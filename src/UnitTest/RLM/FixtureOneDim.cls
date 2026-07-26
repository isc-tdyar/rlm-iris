/// The separating fixture with `channel` removed.
///
/// Two uses, and they are the same fact from either side: a run over this store has
/// no unchosen candidate at the root, so its enumeration is empty; and a trace
/// recorded against the two-dimension fixture names an arm this store does not
/// offer, so that arm is refused rather than invented.
Class UnitTest.RLM.FixtureOneDim Extends UnitTest.RLM.FixtureSeparating
{

Method %OnNew(name As %String = "one-dimension fixture") As %Status
{
    Set ..Name = name
    Quit $$$OK
}

Method Dimensions(path As %String = "") As %DynamicObject
{
    Quit {
        "region": {
            "label": "region",
            "children": [
                {"token": "north", "label": "north"},
                {"token": "south", "label": "south"}
            ]
        }
    }
}

}
