/// A deterministic in-memory RLM.Source used by the test suite.
///
/// The point of this class is that the whole engine can be tested with no
/// database and no language model: peeks resolve against a literal table of
/// statistics, so every assertion below is exact rather than approximate.
///
/// Two dimensions, two children each, which is the smallest shape that still
/// exercises the interesting cases: one dimension splits cleanly and the other
/// barely helps, so a policy that picks the better one is distinguishable from
/// one that picks first.
Class UnitTest.RLM.Fixture Extends RLM.Source
{

/// Statistics keyed by the canonical slice key, as `key|n|metric` rows.
/// `metric` is the normalized 0-1 split metric: `color` separates the
/// population and `size` does not, so a policy that picks the better dimension
/// is distinguishable from one that picks the first.
///
/// A literal list rather than XData or a table, because a fixture that can
/// itself fail to load turns every downstream failure into a puzzle.
ClassMethod Stats() As %List
{
    Quit $ListBuild(
        "|1000|0.90",
        "color:red|600|0.20",
        "color:blue|400|0.25",
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

Method %OnNew(name As %String = "fixture") As %Status
{
    Set ..Name = name
    Quit $$$OK
}

Method Dimensions() As %DynamicObject
{
    Quit {
        "color": {
            "label": "colour",
            "children": [
                {"token": "red",  "label": "red"},
                {"token": "blue", "label": "blue"}
            ]
        },
        "size": {
            "label": "size",
            "children": [
                {"token": "small", "label": "small"},
                {"token": "large", "label": "large"}
            ]
        }
    }
}

/// The fixture's predicate *is* the canonical key, which is what makes the
/// lookup table above readable.
Method Predicate(components As %List) As %String
{
    Set out = "", ptr = 0
    While $ListNext(components, ptr, comp) {
        Set out = out_$Select(out="":"", 1:"/")_comp
    }
    Quit out
}

Method Peek(predicate As %String = "") As %DynamicObject
{
    Set ptr = 0
    While $ListNext(..Stats(), ptr, row) {
        Continue:$Piece(row, "|", 1)'=predicate
        Quit
    }
    If $Piece($Get(row), "|", 1) '= predicate {
        Quit {"error": ("no fixture row for key '"_predicate_"'")}
    }
    Quit {"n": ($Piece(row, "|", 2)), "metric": ($Piece(row, "|", 3)), "capped": 0}
}

Method Describe(label As %String, peek As %DynamicObject) As %String
{
    Quit label_": n="_peek.n_", metric="_peek.metric
}

Method SplitMetric(peek As %DynamicObject) As %Numeric
{
    Quit +peek.metric
}

}
