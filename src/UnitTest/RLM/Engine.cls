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

/// Naming a dimension with two children costs: 1 decision + 2 sub-calls +
/// 1 synthesis. The model names the dimension; the engine expands it.
Method TestRunsPlanSubcallsThenSynthesis()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild(
        "color",
        "red is tight",
        "blue is tight",
        "colour separates the population"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Set report = engine.Run("what separates this store?", .trace)

    Do $$$AssertEquals(llm.Calls, 4, "1 decision + 2 sub-calls + 1 synthesis")
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
    // The choice offered is now a list of dimensions rather than of slice paths,
    // so the name to look for is the dimension's.
    Do $$$AssertNotEquals($Find(plan, "color"), 0, "the candidate list is present")
    Set leak = $Find(plan, "<row")
    Do $$$AssertEquals(leak, 0, "no fixture rows leak into the prompt")
}

/// The successor to TestRefusedSliceIsReportedNotExecuted.
///
/// A refused *slice* can no longer occur: the engine generates slice names from
/// the store's own children, so every name it resolves resolves by construction.
/// What can still go wrong is the model naming a dimension the store does not
/// offer, and that must decline the split visibly rather than proceed as though
/// a decomposition happened.
Method TestInventedDimensionDeclinesTheSplitAndSaysSo()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("shape", "synthesis"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Set report = engine.Run("q", .trace)

    Do $$$AssertEquals(llm.Calls, 2, "the invented dimension costs no sub-call")
    Set found = $Find(report, "Not decomposed")
    Do $$$AssertNotEquals(found, 0, "the decline is on the record")
    Set named = $Find(report, "shape")
    Do $$$AssertNotEquals(named, 0, "quoting what the model actually said")
}

/// The chosen dimension has more children than the budget can fund. The run must
/// be truncated at the budget, and the truncation stated.
Method TestBudgetCapsSubcallsAndSaysSo()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("color", "one", "synthesis"))
    // 3 total: decision + 1 sub-call + reserved synthesis, against 2 children.
    Set engine = ##class(RLM.Engine).%New(..Source, llm, ##class(RLM.Budget).%New(3))
    Set report = engine.Run("q", .trace)

    Do $$$AssertEquals(llm.Calls, 3, "budget honoured exactly")
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
        "color",
        "red note",
        "blue note",
        "synthesis anyway"))
    // Call 1 is the decision, so call 2 is the first sub-call.
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
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("color", "red", "blue", "synth"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Do engine.Run("q", .trace)

    Set roles = "", keys = ""
    Set seq = ""
    For  {
        Set seq = $Order(^||RLM.Trace(trace, seq), 1, row)
        Quit:seq=""
        Set roles = roles_$Select(roles="":"", 1:",")_$List(row, 1)
        // Field 3 is the source class and field 4 the slice key; the row is not
        // built in the order Add() takes its arguments.
        If $List(row, 1) = "subcall" {
            Set keys = keys_$Select(keys="":"", 1:",")_$List(row, 4)
        }
    }
    // `decision` stands where `plan` did: the step is recorded whether or not a
    // model call paid for it, which is what lets the two policies be compared.
    Do $$$AssertEquals(roles, "decision,subcall,subcall,synthesis", "one row per step")
    Do $$$AssertEquals(keys, "color:red,color:blue", "each sub-call says which slice")
}

/// The decision detail is a sidecar, not an eleventh field.
///
/// A nested list packed into field eleven would make `$List(row, 11)` on a
/// pre-feature row return "" rather than fail, which is a silent wrong answer.
/// Subscripts also make enumerating the alternative arms a $Order walk.
Method TestDecisionIsASidecarAndLeavesTheRowIntact()
{
    Set trace = ##class(RLM.Trace).%New()
    Set d = ##class(RLM.Decision).%New("RLM.Policy.Greedy", 0.90)
    Do d.Choose("color", 0.22, "lowest weighted child metric")
    Set c = d.AddCandidate("color", 0.22, 2, 2)
    Set c.ChildMetrics = $ListBuild("red:600:0.20", "blue:400:0.25")
    Do d.AddCandidate("size", 0.86, 2, 2)
    Set d.PeeksSpent = 4
    Set seq = trace.AddDecision(d, 0, "UnitTest.RLM.Fixture", "")

    Set row = trace.Row(seq)
    Do $$$AssertEquals($ListLength(row), 10, "the $LIST row keeps its ten fields")
    Do $$$AssertEquals($List(row, 1), "decision", "role names the step")
    Do $$$AssertEquals($List(row, 5), 0.90, "splitMetric is the before-metric")

    Set side = ^||RLM.Trace(trace.RunId, seq, "d")
    Do $$$AssertEquals($List(side, 1), "color", "chosen dimension in the sidecar")
    Do $$$AssertEquals($List(side, 5), "RLM.Policy.Greedy", "which policy decided")
    Do $$$AssertEquals($List(side, 6), 4, "peeks spent")

    Set cand = ^||RLM.Trace(trace.RunId, seq, "d", "cand", 1)
    Do $$$AssertEquals($List(cand, 1), "color", "first candidate, declaration order")
    Set metrics = ^||RLM.Trace(trace.RunId, seq, "d", "cand", 1, "m")
    Do $$$AssertEquals($ListGet(metrics, 2), "blue:400:0.25", "child metrics survive")
}

/// FR-016, first of three. A store that throws mid-run must not reach the caller
/// as an exception.
///
/// The three cases are separate tests rather than one loop because the interesting
/// part is not that a Try exists -- it is where each throw originates. A source
/// throws below the engine, a policy throws inside a seam the engine calls, and a
/// provider throws two frames down inside the policy; a single Try that caught the
/// first can easily be positioned so it misses the third.
///
/// What is asserted is that the partial document survives: the root peek succeeded,
/// so the store's statistics were known and belong in the report. Discarding them
/// on the way out would make a mid-run failure indistinguishable from a store that
/// could not be read at all.
Method TestThrowingSourceBecomesAReportNotAnException()
{
    Set thrower = ##class(UnitTest.RLM.FixtureThrows).%New("brittle store")
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("color", "red", "blue", "synth"))
    Set engine = ##class(RLM.Engine).%New(thrower, llm)
    Set report = engine.Run("what separates this store?", .traceId)

    Do $$$AssertNotEquals($Find(report, "stopped early"), 0, "the failure is stated")
    Do $$$AssertNotEquals($Find(report, "n=1000"), 0, "what was known is kept")
    Do $$$AssertNotEquals(traceId, "", "and the run is still identified")
}

/// FR-016, second of three. Obligation 7 says a policy never throws; the engine
/// does not get to rely on that, because a policy is the seam third-party code
/// plugs into.
Method TestThrowingPolicyBecomesAReportNotAnException()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("synth"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm, ,
        ##class(UnitTest.RLM.PolicyThrows).%New())
    Set report = engine.Run("q", .traceId)

    Do $$$AssertNotEquals($Find(report, "stopped early"), 0, "the failure is stated")
    Do $$$AssertNotEquals($Find(report, "divided by zero"), 0, "and named")
}

/// FR-016, third of three. A real provider is an HTTP client, and a socket reset
/// arrives as an exception however carefully RLM.LLM words its contract.
Method TestThrowingProviderBecomesAReportNotAnException()
{
    Set llm = ##class(UnitTest.RLM.LLMThrows).%New()
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Set report = engine.Run("q", .traceId)

    Do $$$AssertEquals(llm.Calls, 1, "it failed on the first call")
    Do $$$AssertNotEquals($Find(report, "stopped early"), 0, "the failure is stated")
    Do $$$AssertNotEquals($Find(report, "closed the connection"), 0, "and named")
}

/// FR-015's default, asserted rather than assumed. UnitTest.RLM.Fixture does not
/// override Ready, and the whole point of giving RLM.Source a concrete one is that
/// no existing store needs editing to keep working.
Method TestSourceWithoutReadyRunsUnchanged()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("color", "red", "blue", "synth"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Set report = engine.Run("q", .traceId)

    Do $$$AssertEquals(llm.Calls, 4, "the readiness check cost nothing")
    Do $$$AssertNotEquals($Find(report, "n=1000"), 0, "and the run happened")
    Do $$$AssertEquals($Find(report, "was not run"), 0, "nothing was refused")
}

/// A store that declines must decline before it is peeked, not after.
///
/// Asserted on the store's own peek counter rather than on the report, because the
/// report of a run that peeked and then refused looks identical to one that refused
/// first -- and on a store mid-load the peek is the expensive thing, and the thing
/// most likely to fail.
Method TestNotReadyStoreIsNotEvenPeeked()
{
    Set stale = ##class(UnitTest.RLM.FixtureNotReady).%New("nightly load")
    Set llm = ##class(RLM.LLM.Null).%New("")
    Set engine = ##class(RLM.Engine).%New(stale, llm)
    Set report = engine.Run("q", .traceId)

    Do $$$AssertEquals(llm.Calls, 0, "no model call")
    Do $$$AssertEquals(stale.Peeks, 0, "and the store was never read")
    Do $$$AssertNotEquals($Find(report, "was not run"), 0, "and the reader is told")
}

/// Absence has to mean something, or a reader cannot tell a step that made no
/// decision from a decision that failed to record.
Method TestOrdinaryRowHasNoDecisionSubtree()
{
    Set trace = ##class(RLM.Trace).%New()
    Set seq = trace.Add("subcall", 1, "color:red", "UnitTest.RLM.Fixture")
    // Hoisted: a $$$macro(...) call cannot span source lines.
    Set has = $Data(^||RLM.Trace(trace.RunId, seq, "d"))
    Do $$$AssertNotTrue(has, "a sub-call made no decision")
}

}
