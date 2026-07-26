/// The separating fixture with no statistics behind it: every peek fails.
///
/// It declares the same dimensions, so an arm recorded against
/// UnitTest.RLM.FixtureSeparating resolves to a name this store also offers -- and
/// then cannot be scored. That is the case FR-005 is about, and it is the only way
/// to test "unscorable" without conflating it with "not offered".
Class UnitTest.RLM.FixtureSeparatingBroken Extends UnitTest.RLM.FixtureSeparating
{

ClassMethod Stats() As %List
{
    Quit ""
}

Method %OnNew(name As %String = "broken fixture") As %Status
{
    Set ..Name = name
    Quit $$$OK
}

}
