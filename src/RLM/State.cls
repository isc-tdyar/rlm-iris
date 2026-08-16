/// A run's shared scratchpad, keyed by the slice that wrote it.
///
/// Sub-calls in a REPL-based RLM are independent map operations: each sees its own
/// subset and nothing else, and whatever it learns dies with the process holding
/// the variable. That is a property of the substrate rather than of the method --
/// a Python local has nowhere to put a finding that outlives the call that made it.
///
/// A global does, and three things follow that the flat version cannot have. A
/// later slice can read what an earlier one found instead of rediscovering it. A
/// run that exhausted its budget can be resumed against what it already
/// established rather than restarted. And the result of a decomposition becomes a
/// queryable artifact -- a mapping, a set of per-record determinations, a growing
/// map of an undocumented system -- rather than a paragraph that has to be
/// regenerated to be used again.
///
/// Process-private by default, so an exploratory run and a test clean up after
/// themselves. Durable when the run is durable, which is exactly the case where
/// resuming is the point.
///
/// Keys are slice paths, so state and trace agree about what identifies a slice
/// without either having to know the other exists. The empty path is the root,
/// which is where a run's own question and answer belong.
///
/// Paths are stored prefixed rather than raw, because IRIS rejects a null
/// subscript and the root's path is the empty string. Sub() is the only place
/// that knows this, and the prefix is constant, so paths keep their collation
/// order relative to each other and the root sorts first without a special case.
///
/// Every global access copies ..Root into a local before the indirection. `@..Root@(...)`
/// is not reliably a legal indirection target -- the operand wants a variable rather
/// than a property reference -- and the failure would be at compile time on every
/// method here at once.
Class RLM.State Extends %RegisteredObject
{

/// The run this state belongs to. Shared with the trace, so a finding can be read
/// back beside the calls that produced it.
Property RunId As %Integer;

/// Global root, `^RLM.State` or the process-private `^||RLM.State`.
Property Root As %String [ Private ];

/// Whether writes survive the process.
Property Durable As %Boolean [ InitialExpression = 0 ];

/// The subscript a slice path is stored under.
///
/// `^RLM.State(runId, "")` is not a legal global reference -- IRIS throws
/// `<SUBSCRIPT>` on a null subscript -- and the root slice's path is exactly the
/// empty string. Prefixing keeps every subscript non-null without changing what a
/// path means to anything outside this class.
ClassMethod Sub(path As %String) As %String [ Private ]
{
	Quit "p" _ path
}

Method %OnNew(
	runId As %Integer,
	durable As %Boolean = 0) As %Status
{
	Set ..RunId = runId
	Set ..Durable = durable
	Set ..Root = $Select(durable:"^RLM.State", 1:"^||RLM.State")
	Quit $$$OK
}

/// Record one finding against one slice.
///
/// Last write wins, because a slice revisited by a deeper run has learned more
/// than the shallower one did, and keeping both would make Findings() ambiguous
/// about which is current. A caller wanting a history writes distinct keys.
Method Put(
	path As %String,
	key As %String,
	value As %String) As %Status
{
	If key = "" { Quit $$$ERROR($$$GeneralError, "a state key may not be empty") }
	Set ref = ..Root
	Set @ref@(..RunId, ..Sub(path), key) = value
	Quit $$$OK
}

/// Read one finding back, or `default` if this slice never wrote it.
///
/// A default rather than a status because every caller of this is asking whether
/// work has already been done, and "no" is an ordinary answer to that rather than
/// a failure.
Method Get(
	path As %String,
	key As %String,
	default As %String = "") As %String
{
	Set ref = ..Root
	If '$Data(@ref@(..RunId, ..Sub(path), key)) { Quit default }
	Quit @ref@(..RunId, ..Sub(path), key)
}

/// Whether this slice has recorded `key` already.
///
/// Distinct from Get() returning "" because a finding may legitimately be empty,
/// and a resumed run deciding whether to redo work must be able to tell "recorded
/// nothing" from "never ran".
Method Has(
	path As %String,
	key As %String) As %Boolean
{
	Set ref = ..Root
	Quit ''$Data(@ref@(..RunId, ..Sub(path), key))
}

/// Every key this slice wrote, in collation order.
Method Keys(path As %String = "") As %List
{
	Set ref = ..Root
	Set out = "", key = ""
	For {
		Set key = $Order(@ref@(..RunId, ..Sub(path), key))
		Quit:key=""
		Set out = out_$ListBuild(key)
	}
	Quit out
}

/// Every slice this run wrote anything for, in collation order.
///
/// The traversal is pre-order and paths sort by their own text rather than by
/// visit order, so this is a stable enumeration of what was established and not a
/// replay of how it was reached. The trace is where order lives.
Method Paths() As %List
{
	Set ref = ..Root
	Set out = "", sub = ""
	For {
		Set sub = $Order(@ref@(..RunId, sub))
		Quit:sub=""
		Set out = out_$ListBuild($Extract(sub, 2, *))
	}
	Quit out
}

/// Every `path` that recorded `key`, as `path|value` rows.
///
/// One list rather than a callback or a result set, because the callers are a
/// synthesis prompt and a resumption check, and both want the whole of a small
/// thing rather than a cursor over a large one.
Method Findings(key As %String = "finding") As %List
{
	Set out = "", paths = ..Paths(), ptr = 0
	While $ListNext(paths, ptr, path) {
		Continue:'..Has(path, key)
		Set out = out_$ListBuild(path_"|"_..Get(path, key))
	}
	Quit out
}

/// How many findings this run has recorded, across every slice and key.
Method Count() As %Integer
{
	Set n = 0, paths = ..Paths(), ptr = 0
	While $ListNext(paths, ptr, path) {
		Set n = n + $ListLength(..Keys(path))
	}
	Quit n
}

/// Discard everything this run wrote.
///
/// An instance method rather than a class method taking a run id, so a caller
/// cannot clear a run it does not hold -- including one still in progress in
/// another process, which durable state makes possible for the first time.
Method Clear() As %Status
{
	Set ref = ..Root
	Kill @ref@(..RunId)
	Quit $$$OK
}

}
