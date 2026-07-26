/// A scripted `%AI.Provider` that never reaches a network.
///
/// `%AI.Provider.ChatComplete` is a concrete method whose body is a `$ZF(-6)`
/// callout into the LLM library. Overriding it in a subclass replaces the callout
/// entirely, so a whole decomposition runs with no provider configured, no key, and
/// nothing to reach -- which is what Constitution IV requires of every test here.
///
/// It also records what it was called with. Half the assertions in this milestone
/// are about the request rather than the reply: that the messages array is exactly
/// system-then-user, that `MaxTokens` arrived, that the engine made one call per
/// decision and not a loop's worth.
Class UnitTest.RLMAIHub.StubProvider Extends %AI.Provider
{

/// Replies, in order. Running past the end is an error rather than a repeat: it
/// means the engine made a call no test anticipated (Constitution IV).
Property Script As %List;

/// 1-based index of a call that should throw instead of replying, mimicking how
/// `%AI.*` signals failure. 0 for none.
Property ThrowOnCall As %Integer [ InitialExpression = 0 ];

/// Usage object returned with every reply, as JSON. "" to return none at all --
/// which a provider is entitled to do, and which must not read as truncation.
Property UsageJSON As %String;

/// Return "" instead of a response object. Nothing in the platform promises this
/// cannot happen, and the consequence in the caller is an `<INVALID OREF>` -- a
/// throw, which is the one thing `RLMAIHub.Provider` promises not to do.
Property ReturnNothing As %Boolean [ InitialExpression = 0 ];

Property Calls As %Integer [ InitialExpression = 0 ];

/// The arguments of each call, so the request can be asserted on.
Property SeenModel As %List;

Property SeenMessages As %List;

Property SeenTemperature As %List;

Property SeenMaxTokens As %List;

/// `script` is a `$ListBuild` list, declared `%String` because it must be: an
/// override of `%OnNew` may only widen `%RegisteredObject`'s `initvalue As %String`,
/// and `%Library.List` is not a subclass of `%Library.String` (`ERROR #5478`). A
/// `$List` is a string at runtime, so nothing is lost but the declaration.
Method %OnNew(script As %String = "") As %Status
{
    Set ..Script = script
    Quit $$$OK
}

Method ChatComplete(
	model As %String,
	messages As %DynamicArray,
	temperature As %Float = "",
	maxTokens As %Integer = "",
	topP As %Float = "",
	frequencyPenalty As %Float = "",
	presencePenalty As %Float = "") As %AI.LLM.Response
{
    Set ..Calls = ..Calls + 1
    Set ..SeenModel = ..SeenModel_$ListBuild(model)
    Set ..SeenMessages = ..SeenMessages_$ListBuild(messages.%ToJSON())
    Set ..SeenTemperature = ..SeenTemperature_$ListBuild(temperature)
    Set ..SeenMaxTokens = ..SeenMaxTokens_$ListBuild(maxTokens)

    If ..ThrowOnCall = ..Calls {
        Throw ##class(%Exception.General).%New("stub provider failure", 5001, , "the stub was asked to fail on call "_..Calls)
    }
    If ..Calls > $ListLength(..Script) {
        Throw ##class(%Exception.General).%New("stub script exhausted", 5001, , "call "_..Calls_" was not anticipated by a "_$ListLength(..Script)_"-reply script")
    }

    If ..ReturnNothing { Quit "" }

    Set obj = {"content": ($List(..Script, ..Calls))}
    If ..UsageJSON '= "" { Set obj.usage = {}.%FromJSON(..UsageJSON) }
    Quit ##class(%AI.LLM.Response).FromJSON(obj)
}

/// The messages array of the nth call, parsed.
Method MessagesOf(n As %Integer = 1) As %DynamicArray
{
    If (n < 1) || (n > $ListLength(..SeenMessages)) { Quit [] }
    Quit [].%FromJSON($List(..SeenMessages, n))
}

}
