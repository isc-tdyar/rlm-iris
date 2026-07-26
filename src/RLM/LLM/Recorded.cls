/// A language model that answers from a finished run's trace instead of from a
/// provider.
///
/// One entry per model call the run made through `RLM.Engine.Ask` -- every
/// `subcall` and the `synthesis` -- in seq order, which is the order the engine
/// makes them in. Each entry carries the text the model returned and the error it
/// returned instead, so a call that failed in the original fails here too. A
/// replay that repaired a failure would be reporting a run that never happened.
///
/// This is an `RLM.LLM` rather than a special engine mode because the replay must
/// go through the same engine as the run: a second renderer that "reproduces" a
/// report is a second implementation of the report, and the two drift.
Class RLM.LLM.Recorded Extends RLM.LLM
{

/// `$LB(text, errorNote)` per recorded call, in order.
Property Script As %List;

/// Calls served from the record.
Property Calls As %Integer [ InitialExpression = 0 ];

/// Calls asked for beyond the record. Non-zero means the replayed traversal made
/// a call the original did not, which is a mismatch and not a provider problem.
Property Overruns As %Integer [ InitialExpression = 0 ];

Method %OnNew(
	runId As %Integer,
	durable As %Boolean = 1) As %Status
{
    Set ..Script = ""
    Set ..Model = ""
    Set seq = ""
    For  {
        If durable { Set seq = $Order(^RLM.Trace(runId, seq), 1, row) }
        Else { Set seq = $Order(^||RLM.Trace(runId, seq), 1, row) }
        Quit:seq=""
        Quit:seq'?1.N
        Set role = $List(row, 1)
        Continue:(role'="subcall")&&(role'="synthesis")
        If ..Model = "" { Set ..Model = $List(row, 9) }
        Set ..Script = ..Script_$ListBuild($ListBuild(
            ##class(RLM.Trace).TextAt(runId, seq, durable), $List(row, 10)))
    }
    Quit $$$OK
}

/// How many calls the record can serve.
Method Length() As %Integer
{
    Quit $ListLength(..Script)
}

/// `instructions` and `prompt` are ignored on purpose. They are a function of the
/// store and the question, both of which are fixed, so re-deriving an answer from
/// them is the one thing a replay must not do.
Method Complete(
	instructions As %String,
	prompt As %String,
	Output sc As %Status) As %String
{
    Set sc = $$$OK
    Set ..Calls = ..Calls + 1
    If ..Calls > $ListLength(..Script) {
        Set ..Overruns = ..Overruns + 1
        // Assembled first: a macro's arguments cannot span lines (MPP5612).
        Set msg = "the replayed run asked for call "_..Calls_"; the record holds "
            _$ListLength(..Script)
        Set sc = $$$ERROR($$$GeneralError, msg)
        Quit ""
    }
    Set entry = $List(..Script, ..Calls)
    Set note = $ListGet(entry, 2)
    If note '= "" {
        // Reproduced as a failure, with the original's own words. The engine turns
        // this into the same caveat it wrote the first time.
        Set sc = $$$ERROR($$$GeneralError, note)
        Quit ""
    }
    Quit $ListGet(entry, 1)
}

}
