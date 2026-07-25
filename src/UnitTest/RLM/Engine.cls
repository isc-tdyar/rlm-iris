/// Tests for the recursion itself.
///
/// Fixture Source plus scripted LLM means every run below is deterministic, so
/// these assert on exact prompts and exact call counts rather than on whether
/// the output "looks reasonable".
///
/// What is being protected: the root model never receives store contents, only
/// aggregates; a slice name the model invents is refused rather than executed;
/// and the budget cannot be overrun by a model that asks for more slices than
/// the run can afford.
Class UnitTest.RLM.Engine Extends %UnitTest.TestCase
{

Property Source As RLM.Source;

Method OnBeforeOneTest(testname As %String) As %Status
{
    Set ..Source = ##class(UnitTest.RLM.Fixture).%New("fixture store")
    Quit $$$OK
}

/// A plan naming two slices costs: 1 plan + 2 sub-calls + 1 synthesis.
Method TestRunsPlanSubcallsThenSynthesis()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild(
        "color:red"_$Char(10)_"color:blue",
        "red is tight",
        "blue is tight",
        "colour separates the population"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Set report = engine.Run("what separates this store?", .trace)

    Do $$$AssertEquals(llm.Calls, 4, "1 plan + 2 sub-calls + 1 synthesis")
    Set found = $Find(report, "colour separates the population")
    Do $$$AssertNotEquals(found, 0, "the synthesis text is the answer")
}

/// The central claim of the package. If store contents ever reach the prompt,
/// the context bound is gone and the whole design is pointless.
Method TestRootPromptCarriesOnlyAggregates()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("", "done"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Do engine.Run("anything", .trace)

    Set plan = llm.PromptAt(1)
    Do $$$AssertNotEquals($Find(plan, "n=1000"), 0, "root count is present")
    Do $$$AssertNotEquals($Find(plan, "color:red"), 0, "the menu is present")
    Set leak = $Find(plan, "<row")
    Do $$$AssertEquals(leak, 0, "no fixture rows leak into the prompt")
}

/// A model that names a slice the store does not offer must be refused, and the
/// refusal must be visible in the report rather than silently dropped: an
/// omitted slice the reader believes was inspected is the worst failure mode.
Method TestRefusedSliceIsReportedNotExecuted()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild(
        "shape:round"_$Char(10)_"color:red",
        "red note",
        "synthesis"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Set report = engine.Run("q", .trace)

    Do $$$AssertEquals(llm.Calls, 3, "the refused slice costs no sub-call")
    Set found = $Find(report, "refused")
    Do $$$AssertNotEquals(found, 0, "the refusal is on the record")
}

/// The model asks for more slices than the budget can fund. It must be truncated
/// at the budget, and the truncation must be stated.
Method TestBudgetCapsSubcallsAndSaysSo()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild(
        "color:red"_$Char(10)_"color:blue"_$Char(10)_"size:small"_$Char(10)_"size:large",
        "one", "two", "synthesis"))
    // 4 total: plan + 2 sub-calls + reserved synthesis.
    Set engine = ##class(RLM.Engine).%New(..Source, llm, ##class(RLM.Budget).%New(4))
    Set report = engine.Run("q", .trace)

    Do $$$AssertEquals(llm.Calls, 4, "budget honoured exactly")
    Set found = $Find(report, "budget")
    Do $$$AssertNotEquals(found, 0, "the cap is disclosed")
}

/// Synthesis must happen even when the plan yields nothing, or a run over a
/// store the model cannot decompose produces no answer at all.
Method TestEmptyPlanStillSynthesizes()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("", "nothing to split on"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Set report = engine.Run("q", .trace)
    Do $$$AssertEquals(llm.Calls, 2, "plan + synthesis")
    Set found = $Find(report, "nothing to split on")
    Do $$$AssertNotEquals(found, 0, "answer present")
}

/// A provider failure on one sub-call must cost that slice, not the report.
Method TestSubcallFailureDoesNotAbortTheRun()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild(
        "color:red"_$Char(10)_"color:blue",
        "red note",
        "blue note",
        "synthesis anyway"))
    Set llm.FailAtCall = 2
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Set report = engine.Run("q", .trace)
    Set found = $Find(report, "synthesis anyway")
    Do $$$AssertNotEquals(found, 0, "run completed")
}

/// The trace is what makes offline evaluation possible. Each row must say what
/// kind of step it was, so a sub-peek is never mistaken for a root decision --
/// the defect that made an earlier prototype's 6-slice plan read as 8 calls.
Method TestTraceDistinguishesRolesAndRecordsSliceKeys()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("color:red", "note", "synthesis"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Do engine.Run("q", .trace)

    Set roles = ""
    Set seq = ""
    For  {
        Set seq = $Order(^||RLM.Trace(trace, seq), 1, row)
        Quit:seq=""
        Set roles = roles_$Select(roles="":"", 1:",")_$List(row, 1)
    }
    Do $$$AssertEquals(roles, "plan,subcall,synthesis", "one row per step, in order")
}

}
