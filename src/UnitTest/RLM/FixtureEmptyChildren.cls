/// A fixture whose dimension divides a populated slice into empty children.
///
/// Not a contrived shape. `RLM.Source.Interop` advertises `hour` as 24 buckets
/// whether or not a message landed in any of them, so a six-message extent scores
/// several slices holding nothing -- and that is how the divide-by-zero in
/// `RLM.Policy.Greedy` was found, on a real store, in an end-to-end test.
///
/// The root holds 1000 rows and every child holds none, which is inconsistent as
/// arithmetic and exactly right as a test: it isolates the empty-children case from
/// the empty-store case, which a policy handles elsewhere and differently.
Class UnitTest.RLM.FixtureEmptyChildren Extends UnitTest.RLM.Fixture
{

ClassMethod Stats() As %List
{
    Quit $ListBuild(
        "|1000|0.90",
        "hour:h0|0|0",
        "hour:h1|0|0",
        "hour:h2|0|0")
}

Method %OnNew(name As %String = "empty-children fixture") As %Status
{
    Set ..Name = name
    Quit $$$OK
}

Method Dimensions(path As %String = "") As %DynamicObject
{
    Quit {
        "hour": {
            "label": "hour",
            "children": [
                {"token": "h0", "label": "00:00"},
                {"token": "h1", "label": "01:00"},
                {"token": "h2", "label": "02:00"}
            ]
        }
    }
}

}
