/// The M0 phase gate: a whole decomposition over a real SQL table.
///
/// Everything below the engine is genuine -- IRIS computes the aggregates over
/// rows that are never copied out of the database. Only the language model is
/// scripted, because a real one would make the assertions probabilistic.
///
/// What this proves that the unit tests cannot: RLM.Engine, RLM.Slice,
/// RLM.Source.Table, RLM.Budget, RLM.Trace and RLM.Report compose, and the
/// composition holds the invariant that matters -- the model sees aggregates and
/// a menu, never rows.
Class UnitTest.RLM.EndToEnd Extends %UnitTest.TestCase
{

Property Source As RLM.Source;

Method OnBeforeAllTests() As %Status
{
    Quit ##class(UnitTest.RLM.Widget).Populate()
}

Method OnBeforeOneTest(testname As %String) As %Status
{
    Set ..Source = ##class(RLM.Source.Table).%New("UnitTest.RLM.Widget", "Price")
    Do ..Source.AddDimension("colour", "Colour")
    Do ..Source.AddDimension("size", "Size")
    Quit $$$OK
}

Method TestDecomposesARealTable()
{
    // The model now names a dimension rather than a list of slices; the engine
    // expands it into one slice per child, so every name it resolves is one the
    // store itself generated.
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild(
        "colour",
        "The six red widgets sit between 9 and 12.",
        "The four blue widgets sit between 96 and 104.",
        "Colour separates price: red 9-12, blue 96-104."))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Set report = engine.Run("what drives price?", .traceId)

    Do $$$AssertEquals(llm.Calls, 4, "decision + 2 sub-calls + synthesis")

    // Figures the model was given must be the database's, not the fixture's.
    Do $$$AssertNotEquals($Find(report, "n=10"), 0, "store-wide count is real")
    Do $$$AssertNotEquals($Find(report, "n=6"), 0, "red slice count is real")
    Do $$$AssertNotEquals($Find(report, "n=4"), 0, "blue slice count is real")
    Do $$$AssertNotEquals($Find(report, "Colour separates price"), 0, "answer present")
}

/// The invariant, checked against a real store rather than a fixture: not one
/// row value may appear in any prompt the model received.
Method TestNoRowEverReachesTheModel()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild(
        "colour", "red note", "blue note", "answer"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Do engine.Run("what drives price?", .traceId)

    // 104 is a Price value held by exactly one row and is not any aggregate of
    // the red slice, so finding it in the red sub-call prompt would mean row
    // data crossed the boundary.
    //
    // The prompt is located by content rather than by ordinal: the store's child
    // order comes from SELECT DISTINCT and is the database's business, so a test
    // that hard-codes which call was red asserts on collation order by accident.
    Set redPrompt = ""
    For i = 1:1:llm.Calls {
        If $Find(llm.PromptAt(i), "n=6") { Set redPrompt = llm.PromptAt(i)  Quit }
    }
    Do $$$AssertNotEquals(redPrompt, "", "the red slice was asked about")
    Set leak = $Find(redPrompt, "104")
    Do $$$AssertEquals(leak, 0, "no individual price reaches the sub-call")
    Do $$$AssertNotEquals($Find(redPrompt, "n=6"), 0, "only the aggregate does")
}

/// The prompt the model sees must not grow with the table. This is the claim
/// that distinguishes the package from loading a table into a REPL, so it is
/// measured rather than asserted rhetorically.
Method TestPromptSizeIsIndependentOfRowCount()
{
    Set small = ..PlanPromptLength()
    // Ten times the rows, same two colours and two sizes.
    For i = 1:1:9 { Do ..Duplicate() }
    Set large = ..PlanPromptLength()
    Do $$$AssertEquals(large, small, "100 rows produce the same plan prompt as 10")
    Do ##class(UnitTest.RLM.Widget).Populate()
}

Method PlanPromptLength() As %Integer
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("none", "answer"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Do engine.Run("q", .t)
    // The store-wide count is the one figure that legitimately changes with row
    // count; blank it so the comparison is about structure, not digits.
    Quit $Length($Replace(llm.PromptAt(1), "n="_..Source.Peek("").n, "n=N"))
}

Method Duplicate() As %Status
{
    Set rs = ##class(RLM.Source.Table).Query("SELECT Colour, Size, Price FROM UnitTest_RLM.Widget", .sc)
    Set rows = ""
    While rs.%Next() {
        Set rows = rows_$ListBuild(rs.%Get("Colour")_"|"_rs.%Get("Size")_"|"_rs.%Get("Price"))
    }
    Set ptr = 0
    While $ListNext(rows, ptr, row) {
        Set w = ##class(UnitTest.RLM.Widget).%New()
        Set w.Colour = $Piece(row, "|", 1)
        Set w.Size = $Piece(row, "|", 2)
        Set w.Price = $Piece(row, "|", 3)
        Do w.%Save()
    }
    Quit $$$OK
}

/// The trace must account for every model call, because offline evaluation reads
/// the trace and not the report.
Method TestTraceAccountsForEveryCall()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("colour", "red", "blue", "answer"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Do engine.Run("q", .traceId)

    Set roles = ..Roles(traceId)
    // A `decision` row now stands where `plan` did. There is no `refused` row
    // because the engine generates the slice names from the store's own children,
    // so a name the store will refuse can no longer be produced -- the failure
    // mode the old assertion guarded is gone rather than untested.
    Do $$$AssertEquals(roles, "decision,subcall,subcall,synthesis", "every step recorded")
}

/// US1 phase gate. The claim of the feature, measured: the same store decomposed
/// with no model call spent on navigation.
Method TestGreedyRunSpendsNoModelCallOnNavigation()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("red", "blue", "answer"))
    Set budget = ##class(RLM.Budget).%New(8)
    Set engine = ##class(RLM.Engine).%New(..Source, llm, budget,
        ##class(RLM.Policy.Greedy).%New())
    Set report = engine.Run("what drives price?", .traceId)

    Do $$$AssertEquals(llm.Calls, 3, "2 sub-calls + synthesis, and nothing else")
    Set roles = ..Roles(traceId)
    Do $$$AssertEquals(roles, "decision,subcall,subcall,synthesis", "decision recorded")
    Do $$$AssertTrue(budget.PeeksUsed > 0, "it paid in peeks instead")
    Do $$$AssertNotEquals($Find(report, "n=6"), 0, "and reached the same slices")
    Do $$$AssertNotEquals($Find(report, "n=4"), 0, "both of them")
}

/// SC-001, stated as a comparison rather than an absolute: the same store, the
/// same slices, one fewer model call.
Method TestGreedyCostsOneFewerModelCallThanTheModelPolicy()
{
    Set a = ##class(RLM.LLM.Null).%New($ListBuild("colour", "red", "blue", "answer"))
    Set ea = ##class(RLM.Engine).%New(..Source, a)
    Do ea.Run("what drives price?", .ta)

    Set b = ##class(RLM.LLM.Null).%New($ListBuild("red", "blue", "answer"))
    Set eb = ##class(RLM.Engine).%New(..Source, b, , ##class(RLM.Policy.Greedy).%New())
    Do eb.Run("what drives price?", .tb)

    Do $$$AssertEquals(b.Calls, a.Calls - 1, "one fewer model call for the same work")
}

/// A store nothing separates must produce an answer that says so, not a
/// decomposition that quietly examined nothing.
Method TestUndecomposableStoreSaysSoInTheReport()
{
    Set flat = ##class(UnitTest.RLM.FixtureFlat).%New()
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("nothing separates this store"))
    Set engine = ##class(RLM.Engine).%New(flat, llm, ,
        ##class(RLM.Policy.Greedy).%New())
    Set report = engine.Run("q", .traceId)

    Do $$$AssertEquals(llm.Calls, 1, "synthesis only")
    Do $$$AssertNotEquals($Find(report, "Not decomposed"), 0, "the reader is told")
    Set why = $Find(report, "no dimension reduced the metric")
    Do $$$AssertNotEquals(why, 0, "and told why")
}

Method Roles(traceId As %Integer) As %String
{
    Set roles = "", seq = ""
    For  {
        Set seq = $Order(^||RLM.Trace(traceId, seq), 1, row)
        Quit:seq=""
        Set roles = roles_$Select(roles="":"", 1:",")_$List(row, 1)
    }
    Quit roles
}

}
