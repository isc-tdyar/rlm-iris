/// What one slice looks like to the model.
///
/// The traversal decides *which* slices a run visits; a lens decides what the
/// model is shown once it gets to one. Separating the two is what makes aggregate
/// statistics one option rather than the only one.
///
/// Statistics are what you compute when a slice is too large to read. That is the
/// pathological case rather than the design centre: a decomposition exists to make
/// subsets small, and a subset small enough to read is better answered by reading
/// it than by summarizing it. RLM.Lens.Stats keeps the statistics-only view for
/// the stores where it is the only safe one -- a 400M-row extent, a PHI-bearing
/// table -- and RLM.Lens.Contents reads the records once the recursion has made
/// them few enough to fit.
///
/// Both obligations of RLM.Source survive the widening, because both are about
/// size rather than about statistics:
///
/// 1. What a lens returns is bounded by a constant, never by the size of the
///    store. The claim was always that context grows with slices inspected times
///    cap-per-slice; a lens that returned a whole slice would break the only
///    bound the design has.
/// 2. Truncation is disclosed. A view that shows 20 of 4,000 records and says so
///    is evidence; one that shows 20 and lets them read as all of them makes
///    every claim drawn from it wrong in the same direction.
Class RLM.Lens Extends %RegisteredObject [ Abstract ]
{

/// What the model is shown for one slice.
///
/// `disclosed` carries anything a reader must be told about the view itself -- a
/// truncation, a fallback, a refusal -- and the engine turns it into a caveat.
/// "" means the view is complete as shown.
///
/// A lens is handed the peek as well as the predicate because the two answer
/// different questions: the predicate is how to reach the records, and the peek is
/// how many there are, which is what decides whether reaching for them is sound.
Method View(
	source As RLM.Source,
	label As %String,
	peek As %DynamicObject,
	predicate As %String,
	Output disclosed As %String) As %String [ Abstract ]
{
}

/// How to instruct a model that is about to be shown this kind of view.
///
/// It belongs to the lens rather than to the engine because the two views ask for
/// different work. Statistics are described; records are read and answered from.
/// An instruction telling a model to "state what the statistics support" while
/// handing it rows produces a summary of data it was supposed to reason over.
Method Instructions() As %String [ Abstract ]
{
}

/// Short name of the view kind, for reports and caveats.
Method Kind() As %String [ Abstract ]
{
}

}
