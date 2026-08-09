/// A deterministic in-memory source that offers contents as well as statistics.
///
/// UnitTest.RLM.Fixture deliberately does not implement Materialize, because the
/// suite needs a store that predates lenses to prove one still runs. This one is
/// its counterpart: every branch RLM.Lens.Contents can take is reachable from a
/// single store, so the tests assert on which view came back rather than on which
/// fixture was chosen.
///
/// The four children are the four cases:
///
///   small   3 records, uncapped         -- read
///   big     40 records                  -- too large, falls back
///   partial 5 records but capped        -- count is a floor, falls back
///   many    claims 2, holds 5           -- truncation the peek did not predict
Class UnitTest.RLM.FixtureContents Extends RLM.Source
{

/// `key|n|metric|capped` rows, keyed by the canonical slice key.
ClassMethod Stats() As %List
{
	Quit $ListBuild(
		"|50|0.90|0",
		"batch:small|3|0.10|0",
		"batch:big|40|0.20|0",
		"batch:partial|5|0.30|1",
		"batch:many|2|0.40|0")
}

/// `key|record` rows, in the order a view should render them.
ClassMethod Records() As %List
{
	Quit $ListBuild(
		"batch:small|id=1; status=ok",
		"batch:small|id=2; status=ok",
		"batch:small|id=3; status=failed",
		"batch:many|id=10; status=ok",
		"batch:many|id=11; status=ok",
		"batch:many|id=12; status=ok",
		"batch:many|id=13; status=ok",
		"batch:many|id=14; status=ok")
}

Method %OnNew(name As %String = "contents fixture") As %Status
{
	Set ..Name = name
	Quit $$$OK
}

Method Dimensions(path As %String = "") As %DynamicObject
{
	Quit {
		"batch": {
			"label": "batch",
			"children": [
				{"token": "small",   "label": "small"},
				{"token": "big",     "label": "big"},
				{"token": "partial", "label": "partial"},
				{"token": "many",    "label": "many"}
			]
		}
	}
}

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
	Quit {
		"n": ($Piece(row, "|", 2)),
		"metric": ($Piece(row, "|", 3)),
		"capped": ($Piece(row, "|", 4))
	}
}

/// Records for a slice, capped at `limit`, reporting truncation exactly.
///
/// `batch:big` deliberately has no records despite a large count: a store may know
/// how many rows a slice holds and still be unable to render them, and the lens
/// must reach the same fallback either way.
Method Materialize(
	predicate As %String = "",
	limit As %Integer = 20,
	Output truncated As %Boolean) As %String
{
	Set truncated = 0
	If limit < 1 { Quit "" }
	Set out = "", rows = 0, ptr = 0
	While $ListNext(..Records(), ptr, row) {
		Continue:$Piece(row, "|", 1)'=predicate
		Set rows = rows + 1
		If rows > limit { Set truncated = 1 Quit }
		Set out = out_$Select(out="":"", 1:$Char(10))_"- "_$Piece(row, "|", 2)
	}
	Quit out
}

Method Describe(
	label As %String,
	peek As %DynamicObject) As %String
{
	If peek.error '= "" { Quit label_": unavailable ("_peek.error_")" }
	Quit label_": n="_$Select(peek.capped:"at least "_peek.n, 1:peek.n)
		_", metric="_peek.metric
}

Method SplitMetric(peek As %DynamicObject) As %Numeric
{
	Quit +peek.metric
}

}
