/// A nested fixture that remembers every predicate it was peeked with.
///
/// "Every peek stayed inside the scope" is a claim about what the engine asked
/// for, not about what came back, so it cannot be checked from the report or the
/// trace -- both record the answers. The store is the only place that sees the
/// questions.
Class UnitTest.RLM.FixtureRecording Extends UnitTest.RLM.FixtureNested
{

/// Predicates this store was asked for, in order.
Property Peeked As %List;

Method %OnNew(name As %String = "recording fixture") As %Status
{
    Set ..Name = name
    Quit $$$OK
}

Method Peek(predicate As %String = "") As %DynamicObject
{
    Set ..Peeked = ..Peeked_$ListBuild(predicate)
    Quit ##super(predicate)
}

}
