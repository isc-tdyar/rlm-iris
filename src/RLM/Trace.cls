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

/// Append a split decision: a `decision` row plus a subtree holding the detail.
///
/// The detail is a sidecar rather than an eleventh field of the $LIST row. A
/// candidate list is variable-length and a $LIST row is positional, and
/// `$List(row, 11)` on a row written before this feature returns "" rather than
/// failing -- a silent wrong answer. Subscripts also make enumerating the
/// alternative arms a plain $Order walk, which is the operation offline
/// re-scoring is built on.
Method AddDecision(
	decision As RLM.Decision,
	depth As %Integer = 0,
	sourceClass As %String = "",
	sliceKey As %String = "") As %Integer
{
    Set note = $Select(decision.Chose():"split on "_decision.Dimension,
        1:"not decomposed")
    Set seq = ..Add("decision", depth, sliceKey, sourceClass,
        decision.MetricBefore, , , , decision.Capped, note)
    Set side = $ListBuild(decision.Dimension, decision.Reason,
        decision.MetricBefore, decision.MetricAfter, decision.PolicyClass,
        decision.PeeksSpent, decision.Capped)
    Do ..SetNode($ListBuild(seq, "d"), side)
    For i = 1:1:decision.Candidates.Count() {
        Set c = decision.Candidates.GetAt(i)
        Set row = $ListBuild(c.Dimension, c.Score, c.Children, c.Sampled, c.Error)
        Do ..SetNode($ListBuild(seq, "d", "cand", i), row)
        If c.ChildMetrics '= "" {
            Do ..SetNode($ListBuild(seq, "d", "cand", i, "m"), c.ChildMetrics)
        }
    }
    Quit seq
}

/// Write one sidecar node at the given subscript path.
///
/// The path is a %List rather than positional arguments because the tree is four
/// and five levels deep in places, and because $Select cannot choose between two
/// global references -- `^||` parses as an extended reference, not a value -- so
/// every write would otherwise need its own If/Else at its own depth.
Method SetNode(path As %List, value As %String) [ Private ]
{
    Set ref = $Select(..Durable:"^RLM.Trace(", 1:"^||RLM.Trace(")_..RunId
    Set ptr = 0
    While $ListNext(path, ptr, sub) {
        Set ref = ref_","_$Select(sub'?1.N:""""_sub_"""", 1:sub)
    }
    Set @(ref_")") = value
}

/// Rebuild the decisions of a run as RLM.Decision objects.
///
/// This is the reader User Story 3 exists for: a finished run can be re-scored
/// against the dimensions it did not choose without anyone hand-parsing a $LIST
/// row. Output `seqs` maps ordinal -> trace seq, so a caller can get back to the
/// row a decision came from.
ClassMethod Decisions(
	runId As %Integer,
	durable As %Boolean = 0,
	Output seqs) As %ListOfObjects
{
    Kill seqs
    Set out = ##class(%ListOfObjects).%New()
    Set seq = ""
    For  {
        If durable { Set seq = $Order(^RLM.Trace(runId, seq)) }
        Else { Set seq = $Order(^||RLM.Trace(runId, seq)) }
        Quit:seq=""
        If durable { Set has = $Data(^RLM.Trace(runId, seq, "d")) }
        Else { Set has = $Data(^||RLM.Trace(runId, seq, "d")) }
        Continue:'has
        If durable { Set side = ^RLM.Trace(runId, seq, "d") }
        Else { Set side = ^||RLM.Trace(runId, seq, "d") }
        Set d = ##class(RLM.Decision).%New($List(side, 5), $List(side, 3))
        If $List(side, 1) = "" {
            Do d.Decline($List(side, 2))
        } Else {
            Do d.Choose($List(side, 1), $List(side, 4), $List(side, 2))
        }
        Set d.PeeksSpent = $List(side, 6)
        Set d.Capped = $List(side, 7)
        Set n = ""
        For  {
            If durable { Set n = $Order(^RLM.Trace(runId, seq, "d", "cand", n)) }
            Else { Set n = $Order(^||RLM.Trace(runId, seq, "d", "cand", n)) }
            Quit:n=""
            If durable { Set row = ^RLM.Trace(runId, seq, "d", "cand", n) }
            Else { Set row = ^||RLM.Trace(runId, seq, "d", "cand", n) }
            Set c = d.AddCandidate($List(row, 1), $List(row, 2), $List(row, 3),
                $List(row, 4))
            Set c.Error = $List(row, 5)
            If durable { Set m = $Get(^RLM.Trace(runId, seq, "d", "cand", n, "m")) }
            Else { Set m = $Get(^||RLM.Trace(runId, seq, "d", "cand", n, "m")) }
            Set c.ChildMetrics = m
        }
        Do out.Insert(d)
        Set seqs(out.Count()) = seq
    }
    Quit out
}

/// How many rows a finished run wrote.
///
/// A class method over a run id, like Decisions and RLM.Report.RenderTrace: the
/// caller that wants to know whether a rendering dropped a row has the id and the
/// global, not the engine that made them.
ClassMethod RowCount(
	runId As %Integer,
	durable As %Boolean = 0) As %Integer
{
    Set n = 0, seq = ""
    For  {
        If durable { Set seq = $Order(^RLM.Trace(runId, seq)) }
        Else { Set seq = $Order(^||RLM.Trace(runId, seq)) }
        Quit:seq=""
        Set n = n + 1
    }
    Quit n
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
