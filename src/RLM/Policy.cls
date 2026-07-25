/// How a slice gets divided.
///
/// This is the seam the package's evaluation story rests on. Before it existed,
/// the engine asked the model both questions at once -- "how should this be
/// divided" and "which pieces are worth looking at" -- and got back a list of
/// slice names that conflated them. Separating the first question out is what
/// lets a policy answer it from statistics alone, because a store can score a
/// dimension without any judgement about relevance.
///
/// A policy returns a dimension, never a predicate and never a slice name. That
/// is not a stylistic choice: Constitution II forbids the model authoring an
/// input, and a dimension name checked against an engine-supplied candidate set
/// is the narrowest surface that still expresses a choice.
///
/// Obligations on an implementation, in full:
///
///   1. Charge every peek to the budget, and stop when it refuses.
///   2. Never touch the reserved synthesis slot.
///   3. Report partial evidence -- Sampled < Children, and Capped when a bound
///      bit. A score from 8 of 400 children presented as a measurement invites
///      an evaluator to trust an estimate.
///   4. Be deterministic. Ties break by position in `candidates`, which is the
///      store's declaration order. No wall clock, no randomness: a run that does
///      not replay cannot be scored against its alternatives.
///   5. Decline rather than guess. Splitting for the sake of splitting spends
///      budget producing slices nobody asked about.
///   6. Validate anything a model said against `candidates` before using it.
///   7. Never throw. A policy failure is a declined split with the reason
///      attached, because a coarse answer beats no answer.
Class RLM.Policy Extends %RegisteredObject [ Abstract ]
{

/// Most peeks one decision may spend, whatever the fanout.
///
/// Scoring a dimension costs one peek per child, so an uncapped decision costs
/// sum(children) -- unbounded in the store's widest column. Peeks are far cheaper
/// than model calls, but an unbounded loop inside a decision is a latency cliff
/// waiting for a 400-value column.
Property MaxPeeksPerDecision As %Integer [ InitialExpression = 12 ];

/// Most children of one dimension to evaluate, in declaration order.
///
/// Declaration order rather than a random sample, because a random sample makes
/// two runs over the same store choose differently and destroys replay.
Property MaxChildrenSampled As %Integer [ InitialExpression = 8 ];

/// Choose how to divide the current slice.
///
/// `candidates` is a %List of dimension names the engine has already established
/// are eligible. An implementation must not extend that set: a policy deriving
/// its own candidates could derive a different one, and then two policies over
/// the same store are not comparable, which defeats the seam.
Method ChooseSplit(
	source As RLM.Source,
	peek As %DynamicObject,
	candidates As %List,
	budget As RLM.Budget) As RLM.Decision [ Abstract ]
{
}

/// The children of a dimension as a %List of `token` values, in declaration
/// order, or "" if the dimension declares none.
///
/// Shared by every policy so they all read the store the same way; a policy that
/// enumerated children its own way would score a different set.
ClassMethod Children(
	source As RLM.Source,
	dimension As %String,
	Output sc As %Status) As %List
{
    Set sc = $$$OK, out = ""
    Set dims = source.Dimensions()
    If '$IsObject(dims) {
        Set sc = $$$ERROR($$$GeneralError, "store declares no dimensions")
        Quit ""
    }
    If 'dims.%IsDefined(dimension) {
        Set sc = $$$ERROR($$$GeneralError, "'"_dimension_"' is not a dimension of this store")
        Quit ""
    }
    Set spec = dims.%Get(dimension)
    If '$IsObject(spec) || '$IsObject(spec.children) {
        Set sc = $$$ERROR($$$GeneralError, "'"_dimension_"' declares no children")
        Quit ""
    }
    Set it = spec.children.%GetIterator()
    While it.%GetNext(, .child) {
        Continue:'$IsObject(child)
        Continue:child.token=""
        Set out = out_$ListBuild(child.token)
    }
    If out = "" {
        Set sc = $$$ERROR($$$GeneralError, "'"_dimension_"' declares no children")
    }
    Quit out
}

}
