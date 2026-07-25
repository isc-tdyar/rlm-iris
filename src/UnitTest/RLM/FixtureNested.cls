/// A store that is still mixed one level down, so recursion has somewhere to go.
///
/// The ordinary fixture cannot test depth: both of its depth-1 slices are already
/// one population (0.20 and 0.25), so an engine that recursed correctly and one
/// that stopped at depth 1 would produce the same run. Here `color:red` is still
/// mixed at 0.80 and `color:blue` is clean at 0.10, which is the smallest shape
/// that distinguishes them -- and it exercises both branches of the
/// worth-splitting question in a single run.
Class UnitTest.RLM.FixtureNested Extends UnitTest.RLM.Fixture
{

/// Same keys as the parent fixture. `color` wins at the root (0.52 weighted
/// against `size`'s 0.865); within red, `size` then wins again (0.055); within
/// blue there is nothing left to separate, and the default ShouldSplit threshold
/// of 0.15 says so before a peek is spent finding out.
ClassMethod Stats() As %List
{
    Quit $ListBuild(
        "|1000|0.90",
        "color:red|600|0.80",
        "color:blue|400|0.10",
        "size:small|500|0.85",
        "size:large|500|0.88",
        "color:red/size:small|300|0.05",
        "color:red/size:large|300|0.06",
        "color:blue/size:small|200|0.07",
        "color:blue/size:large|200|0.08",
        "size:small/color:red|300|0.05",
        "size:small/color:blue|200|0.07",
        "size:large/color:red|300|0.06",
        "size:large/color:blue|200|0.08")
}

Method %OnNew(name As %String = "nested fixture") As %Status
{
    Set ..Name = name
    Quit $$$OK
}

}
