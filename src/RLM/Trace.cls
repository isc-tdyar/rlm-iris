/// A structured record of one decomposition, one row per model call.
///
/// This is a record, not a log. An earlier prototype traced decompositions as
/// display strings, which made it impossible to tell a root decision from a
/// sub-agent's own peek -- a six-slice plan printed eight lines and read as a
/// budget violation. So `role` is the first field of every row.
///
/// Because a peek is a pure function of a frozen store, a trace plus the store
/// is enough to replay a run with no model call at all. That is what makes
/// offline evaluation -- and later, learning a policy -- possible, and it is why
/// the model is never allowed to author code: model-authored code is not a
/// function of the store, so it does not replay.
///
/// Rows live in a process-private global by default so a run leaves nothing
/// behind. Set Durable to write to ^RLM.Trace instead.
Class RLM.Trace Extends %RegisteredObject
{

/// Identifier of this run, unique within the process.
Property RunId As %Integer;

/// Next row ordinal.
Property Seq As %Integer [ InitialExpression = 0 ];

/// Write to ^RLM.Trace rather than the process-private ^||RLM.Trace.
Property Durable As %Boolean [ InitialExpression = 0 ];

Method %OnNew(durable As %Boolean = 0) As %Status
{
    Set ..Durable = durable
    // $Select cannot choose between two global references -- `^||` is parsed as
    // an extended reference, not as a value -- so the branch is explicit.
    If durable {
        Set ..RunId = $Increment(^RLM.Trace)
    } Else {
        Set ..RunId = $Increment(^||RLM.Trace)
    }
    Quit $$$OK
}

/// Append a row.
///
/// `role` is one of plan / subcall / synthesis / refused / capped. `metrics` is
/// an optional %DynamicObject of per-source figures, kept out of the $LIST row
/// because what a store measures is the store's business, not the trace's.
Method Add(
	role As %String,
	depth As %Integer = 0,
	sliceKey As %String = "",
	sourceClass As %String = "",
	splitMetric As %Numeric = "",
	tokensIn As %Integer = "",
	tokensOut As %Integer = "",
	model As %String = "",
	capped As %Boolean = 0,
	note As %String = "") As %Integer
{
    // $Increment cannot take an object property.
    Set seq = ..Seq + 1
    Set ..Seq = seq
    Set row = $ListBuild(role, depth, sourceClass, sliceKey, splitMetric,
        capped, tokensIn, tokensOut, model, note)
    If ..Durable {
        Set ^RLM.Trace(..RunId, seq) = row
    } Else {
        Set ^||RLM.Trace(..RunId, seq) = row
    }
    Quit seq
}

/// Read one row back, for assertions and for replay.
Method Row(seq As %Integer) As %List
{
    If ..Durable { Quit $Get(^RLM.Trace(..RunId, seq)) }
    Quit $Get(^||RLM.Trace(..RunId, seq))
}

/// How many model calls this run recorded in a given role, or in total.
Method Count(role As %String = "") As %Integer
{
    Set n = 0, seq = ""
    For  {
        Set row = ..Row($Increment(seq))
        Quit:row=""
        If (role = "") || ($List(row, 1) = role) { Set n = n + 1 }
    }
    Quit n
}

}
