/// A store that reports itself unfit to report on.
///
/// The state this exists for is a real one: a table mid-load, a view over a feed
/// that has not arrived, an extent whose statistics are stale. The alternative to
/// refusing is averaging over whichever rows happen to be present, which produces a
/// document that is both confident and wrong -- and a reader has no way to tell it
/// from a correct one.
///
/// The reason is actionable on purpose. "not ready" sends a reader to the logs;
/// naming what is missing sends them to the thing that is missing.
Class UnitTest.RLM.FixtureNotReady Extends UnitTest.RLM.Fixture
{

/// Peeks this store was asked for. The engine does not charge its own peeks to the
/// budget -- only a policy's -- so RLM.Budget cannot answer "was it read at all",
/// and on a store mid-load that is the question: the peek is the expensive call and
/// may itself be the thing that fails.
Property Peeks As %Integer [ InitialExpression = 0 ];

Method Ready(Output reason As %String) As %Boolean
{
    Set reason = "the nightly load has not finished; 3 of 12 partitions are absent"
    Quit 0
}

Method Peek(predicate As %String = "") As %DynamicObject
{
    Set ..Peeks = ..Peeks + 1
    Quit ##super(predicate)
}

}
