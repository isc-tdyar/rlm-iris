/// A store with one dimension that genuinely separates and one that does not, with
/// both facts declared as numbers.
///
/// `UnitTest.RLM.Fixture` already has a better dimension and a worse one, but the
/// gap is small enough that "which policy won" reads as arithmetic. Here `region`
/// cuts the metric from 0.90 to 0.10 and `channel` leaves 90% of the population in
/// one still-mixed bucket, so a policy that picks `channel` is unambiguously worse
/// and the scorecard's ranking is a fact rather than a rounding.
///
/// Every expectation is a class method returning a number worked out by hand.
/// A fixture that computed its own expectations would agree with any bug in the
/// code under test.
Class UnitTest.RLM.FixtureSeparating Extends RLM.Source
{

/// Which dimension actually separates the population.
ClassMethod Separating() As %String
{
    Quit "region"
}

/// Which one barely helps: `channel:web` holds 900 of 1000 rows at metric 0.88
/// against the parent's 0.90.
ClassMethod NotSeparating() As %String
{
    Quit "channel"
}

/// The size-weighted mean child metric of `region`, by hand:
/// (500*0.10 + 500*0.10) / 1000 = 0.10.
ClassMethod RegionScore() As %Numeric
{
    Quit 0.1
}

/// The same for `channel`: (900*0.88 + 100*0.20) / 1000 = 0.812.
ClassMethod ChannelScore() As %Numeric
{
    Quit 0.812
}

/// Statistics keyed by canonical slice key, as `key|n|metric`.
ClassMethod Stats() As %List
{
    Quit $ListBuild(
        "|1000|0.90",
        "region:north|500|0.10",
        "region:south|500|0.10",
        "channel:web|900|0.88",
        "channel:store|100|0.20",
        "region:north/channel:web|450|0.09",
        "region:north/channel:store|50|0.08",
        "region:south/channel:web|450|0.09",
        "region:south/channel:store|50|0.08",
        "channel:web/region:north|450|0.09",
        "channel:web/region:south|450|0.09",
        "channel:store/region:north|50|0.08",
        "channel:store/region:south|50|0.08")
}

Method %OnNew(name As %String = "separating fixture") As %Status
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
        },
        "channel": {
            "label": "channel",
            "children": [
                {"token": "web",   "label": "web"},
                {"token": "store", "label": "store"}
            ]
        }
    }
}

/// The predicate is the canonical key, which is what makes the table above
/// readable as the store itself.
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
