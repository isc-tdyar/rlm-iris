/// A provider that throws on its first call.
///
/// RLM.LLM tells implementations to return "" and set the status rather than
/// throw, and RLM.LLM.Null obeys -- which is exactly why it cannot test this. A
/// real provider is an HTTP client: a socket reset, a JSON parse of a truncated
/// body, or a %Net timeout all arrive as exceptions, and none of them should reach
/// a caller who asked for a document.
Class UnitTest.RLM.LLMThrows Extends RLM.LLM
{

/// Calls attempted, so a test can prove the throw happened on the call it meant.
Property Calls As %Integer [ InitialExpression = 0 ];

Method %OnNew() As %Status
{
    Set ..Model = "throws"
    Quit $$$OK
}

Method Complete(
	instructions As %String,
	prompt As %String,
	Output sc As %Status) As %String
{
    Set sc = $$$OK
    Set ..Calls = ..Calls + 1
    Throw ##class(%Exception.General).%New("LLMThrows", 5001, ,
        "the provider closed the connection on call "_..Calls)
}

}
