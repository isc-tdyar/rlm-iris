/// The store a decomposition runs over.
///
/// A Source answers three questions and nothing else: how may this store be
/// split (Dimensions), what does one slice look like in aggregate (Peek), and
/// how should those aggregates be worded for a language model (Describe).
///
/// The contract is deliberately narrow because of what it guarantees. A Source
/// never returns rows, nodes or values -- only statistics -- so the context a
/// root model accumulates is bounded by the number of slices it inspects rather
/// than by the size of the store. A 400-node global and a 400-million-node
/// global cost the same to characterize.
///
/// Two invariants every subclass must hold:
///
/// 1. The model never authors a predicate. Peek enumerates what exists; the
///    model picks a token from that enumeration; RLM.Slice refuses anything
///    else. There is no injection surface because there is no place for the
///    model to write one.
/// 2. Caps are reported, never hidden. If a Peek stopped early it must say so
///    in the peek object, because a silently truncated count is worse than no
///    count: the model treats it as a total and every downstream claim inherits
///    the error.
Class RLM.Source Extends %RegisteredObject [ Abstract ]
{

/// Human-readable name of the store, used in reports and traces.
Property Name As %String;

/// The decomposition whitelist.
///
/// Returns an object keyed by dimension name, each holding a `label` and a
/// `children` array of `{"token": ..., "label": ...}`. This is the complete set
/// of legal moves; a dimension or token absent from here cannot be reached.
///
/// `path` is the slice the moves are being asked for, "" for the whole store. A
/// flat store ignores it: a table's columns and their values are the same
/// wherever you stand. A hierarchical store cannot -- the level-2 subscripts
/// under `^G("2019-11-04")` are not those under `^G("2020-03-11")` -- and a
/// store that answered from the root would advertise children that do not exist
/// under the given parent, or resolve a legal slice to the wrong subtree. Both
/// failures return plausible figures about a different population, which is
/// worse than a refusal.
Method Dimensions(path As %String = "") As %DynamicObject [ Abstract ]
{
}

/// Translate a resolved list of `dim:token` components into whatever this store
/// uses to restrict a slice -- a SQL predicate, a subscript prefix, a filter
/// object. Called only by RLM.Slice, and only with components it has already
/// checked against Dimensions().
Method Predicate(components As %List) As %String [ Abstract ]
{
}

/// Aggregate statistics for one slice. Must include `n` (row or node count) and
/// `capped` (1 if the count stopped at a limit). On failure return an object
/// with an `error` property rather than throwing: a failed peek should cost the
/// run one call, not the whole report.
Method Peek(predicate As %String = "") As %DynamicObject [ Abstract ]
{
}

/// Render a peek as self-labelling metric lines for the prompt.
///
/// Self-labelling matters: the model must quote figures under the exact name it
/// was given them under, and it cannot do that if the lines are positional.
Method Describe(label As %String, peek As %DynamicObject) As %String [ Abstract ]
{
}

/// The normalized 0-1 scalar a policy compares across candidate splits: how
/// much this slice still mixes distinct populations.
///
/// Each store defines its own. A numeric aggregate has a relative spread; a
/// subscript walk has fanout entropy or child-count skew; there is no single
/// metric that means anything in both. Normalizing here is what lets
/// RLM.Policy.Greedy work over any Source without knowing what the store is.
Method SplitMetric(peek As %DynamicObject) As %Numeric [ Abstract ]
{
}

/// Whether a slice is worth splitting further. Overridable per store; the
/// default asks only whether the slice is still mixed enough to bother.
Method ShouldSplit(peek As %DynamicObject, threshold As %Numeric = 0.15) As %Boolean
{
    Quit ..SplitMetric(peek) > threshold
}

/// Whether this store is fit to report on at all.
///
/// Concrete rather than abstract, and returning 1, because "present but not fit
/// to report on" is a state most stores do not have -- and an existing source
/// must not need editing to stay ready.
///
/// A store that overrides this to return 0 owes the caller a `reason` it can act
/// on. The alternative to the whole mechanism is averaging over whichever rows
/// happen to be usable, which produces a document that is both confident and
/// wrong.
Method Ready(Output reason As %String) As %Boolean
{
    Set reason = ""
    Quit 1
}

/// Rows inside `predicate` that `dimension` covers with no child, so that its
/// children do not sum to their parent.
///
/// Concrete and returning 0, because a dimension enumerated from the data has no
/// such rows by construction: every value it found is a child. Only a dimension
/// whose children are declared -- a bucket set over a nullable column -- can miss
/// rows, and only that store knows how many.
///
/// The engine asks so it can disclose the gap. A store that has one and reports 0
/// produces a report whose figures do not reconcile, which is Constitution III's
/// concern rather than a rounding matter.
Method NullCount(
	predicate As %String = "",
	dimension As %String = "") As %Integer
{
    Quit 0
}

}
