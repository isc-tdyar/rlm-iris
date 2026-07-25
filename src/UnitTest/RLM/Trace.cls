/// Tests for reading a decision back out of a trace.
///
/// What is being protected is offline evaluation. A run is worth tracing only if
/// the arms it did not take are recoverable afterwards, because otherwise the
/// trace records a conclusion and not the evidence -- and a policy cannot be
/// scored against a conclusion.
///
/// Every assertion here reads the global directly or through
/// RLM.Trace.Decisions(), never through the engine that wrote it: the reader in
/// six months has the global and the store, not the objects.
Class UnitTest.RLM.Trace Extends %UnitTest.TestCase
{

/// A decision with one scored winner, one scored loser, and one candidate that
/// could not be evaluated -- the three states a reader has to distinguish.
ClassMethod Written(Output trace As RLM.Trace) As %Integer
{
    Set trace = ##class(RLM.Trace).%New()
    Set d = ##class(RLM.Decision).%New("RLM.Policy.Greedy", 0.90)
    Do d.Choose("color", 0.22, "lowest size-weighted child metric")
    Set c = d.AddCandidate("color", 0.22, 2, 2)
    Set c.ChildMetrics = $ListBuild("red:600:.2", "blue:400:.25")
    Set c2 = d.AddCandidate("size", 0.865, 2, 2)
    Set c2.ChildMetrics = $ListBuild("small:500:.85", "large:500:.88")
    Set c3 = d.AddCandidate("shape", "", 0, 0)
    Set c3.Error = "no such dimension"
    Set d.PeeksSpent = 4
    Quit trace.AddDecision(d, 0, "UnitTest.RLM.Fixture", "")
}

/// $Order over the candidate subtree, which is the operation re-scoring is built
/// on. A count read from a field would go stale the moment a candidate was added.
Method TestEveryCandidateIsEnumerableByOrder()
{
    Set seq = ..Written(.trace)
    Set dims = "", n = ""
    For  {
        Set n = $Order(^||RLM.Trace(trace.RunId, seq, "d", "cand", n), 1, row)
        Quit:n=""
        Set dims = dims_$Select(dims="":"", 1:",")_$List(row, 1)
    }
    Do $$$AssertEquals(dims, "color,size,shape", "all three, in declaration order")
}

/// The raw child metrics are the part a summary score cannot reconstruct: "did
/// this isolate an outlier or halve the population?" is only answerable from them.
Method TestChildMetricsSurviveTheRoundTrip()
{
    Set seq = ..Written(.trace)
    Set decisions = ##class(RLM.Trace).Decisions(trace.RunId, 0, .seqs)
    Set d = decisions.GetAt(1)
    Set c = d.Candidates.GetAt(1)

    Do $$$AssertEquals($ListLength(c.ChildMetrics), 2, "both children")
    Do $$$AssertEquals($ListGet(c.ChildMetrics, 1), "red:600:.2", "first child intact")
    Do $$$AssertEquals($ListGet(c.ChildMetrics, 2), "blue:400:.25", "and the second")
    Do $$$AssertEquals(seqs(1), seq, "and the row it came from is identifiable")
}

/// FR-010. A candidate that could not be evaluated must be distinguishable from
/// one that scored badly, or an evaluator counts an absence as a rejection.
Method TestFailedCandidateRecordsItsError()
{
    Do ..Written(.trace)
    Set decisions = ##class(RLM.Trace).Decisions(trace.RunId)
    Set c = decisions.GetAt(1).Candidates.GetAt(3)

    Do $$$AssertEquals(c.Dimension, "shape", "the candidate is still on the record")
    Do $$$AssertEquals(c.Score, "", "with no score")
    Do $$$AssertNotEquals(c.Error, "", "and the reason it has none")
    Set loser = decisions.GetAt(1).Candidates.GetAt(2)
    Do $$$AssertEquals(loser.Error, "", "a mere loser carries no error")
}

/// The decision's own fields, not just its candidates: who decided, what it cost,
/// and what it moved the metric from and to.
Method TestDecisionFieldsSurviveTheRoundTrip()
{
    Do ..Written(.trace)
    Set d = ##class(RLM.Trace).Decisions(trace.RunId).GetAt(1)

    Do $$$AssertEquals(d.Dimension, "color", "the chosen dimension")
    Do $$$AssertEquals(d.PolicyClass, "RLM.Policy.Greedy", "who chose it")
    Do $$$AssertEquals(d.MetricBefore, 0.90, "the parent's metric")
    Do $$$AssertEquals(d.MetricAfter, 0.22, "and the score of the winner")
    Do $$$AssertEquals(d.PeeksSpent, 4, "what the decision cost")
    Do $$$AssertNotEquals(d.Reason, "", "and why")
}

/// A decline is a decision and must read back as one. A run that decomposed
/// nothing is not the same as a run that recorded nothing, and only the reason
/// separates them.
Method TestDeclineReadsBackAsADecline()
{
    Set trace = ##class(RLM.Trace).%New()
    Set d = ##class(RLM.Decision).%New("RLM.Policy.Greedy", 0.90)
    Do d.AddCandidate("color", 0.89, 2, 2)
    Do d.Decline("no dimension reduced the metric by the required 5%")
    Do trace.AddDecision(d, 0, "UnitTest.RLM.FixtureFlat", "")

    Set back = ##class(RLM.Trace).Decisions(trace.RunId).GetAt(1)
    Do $$$AssertNotTrue(back.Chose(), "still a decline after the round trip")
    Do $$$AssertNotEquals(back.Reason, "", "and it still says why")
    Do $$$AssertEquals(back.Candidates.Count(), 1, "with the arm it rejected")
}

/// Rows that made no decision must not appear in the reader's output, or a
/// sub-call is counted as a decomposition step.
Method TestRowWithoutDecisionSubtreeIsSkipped()
{
    Set trace = ##class(RLM.Trace).%New()
    Do trace.Add("subcall", 1, "color:red", "UnitTest.RLM.Fixture")
    Do trace.Add("synthesis", 0, "", "UnitTest.RLM.Fixture")

    Set decisions = ##class(RLM.Trace).Decisions(trace.RunId)
    Do $$$AssertEquals(decisions.Count(), 0, "neither row decided anything")
}

/// Two runs in one process share the global, so a reader given one run id must
/// see only that run. This is what the process-private global's first subscript
/// is for, and getting it wrong mixes two decompositions into one report.
Method TestDecisionsAreScopedToTheirRun()
{
    Set a = ..Written(.traceA)
    Set b = ..Written(.traceB)
    Do $$$AssertNotEquals(traceA.RunId, traceB.RunId, "distinct runs")
    // Hoisted: a $$$macro(...) call cannot span source lines.
    Set na = ##class(RLM.Trace).Decisions(traceA.RunId).Count()
    Set nb = ##class(RLM.Trace).Decisions(traceB.RunId).Count()
    Do $$$AssertEquals(na, 1, "one decision in the first run")
    Do $$$AssertEquals(nb, 1, "and one in the second")
}

}
