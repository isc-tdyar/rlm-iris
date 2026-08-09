/// The records themselves, once the recursion has made them few enough.
///
/// This is the lens the general case needs. Most real questions are judgements
/// over records rather than aggregations of them -- which patients meet the
/// criteria, which messages failed and why, which rows look wrong -- and no
/// aggregate answers any of them. What makes reading affordable is the
/// decomposition: a slice that started as 400M rows is, four levels down, a few
/// dozen, and a few dozen fit.
///
/// So the stopping rule generalizes. The traversal already stops splitting a slice
/// the store calls one population; this lens adds the other reason to stop, which
/// is that the slice has become small enough to answer from directly. Above the
/// threshold the view degrades to statistics rather than failing, because a slice
/// that is still too large is exactly the slice the statistics were designed for.
///
/// Three ways a view falls back, all disclosed rather than silent:
///
/// 1. The slice is larger than MaxRecords, so reading it would break the context
///    bound the whole design rests on.
/// 2. The peek was capped, so its count is a floor and the slice may be very much
///    larger than it appears. Trusting a floor here is how a bounded walk turns
///    into an unbounded read.
/// 3. The store does not offer contents at all. RLM.Source.Materialize is concrete
///    and returns nothing by default, so a source written before this lens existed
///    degrades to its old behaviour instead of erroring.
Class RLM.Lens.Contents Extends RLM.Lens
{

/// Most records one view may show.
///
/// This is the context bound, and it is per slice rather than per run: the
/// traversal already bounds how many slices are visited, and the product of the
/// two is what the model actually accumulates.
Property MaxRecords As %Integer [ InitialExpression = 20 ];

/// The view used when the records cannot be shown. Held as a lens rather than
/// open-coded so a fallback view and a statistics view are the same object, and
/// cannot drift into wording the same aggregates two ways.
Property Fallback As RLM.Lens;

Method %OnNew(maxRecords As %Integer = 20) As %Status
{
	Set ..MaxRecords = $Select(maxRecords < 1:1, 1:maxRecords)
	Set ..Fallback = ##class(RLM.Lens.Stats).%New()
	Quit $$$OK
}

Method View(
	source As RLM.Source,
	label As %String,
	peek As %DynamicObject,
	predicate As %String,
	Output disclosed As %String) As %String
{
	Set disclosed = ""

	// The store's own judgement of whether this slice can be read, asked before
	// any attempt to read it. A source that knows its slice is capped or errored
	// answers here for free; finding out from a materialize that returned 50,000
	// rows is finding out too late.
	If 'source.Fits(peek, ..MaxRecords) {
		Set disclosed = "'"_label_"' holds more than "_..MaxRecords
			_" record(s) or its count is a floor, so it is described by its "
			_"statistics rather than read."
		Quit ..Fallback.View(source, label, peek, predicate, .ignored)
	}

	Set body = source.Materialize(predicate, ..MaxRecords, .truncated)
	If $ZStrip(body, "<>W") = "" {
		Set disclosed = "'"_label_"' could not be read, so it is described by "
			_"its statistics instead."
		Quit ..Fallback.View(source, label, peek, predicate, .ignored)
	}

	// Fits() said the slice was within the cap, so a truncation here means the
	// count the peek reported and the rows the store returned disagree. Saying so
	// is the whole of Constitution II: the model is about to reason over these
	// records and must not read them as the complete set.
	// $Get rather than a bare read: Materialize is documented to set `truncated`,
	// but the contract is on the implementation and a source that returns without
	// setting it would otherwise take the whole run down with an <UNDEFINED> --
	// from a lens, which is the one place obliged not to.
	Set head = label_": "_peek.n_" record(s)"
	If $Get(truncated, 0) {
		Set disclosed = "'"_label_"' returned more records than its count "
			_"predicted; the view shows the first "_..MaxRecords_"."
		Set head = label_": first "_..MaxRecords_" record(s), and there are more"
	}
	Quit head_$Char(10)_body
}

Method Instructions() As %String
{
	Quit "You are answering a question from the complete records of one subset "
		_"of a larger store. Reason over the records you were given and answer "
		_"for this subset only. Every claim must be something a record shown to "
		_"you states; if the records do not settle the question for this subset, "
		_"say so rather than inferring. Do not generalize to the rest of the "
		_"store, which you have not seen. Two to four sentences."
}

Method Kind() As %String
{
	Quit "contents"
}

}
