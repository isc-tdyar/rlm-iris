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
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild(
        "colour:red"_$Char(10)_"colour:blue",
        "The six red widgets sit between 9 and 12.",
        "The four blue widgets sit between 96 and 104.",
        "Colour separates price: red 9-12, blue 96-104."))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Set report = engine.Run("what drives price?", .traceId)

    Do $$$AssertEquals(llm.Calls, 4, "plan + 2 sub-calls + synthesis")

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
        "colour:red", "red note", "answer"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Do engine.Run("what drives price?", .traceId)

    // 104 is a Price value held by exactly one row and is not any aggregate of
    // the red slice, so finding it in the red sub-call prompt would mean row
    // data crossed the boundary.
    Set redPrompt = llm.PromptAt(2)
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
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("", "answer"))
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
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild(
        "colour:red"_$Char(10)_"shape:round"_$Char(10)_"colour:blue",
        "red", "blue", "answer"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Do engine.Run("q", .traceId)

    Set roles = ""
    Set seq = ""
    For  {
        Set seq = $Order(^||RLM.Trace(traceId, seq), 1, row)
        Quit:seq=""
        Set roles = roles_$Select(roles="":"", 1:",")_$List(row, 1)
    }
    // The refused slice is on the record even though it cost no model call: a
    // slice the reader believes was examined but was not is the failure mode.
    Do $$$AssertEquals(roles, "plan,subcall,refused,subcall,synthesis", "every step recorded")
}

}
