/// The only language-model surface the engine may touch.
///
/// One method, because that is all a decomposition needs: text in, text out.
/// Keeping it to one method is what makes the AI Hub and non-AI Hub variants
/// interchangeable -- RLM.Engine contains no reference to %AI.* or to any HTTP
/// client, so the portable module compiles on an IRIS with no AI Hub at all.
Class RLM.LLM Extends %RegisteredObject [ Abstract ]
{

/// Model identifier, for the trace. Two runs that differ only in model are not
/// comparable, so this is recorded rather than assumed.
Property Model As %String;

/// One completion. `instructions` is the system role, `prompt` the user turn.
///
/// Implementations must not throw: return "" and set the status. A failed call
/// should cost the run one slot, not the whole report.
Method Complete(
	instructions As %String,
	prompt As %String,
	Output sc As %Status) As %String [ Abstract ]
{
}

}
