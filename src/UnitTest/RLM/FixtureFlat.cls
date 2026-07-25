/// A store that does not decompose: every dimension leaves the metric where it
/// found it.
///
/// This exists because "no dimension helped" is a real answer a policy has to be
/// able to give, and it is not reachable from the ordinary fixture -- there,
/// `color` always wins. Without a store like this, the declined-split path can
/// only be tested by mocking a policy, which tests the mock.
Class UnitTest.RLM.FixtureFlat Extends UnitTest.RLM.Fixture
{

/// Same keys as the parent fixture, so the same tests can be pointed at either
/// store. Every child metric sits at or above the root's 0.90.
ClassMethod Stats() As %List
{
    Quit $ListBuild(
        "|1000|0.90",
        "color:red|500|0.90",
        "color:blue|500|0.91",
        "size:small|500|0.92",
        "size:large|500|0.90",
        "color:red/size:small|250|0.90",
        "color:red/size:large|250|0.91",
        "color:blue/size:small|250|0.91",
        "color:blue/size:large|250|0.90",
        "size:small/color:red|250|0.90",
        "size:small/color:blue|250|0.91",
        "size:large/color:red|250|0.91",
        "size:large/color:blue|250|0.90")
}

Method %OnNew(name As %String = "flat fixture") As %Status
{
    Set ..Name = name
    Quit $$$OK
}

}
