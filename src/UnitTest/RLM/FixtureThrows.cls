/// A store whose peek throws.
///
/// A Source is supposed to return an error object rather than throw, but "supposed
/// to" is not a guarantee: a third-party source, a null property dereference, a
/// <STORE> under memory pressure. FR-016 is the engine's answer -- an exception
/// from anywhere below it becomes a report naming the failure, because a caller
/// that gets an exception where it expected a document has nothing to show anyone.
///
/// Ready() is inherited and returns 1: this fixture fails in the middle of a run
/// rather than declining at the start, which is the case a readiness check cannot
/// catch.
Class UnitTest.RLM.FixtureThrows Extends UnitTest.RLM.Fixture
{

/// Throw only for a slice, not for the store. The root peek succeeds, so the run
/// gets far enough to have something to lose.
Method Peek(predicate As %String = "") As %DynamicObject
{
    If predicate '= "" {
        Throw ##class(%Exception.General).%New("FixtureThrows", 5001, ,
            "the store fell over peeking '"_predicate_"'")
    }
    Quit ##super(predicate)
}

}
