/// An RLM.Source.Interop whose namespace check the test controls.
///
/// Lives beside the source rather than under UnitTest because the only thing it
/// overrides is the one fact a test cannot arrange: whether this namespace has
/// interoperability enabled. Disabling interop in the container to assert that
/// refusal would leave every other interop test unable to run, and re-enabling it
/// afterwards is not something a failed test would get around to.
///
/// It also accepts a different extent, so the empty-store refusal can be asserted
/// over a fixture instead of by deleting the container's messages.
Class RLM.Source.InteropProbe Extends RLM.Source.Interop
{

Property Enabled As %Boolean [ InitialExpression = 1 ];

Method InteropEnabled() As %Boolean
{
    Quit ..Enabled
}

/// The dimensions the base declares are Ens.MessageHeader's columns, so over any
/// other extent only the extent is set: a dimension over a missing property is
/// refused by design, and this probe exists to assert Ready rather than the menu.
Method %OnNew(className As %String = "Ens.MessageHeader") As %Status
{
    If className = "Ens.MessageHeader" { Quit ##super(className) }
    Set ..ClassName = className
    Set ..Name = className
    Quit $$$OK
}

}
