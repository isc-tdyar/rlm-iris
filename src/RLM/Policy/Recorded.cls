/// A policy that returns the decisions a finished run made, in order.
///
/// The decisions come from `RLM.Trace.Decisions()`, which already rebuilds each
/// one with its candidate list, so this class reads a record rather than
/// re-deriving anything. It spends the budget the original decision spent -- calls
/// and peeks both -- because a report ends with what the run cost, and a replay
/// that cost nothing would print a different last line while claiming to be the
/// same document.
///
/// It is a policy, not a mode of the engine, so a replay traverses through exactly
/// the same code as the run it reproduces. Anything else is a second
/// implementation of the traversal, and two implementations of one traversal
/// disagree eventually.
Class RLM.Policy.Recorded Extends RLM.Policy
{

/// Recorded decisions, in trace order.
Property Recorded As %ListOfObjects;

/// `$LB(calls, peeks)` per recorded decision, parallel to Recorded.
Property Costs As %List;

/// Ordinal into Recorded, keyed by the slice path the decision was made on.
///
/// Served by path rather than in order, because not every recorded decision came
/// from a policy: when a store answers `ShouldSplit` false, the engine synthesizes
/// a declined decision and traces it without asking anyone. Those rows are on the
/// record and are not offered to a policy, so a positional replay drifts by one at
/// the first such slice and then reproduces a *different* traversal -- silently,
/// because every decision it serves is a real recorded decision, just not this
/// slice's. One decision per slice per run makes the path a key.
Property ByPath As array Of %Integer;

/// Decisions served so far.
Property Served As %Integer [ InitialExpression = 0 ];

/// Decisions asked for that the record does not hold for that slice. Non-zero
/// means the replayed traversal reached a slice the original did not decide, which
/// is a mismatch.
Property Overruns As %Integer [ InitialExpression = 0 ];

Method %OnNew(
	runId As %Integer,
	durable As %Boolean = 1) As %Status
{
    Set ..Recorded = ##class(RLM.Trace).Decisions(runId, durable, .seqs)
    Set ..Costs = ""
    For i = 1:1:..Recorded.Count() {
        Set ..Costs = ..Costs
            _$ListBuild(##class(RLM.Trace).DecisionCost(runId, seqs(i), durable))
        If durable { Set row = $Get(^RLM.Trace(runId, seqs(i))) }
        Else { Set row = $Get(^||RLM.Trace(runId, seqs(i))) }
        // Prefixed: the root's path is "", and a collection key of "" does not
        // store -- the entry would silently vanish and the root would replay as an
        // overrun.
        Do ..ByPath.SetAt(i, "p"_$List(row, 4))
    }
    Quit $$$OK
}

/// `source`, `peek` and `candidates` are ignored; `path` selects the recorded
/// decision. Ignoring the first three is the point: a decision is already on the
/// record, and re-deriving it would make the replay a second run rather than a
/// reproduction. `RLM.Replay` is what checks the store still agrees, once, before
/// any of this.
Method ChooseSplit(
	source As RLM.Source,
	peek As %DynamicObject,
	candidates As %List,
	budget As RLM.Budget,
	path As %String = "") As RLM.Decision
{
    Set i = ..ByPath.GetAt("p"_path)
    If i = "" {
        Set ..Overruns = ..Overruns + 1
        Set d = ##class(RLM.Decision).%New($ClassName(), source.SplitMetric(peek))
        Do d.Decline("no decision was recorded for this slice")
        Quit d
    }
    Set ..Served = ..Served + 1

    // Spend what the original spent, so the run's cost line matches. Charged
    // rather than assigned: the budget's own refusal is part of what a replay must
    // reproduce, and a replay that wrote Used directly could exceed a total the
    // original could not.
    Set cost = $List(..Costs, i)
    If cost '= "" {
        // Counter named apart from `i`: a `For i` here would overwrite the index
        // the decision is fetched by, and the replay would serve the *root's*
        // decision -- a legitimate recorded decision, for the wrong slice.
        For n = 1:1:+$ListGet(cost, 1) { Do budget.Charge(1) }
        Set peeks = +$ListGet(cost, 2)
        If peeks > 0 { Do budget.ChargePeek(peeks) }
    }
    Quit ..Recorded.GetAt(i)
}

}
