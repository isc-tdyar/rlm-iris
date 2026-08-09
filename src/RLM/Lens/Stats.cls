/// The statistics-only view: aggregates, never contents.
///
/// This is what the engine did before lenses existed, and it stays the default so
/// that adding the seam changes no existing run. A store under a governance
/// constraint -- PHI, an extent too large to read at any depth, an audit log whose
/// contents are the thing being protected -- pins this lens and gets exactly the
/// guarantee the package started with: the model reasons about a store it never
/// receives any part of.
///
/// It holds no state and reads nothing the source has not already computed, so it
/// costs nothing beyond the peek the traversal paid for anyway.
Class RLM.Lens.Stats Extends RLM.Lens
{

/// The source's own rendering of its aggregates. Nothing is added: Describe
/// already words a capped count as a floor, and restating that here would be a
/// second place for the wording to drift.
Method View(
	source As RLM.Source,
	label As %String,
	peek As %DynamicObject,
	predicate As %String,
	Output disclosed As %String) As %String
{
	Set disclosed = ""
	Quit source.Describe(label, peek)
}

Method Instructions() As %String
{
	Quit "You are describing one slice of a data store from its aggregate "
		_"statistics alone. Quote figures under the exact names you were given "
		_"them under. State what the statistics support and nothing further. "
		_"Two or three sentences."
}

Method Kind() As %String
{
	Quit "stats"
}

}
