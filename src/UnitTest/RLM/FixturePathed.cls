/// A source whose children depend on where you are standing, plus a record of
/// every path it was asked about.
///
/// This is the smallest store that can distinguish "Dimensions was given the
/// path" from "Dimensions compiled with a path parameter". Level 2 offers `x`
/// under `s1:a` and `y`,`z` under `s1:b`, so a caller that looks children up at
/// the root either refuses a legal slice or resolves one to the wrong subtree --
/// and both failures are silent.
///
/// It stands in for RLM.Source.Global, which has the same shape for real
/// reasons, so the seam can be tested before the global walk exists.
Class UnitTest.RLM.FixturePathed Extends RLM.Source
{

/// Paths Dimensions has been called with this run, in order, keyed 1..n.
Property Asked As %String [ MultiDimensional ];

/// How many times Dimensions has been called since the last Forget.
Property AskCount As %Integer [ InitialExpression = 0 ];

Method %OnNew(name As %String = "pathed") As %Status
{
    Set ..Name = name
    Quit $$$OK
}

/// Clear the record. Tests call this immediately before the call they mean to
/// inspect, because Resolve legitimately asks more than once.
Method Forget()
{
    Kill ..Asked
    Set ..AskCount = 0
}

/// The nth path this source was asked about, or "" if it was not asked that
/// many times. Returning "" rather than erroring keeps the assertion readable:
/// a test that expected two calls and got one fails on the value.
Method AskedWith(n As %Integer) As %String
{
    Quit $Get(..Asked(n), "<not asked>")
}

Method Dimensions(path As %String = "") As %DynamicObject
{
    Set ..AskCount = ..AskCount + 1
    Set ..Asked(..AskCount) = path

    Set out = {}
    // Level 1 exists only at the root. Below it, splitting on level 1 again
    // narrows nothing, which is what the one-dimension-per-path rule encodes.
    If path = "" {
        Do out.%Set("s1", {
            "label": "subscript level 1",
            "children": [
                {"token": "a", "label": "a"},
                {"token": "b", "label": "b"}
            ]
        })
    }
    Set first = ..FirstToken(path)
    If first = "a" {
        Do out.%Set("s2", {
            "label": "subscript level 2",
            "children": [{"token": "x", "label": "x"}]
        })
    } ElseIf first = "b" {
        Do out.%Set("s2", {
            "label": "subscript level 2",
            "children": [
                {"token": "y", "label": "y"},
                {"token": "z", "label": "z"}
            ]
        })
    }
    Quit out
}

/// The `s1` token in `path`, or "" if the path does not fix level 1.
ClassMethod FirstToken(path As %String) As %String
{
    For i = 1:1:$Length(path, "/") {
        Set comp = $Piece(path, "/", i)
        If $Piece(comp, ":", 1) = "s1" { Quit }
        Set comp = ""
    }
    Quit $Piece($Get(comp), ":", 2)
}

Method Predicate(components As %List) As %String
{
    Set out = "", ptr = 0
    While $ListNext(components, ptr, comp) {
        Set out = out_$Select(out="":"", 1:"/")_comp
    }
    Quit out
}

/// Node counts chosen so `s1` is worth splitting on and the leaves are not.
Method Peek(predicate As %String = "") As %DynamicObject
{
    Set counts = "|100:s1:a|60:s1:b|40:s1:a/s2:x|60:s1:b/s2:y|30:s1:b/s2:z|10"
    Set n = ""
    For i = 1:1:$Length(counts, "|") \ 2 {
        Continue:$Piece(counts, "|", (i * 2) - 1)'=predicate
        Set n = $Piece(counts, "|", i * 2)
        Quit
    }
    If n = "" { Quit {"error": ("no fixture row for '"_predicate_"'")} }
    Quit {"n": (+n), "capped": 0,
        "metric": ($Select(predicate="":0.9, $Length(predicate,"/")=1:0.5, 1:0.02))}
}

Method Describe(label As %String, peek As %DynamicObject) As %String
{
    Quit label_": n="_peek.n
}

Method SplitMetric(peek As %DynamicObject) As %Numeric
{
    Quit +peek.metric
}

}
