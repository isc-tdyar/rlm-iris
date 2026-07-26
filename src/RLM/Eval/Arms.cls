/// Score, at every recorded decision, every candidate the run did not take.
///
/// This is what makes a trace an evaluation dataset rather than an audit log. The
/// counterfactual is answerable at all only because of Constitution II: the model
/// never authored a predicate, so every candidate on the record is a name the store
/// itself offered, and re-scoring one is a peek rather than a guess. A package
/// where the model wrote the query would have no way to ask "what if it had written
/// a different one" that did not involve writing one.
///
/// Zero model calls, on every path. `calls` is carried on the result and asserted
/// by the tests rather than assumed, because a field that is always 0 is the
/// cheapest possible place to catch a later change that made an arm consult a
/// model.
///
/// The scoring is `RLM.Policy.Greedy`'s: the size-weighted mean of the children's
/// split metrics, so an arm's score is directly comparable to the `metricAfter` a
/// Greedy run recorded for the dimension it did choose.
Class RLM.Eval.Arms Extends %RegisteredObject
{

/// Every unchosen candidate at every recorded decision, scored.
///
/// Returns `{arms: [...], peeks: n, capped: 0|1, calls: 0, error: ""}`. Never
/// throws: a failure to score one arm is that arm's `error` and a failure to read
/// the trace is the result's, because a caller enumerating a hundred runs must not
/// lose the other ninety-nine to one bad store.
ClassMethod Enumerate(
	source As RLM.Source,
	runId As %Integer,
	peekBudget As %Integer = 64,
	durable As %Boolean = 1) As %DynamicObject
{
    Set out = {"arms": [], "peeks": 0, "capped": 0, "calls": 0, "error": ""}
    Try {
        Do ..Walk(source, runId, peekBudget, durable, out)
    } Catch e {
        // Assigned, not returned: `Quit <value>` is #1043 inside a Catch.
        Set out.error = $ZStrip(e.Name_" "_e.Data, "<>W")
    }
    Quit out
}

/// The enumeration itself. Separate from Enumerate so the Catch there holds
/// whatever was scored before a failure -- a partial enumeration with an error on
/// it is more useful than an empty one.
ClassMethod Walk(
	source As RLM.Source,
	runId As %Integer,
	peekBudget As %Integer,
	durable As %Boolean,
	out As %DynamicObject) [ Private ]
{
    If durable, '$Data(^RLM.Trace(runId)) {
        Set out.error = "no durable trace exists for run "_runId
        Quit
    }

    Set decisions = ##class(RLM.Trace).Decisions(runId, durable, .seqs)
    If decisions.Count() = 0 {
        Set out.error = "run "_runId_" recorded no decisions"
        Quit
    }

    Set peeks = 0
    For i = 1:1:decisions.Count() {
        Set d = decisions.GetAt(i)
        Set seq = seqs(i)
        Set row = ..Row(runId, seq, durable)
        Set path = $ListGet(row, 4)
        Set chosen = $Select(d.Chose():d.Dimension, 1:"")

        For c = 1:1:d.Candidates.Count() {
            Set cand = d.Candidates.GetAt(c)
            Continue:cand.Dimension=chosen
            Set arm = {}
            Set arm.seq = seq
            Set arm.path = path
            Set arm.dimension = cand.Dimension
            Set arm.chosen = chosen
            Set arm.score = ""
            Set arm.peeks = 0
            Set arm.error = ""

            If peeks >= peekBudget {
                // Reported, not dropped. An arm with no score and the reason
                // "budget" is a fact; a missing arm is a silently shorter list.
                Set arm.error = "the peek budget was exhausted before this arm"
                Set out.capped = 1
                Do out.arms.%Push(arm)
                Continue
            }
            Set spent = ..Score(source, path, cand.Dimension,
                peekBudget - peeks, arm)
            Set peeks = peeks + spent
            Set arm.peeks = spent
            If arm.score = "", $Find(arm.error, "budget") { Set out.capped = 1 }
            Do out.arms.%Push(arm)
        }
    }
    Set out.peeks = peeks
}

/// Score one arm by peeking its children within `path`. Returns peeks spent and
/// writes `score` or `error` onto `arm`.
///
/// Children are enumerated through `RLM.Policy.Children` and predicates built
/// through `RLM.Policy.ChildPredicate` -- the same path a policy takes. Assembling
/// either here would score a slightly different population, and the difference
/// would be invisible in the number reported.
ClassMethod Score(
	source As RLM.Source,
	path As %String,
	dimension As %String,
	allowance As %Integer,
	arm As %DynamicObject) As %Integer [ Private ]
{
    Set kids = ##class(RLM.Policy).Children(source, dimension, .sc, path)
    If $$$ISERR(sc) {
        // The store no longer offers this dimension here. Refused, not invented:
        // the alternative is composing a predicate for a name the store did not
        // give, which is the authoring surface Constitution II denies.
        Set arm.error = $System.Status.GetErrorText(sc)
        Quit 0
    }

    Set n = $ListLength(kids)
    If n < 2 {
        Set arm.error = "'"_dimension_"' has fewer than two children here, so "
            _"splitting on it yields the parent"
        Quit 0
    }

    Set peeks = 0, sumN = 0, sumWeighted = 0, scored = 0
    For i = 1:1:n {
        If peeks >= allowance {
            Set arm.error = "the peek budget was exhausted after "_scored
                _" of "_n_" children"
            Quit
        }
        Set token = $ListGet(kids, i)
        Set peek = source.Peek(##class(RLM.Policy).ChildPredicate(source, path,
            dimension, token))
        Set peeks = peeks + 1
        If '$IsObject(peek) || (peek.error '= "") {
            Set arm.error = "the peek for '"_dimension_":"_token_"' failed"
            Quit
        }
        Set sumN = sumN + (+peek.n)
        Set sumWeighted = sumWeighted + ((+peek.n) * source.SplitMetric(peek))
        Set scored = scored + 1
    }

    // Fewer than two children scored says nothing about a split: one child is the
    // parent, and zero is no evidence. Reported as unscored rather than as a
    // number, because 0 already means "divides nothing" (FR-005).
    If (scored < 2) || (sumN = 0) {
        If arm.error = "" {
            Set arm.error = "fewer than two children could be scored"
        }
        Quit peeks
    }
    If scored < n {
        // Scored, and disclosed as partial. Constitution III: a score over 2 of 8
        // children presented as a measurement invites a reader to trust an
        // estimate.
        Set arm.error = "scored on "_scored_" of "_n_" children"
    }
    Set arm.score = sumWeighted / sumN
    Quit peeks
}

/// One trace row, from either global.
ClassMethod Row(
	runId As %Integer,
	seq As %Integer,
	durable As %Boolean) As %List [ Private ]
{
    If durable { Quit $Get(^RLM.Trace(runId, seq)) }
    Quit $Get(^||RLM.Trace(runId, seq))
}

}
