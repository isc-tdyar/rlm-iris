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
Method Dimensions() As %DynamicObject [ Abstract ]
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

}
