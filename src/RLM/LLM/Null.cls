/// A scripted language model: returns canned replies and records what it was
/// asked.
///
/// This is what makes the engine testable. With a Null LLM and the fixture
/// Source, a decomposition is fully deterministic -- so tests can assert on the
/// exact prompt the engine built, which is the part that actually breaks.
///
/// Running past the end of the script is an error rather than a shrug: it means
/// the engine made a call the test did not expect, and that is exactly the
/// regression worth failing on.
Class RLM.LLM.Null Extends RLM.LLM
{

/// Replies to hand back, in order.
Property Script As %List;

/// Calls made so far, failures included.
Property Calls As %Integer [ InitialExpression = 0 ];

/// If set, the call with this ordinal returns an error instead of a reply.
Property FailAtCall As %Integer [ InitialExpression = 0 ];

/// Prompts and instructions received, by call ordinal.
Property Seen As array Of %String(STORAGEDEFAULT = "array");

Method %OnNew(script As %List = "") As %Status
{
    Set ..Script = script
    Set ..Model = "null"
    Quit $$$OK
}

Method Complete(
	instructions As %String,
	prompt As %String,
	Output sc As %Status) As %String
{
    Set sc = $$$OK
    Set ..Calls = ..Calls + 1
    Do ..Seen.SetAt(prompt, ..Calls_",prompt")
    Do ..Seen.SetAt(instructions, ..Calls_",instructions")

    If ..FailAtCall = ..Calls {
        Set sc = $$$ERROR($$$GeneralError, "scripted failure at call "_..Calls)
        Quit ""
    }
    If ..Calls > $ListLength(..Script) {
        Set msg = "RLM.LLM.Null: unscripted call "_..Calls_" (script has "
            _$ListLength(..Script)_" replies)"
        Set sc = $$$ERROR($$$GeneralError, msg)
        Quit ""
    }
    Quit $List(..Script, ..Calls)
}

/// The prompt given on call `n`, for assertions.
Method PromptAt(n As %Integer) As %String
{
    Quit ..Seen.GetAt(n_",prompt")
}

/// The instructions given on call `n`, for assertions.
Method InstructionsAt(n As %Integer) As %String
{
    Quit ..Seen.GetAt(n_",instructions")
}

}
