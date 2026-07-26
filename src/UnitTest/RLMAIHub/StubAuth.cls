/// A recording `%AI.Policy.Authorization` that can refuse or throw.
///
/// The authorization seam runs before the completion, which is the whole point of it:
/// an instance that will not permit a call should not be billed for one. So the tests
/// that use this stub assert the provider was never reached, not only that the status
/// came back wrong.
Class UnitTest.RLMAIHub.StubAuth Extends %AI.Policy.Authorization
{

Property Calls As %Integer [ InitialExpression = 0 ];

Property SeenTool As %List;

Property SeenCall As %List;

Property SeenMetadata As %List;

/// The status `%CanExecute` returns. Empty means OK; anything else is the refusal
/// reason, wrapped as an error.
Property RefuseWith As %String;

Property ThrowAlways As %Boolean [ InitialExpression = 0 ];

Method %CanExecute(
	tool As %String,
	call As %DynamicObject,
	metadata As %DynamicObject) As %Status
{
    Set ..Calls = ..Calls + 1
    Set ..SeenTool = ..SeenTool_$ListBuild(tool)
    Set ..SeenCall = ..SeenCall_$ListBuild($Select($IsObject(call):call.%ToJSON(), 1:""))
    Set ..SeenMetadata = ..SeenMetadata_$ListBuild($Select($IsObject(metadata):metadata.%ToJSON(), 1:""))
    If ..ThrowAlways {
        Throw ##class(%Exception.General).%New("stub auth failure", 5001, , "the stub authorization policy was asked to fail")
    }
    If ..RefuseWith '= "" { Quit $$$ERROR($$$GeneralError, ..RefuseWith) }
    Quit $$$OK
}

}
