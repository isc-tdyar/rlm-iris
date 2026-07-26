/// A recording `%AI.Policy.Audit`.
///
/// The audit seam is the reason this module exists rather than a subclass of
/// `RLM.LLM.REST` with a different URL: on an AI Hub instance a completion is logged by
/// a policy the instance owns and the run does not. What that policy is told is a
/// disclosure decision, so it is recorded here and asserted on rather than assumed.
///
/// Recording rather than mocking: the assertions are about the arguments -- the
/// duration, the status, and above all what is *not* in the descriptor.
Class UnitTest.RLMAIHub.StubAudit Extends %AI.Policy.Audit
{

Property Calls As %Integer [ InitialExpression = 0 ];

/// Each call's four dynamic arguments, as JSON, plus the duration and status.
Property SeenCall As %List;

Property SeenMetadata As %List;

Property SeenResult As %List;

Property SeenDuration As %List;

Property SeenStatus As %List;

/// 1 to throw on every call. An audit sink that fails must not turn a successful
/// completion into a failed one, and this is how a test proves it does not.
Property ThrowAlways As %Boolean [ InitialExpression = 0 ];

Method %LogExecution(
	call As %DynamicObject,
	metadata As %DynamicObject,
	result As %DynamicObject,
	duration As %Integer,
	status As %Status) As %Status
{
    Set ..Calls = ..Calls + 1
    Set ..SeenCall = ..SeenCall_$ListBuild($Select($IsObject(call):call.%ToJSON(), 1:""))
    Set ..SeenMetadata = ..SeenMetadata_$ListBuild($Select($IsObject(metadata):metadata.%ToJSON(), 1:""))
    Set ..SeenResult = ..SeenResult_$ListBuild($Select($IsObject(result):result.%ToJSON(), 1:""))
    Set ..SeenDuration = ..SeenDuration_$ListBuild(duration)
    Set ..SeenStatus = ..SeenStatus_$ListBuild(status)
    If ..ThrowAlways {
        Throw ##class(%Exception.General).%New("stub audit failure", 5001, , "the stub audit sink was asked to fail")
    }
    Quit $$$OK
}

/// Every JSON argument of the nth call concatenated, for a leak assertion that does
/// not have to name which argument a value should not be in.
Method AllOf(n As %Integer = 1) As %String
{
    If (n < 1) || (n > ..Calls) { Quit "" }
    Quit $List(..SeenCall, n)_" "_$List(..SeenMetadata, n)_" "_$List(..SeenResult, n)
}

}
