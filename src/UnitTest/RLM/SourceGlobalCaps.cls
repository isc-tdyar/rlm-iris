/// Tests that a walk which stopped early says so.
///
/// Constitution III. A truncated count presented as a total is worse than no
/// count at all: every later claim is built on it, and nothing downstream can
/// tell that it was a floor. So the assertions here are about the disclosure,
/// not about the number -- a capped walk is allowed to return any figure it
/// likes as long as it admits the figure is a lower bound.
Class UnitTest.RLM.SourceGlobalCaps Extends %UnitTest.TestCase
{

Method OnBeforeOneTest(testname As %String) As %Status
{
    Do ##class(UnitTest.RLM.FixtureGlobal).Build()
    Quit $$$OK
}

/// A source over the fixture with the caps a test wants.
ClassMethod At(
	visit As %Integer = 50000,
	depth As %Integer = 8) As RLM.Source.Global
{
    Set src = ##class(RLM.Source.Global).%New(
        ##class(UnitTest.RLM.FixtureGlobal).#REF, "^||RLM*", .sc)
    Set src.VisitCap = visit
    Set src.DepthCap = depth
    Quit src
}

/// The cap stops the walk and the peek says it stopped. `n` is the cap exactly,
/// so a reader who ignores `capped` at least sees a suspiciously round number
/// rather than a plausible wrong one.
Method TestVisitCapSetsCapped()
{
    Set peek = ..At(5).Peek("")
    Do $$$AssertEquals(peek.capped, 1, "the walk stopped at the cap")
    Do $$$AssertEquals(peek.n, 5, "and counted exactly the cap")
}

/// The other side of the same assertion. A cap above the store's size must not
/// mark the walk capped, or the flag means nothing.
Method TestUncappedWalkIsNotMarkedCapped()
{
    Set peek = ..At(50000).Peek("")
    Do $$$AssertEquals(peek.capped, 0, "nothing was truncated")
    Do $$$AssertEquals(peek.n, ##class(UnitTest.RLM.FixtureGlobal).RootNodes(), "the true count")
}

/// A depth cap bounds `depth` and is disclosed like any other cap. The fixture
/// is three levels deep, so a cap of 2 must leave level 3 uncounted and say so.
Method TestDepthCapSetsCappedAndBoundsDepth()
{
    Set peek = ..At(50000, 2).Peek("")
    Do $$$AssertEquals(peek.capped, 1, "deeper nodes exist and were not counted")
    Do $$$AssertEquals(peek.depth, 2, "and the depth reported is the cap")
    Do $$$AssertTrue(peek.n < ##class(UnitTest.RLM.FixtureGlobal).RootNodes(), "so the count is short")
}

/// A cap exactly at the store's size is not a truncation: every node was
/// visited. This is the off-by-one that turns every honest walk into a warning.
Method TestACapExactlyAtTheSizeIsNotCapped()
{
    Set n = ##class(UnitTest.RLM.FixtureGlobal).RootNodes()
    Set peek = ..At(n).Peek("")
    Do $$$AssertEquals(peek.n, n, "every node counted")
    Do $$$AssertEquals(peek.capped, 0, "and nothing was left out")
}

/// The described text of a capped peek carries a disclosure and an uncapped one
/// does not. Asserts presence, not wording -- the wording is allowed to improve.
Method TestDescribeWordsACappedCountAsAFloor()
{
    Set src = ..At(5)
    Set capped = src.Describe("^||RLMTest", src.Peek(""))
    Set full = ..At(50000)
    Set honest = full.Describe("^||RLMTest", full.Peek(""))
    Do $$$AssertNotEquals($Find(capped, "capped"), 0, "the capped text discloses it")
    Do $$$AssertEquals($Find(honest, "capped"), 0, "and the uncapped text does not")
}

/// The disclosure has to survive the trip into a report, which is the only place
/// a person or a model ever reads it. A caveat that exists in the peek and is
/// dropped by the reporter is the same failure with more steps.
Method TestAReportOfACappedRunDisclosesIt()
{
    Set engine = ##class(RLM.Engine).%New(..At(5),
        ##class(RLM.LLM.Null).%New(), , ##class(RLM.Policy.Greedy).%New())
    Set report = engine.Run("how big is it", .traceId)
    Do $$$AssertNotEquals(report, "", "the run produced a document")
    // The word the peek uses. Asserting on the disclosure's substance rather
    // than its phrasing, but it does have to reach the page.
    Do $$$AssertNotEquals($Find(report, "floor"), 0, "and the report calls the count a floor")
}

}
