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

/// Statistics keyed by the canonical slice key. `metric` is the normalized
/// 0-1 split metric; `color` separates the population and `size` does not.
XData Stats
{
<stats>
<row key="" n="1000" metric="0.90"/>
<row key="color:red" n="600" metric="0.20"/>
<row key="color:blue" n="400" metric="0.25"/>
<row key="size:small" n="500" metric="0.85"/>
<row key="size:large" n="500" metric="0.88"/>
<row key="color:red/size:small" n="300" metric="0.05"/>
<row key="color:red/size:large" n="300" metric="0.06"/>
<row key="color:blue/size:small" n="200" metric="0.07"/>
<row key="color:blue/size:large" n="200" metric="0.08"/>
<row key="size:small/color:red" n="300" metric="0.05"/>
<row key="size:small/color:blue" n="200" metric="0.07"/>
<row key="size:large/color:red" n="300" metric="0.06"/>
<row key="size:large/color:blue" n="200" metric="0.08"/>
</stats>
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
    Set xdata = ##class(%Dictionary.CompiledXData).%OpenId($ClassName()_"||Stats")
    If '$IsObject(xdata) { Quit {"error": "fixture Stats XData missing"} }
    Set reader = ##class(%XML.TextReader).%New()
    Do ##class(%XML.TextReader).ParseStream(xdata.Data, .reader)
    While reader.Read() {
        Continue:reader.NodeType'="element"
        Continue:reader.Name'="row"
        Do reader.MoveToAttributeName("key")
        Set key = reader.Value
        Continue:key'=predicate
        Do reader.MoveToAttributeName("n")
        Set n = reader.Value
        Do reader.MoveToAttributeName("metric")
        Set metric = reader.Value
        Quit
    }
    If '$Data(n) { Quit {"error": ("no fixture row for key '"_predicate_"'")} }
    Quit {"n": (n), "metric": (metric), "capped": 0}
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
