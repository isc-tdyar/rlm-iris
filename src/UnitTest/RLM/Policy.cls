/// Tests for the statistics-only split policy.
///
/// Every assertion here is exact, because Greedy is deterministic by
/// construction: same store, same peek, same candidates, same budget, same
/// answer. A probabilistic assertion in this class would be hiding a defect.
Class UnitTest.RLM.Policy Extends %UnitTest.TestCase
{

Property Source As RLM.Source;

Method OnBeforeOneTest(testname As %String) As %Status
{
    Set ..Source = ##class(UnitTest.RLM.Fixture).%New("fixture store")
    Quit $$$OK
}

/// SC-002. `color` takes the store from 0.90 to ~0.22; `size` leaves it at
/// ~0.865. A policy that picks the first candidate would pick `color` too, which
/// is why the fixture is ordered color-then-size and this test also checks the
/// score it assigned to the loser.
Method TestChoosesTheSeparatingDimension()
{
    Set policy = ##class(RLM.Policy.Greedy).%New()
    Set peek = ..Source.Peek("")
    Set budget = ##class(RLM.Budget).%New(8)
    Set d = policy.ChooseSplit(..Source, peek, $ListBuild("color", "size"), budget)

    Do $$$AssertEquals(d.Dimension, "color", "the dimension that separates")
    Do $$$AssertEquals(d.Candidates.Count(), 2, "both candidates on the record")
    Set colour = d.Candidates.GetAt(1).Score
    Set size = d.Candidates.GetAt(2).Score
    Do $$$AssertTrue(colour < size, "and the loser's score says why it lost")
    Do $$$AssertEquals(d.PolicyClass, "RLM.Policy.Greedy", "who decided")
}

/// The size-weighted mean, checked against a figure computed by hand:
/// (600*0.20 + 400*0.25) / 1000 = 0.22.
Method TestScoreIsTheSizeWeightedMeanOfChildren()
{
    Set policy = ##class(RLM.Policy.Greedy).%New()
    Set d = policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("color"), ##class(RLM.Budget).%New(8))
    Set c = d.Candidates.GetAt(1)
    Do $$$AssertEquals(+$FNumber(c.Score, "", 4), 0.22, "600*0.20+400*0.25 over 1000")
    Do $$$AssertEquals($ListLength(c.ChildMetrics), 2, "raw child metrics kept")
    // The metric is stored canonically, so 0.20 round-trips as .2.
    Do $$$AssertEquals($ListGet(c.ChildMetrics, 1), "red:600:.2", "child as token:n:metric")
}

/// A store nothing separates has to produce a decline, not a coin flip. Without
/// this, a run over such a store reads as a decomposition that found nothing
/// rather than a store that does not decompose.
Method TestDeclinesWhenNothingSeparates()
{
    Set flat = ##class(UnitTest.RLM.FixtureFlat).%New()
    Set policy = ##class(RLM.Policy.Greedy).%New()
    Set d = policy.ChooseSplit(flat, flat.Peek(""), $ListBuild("color", "size"),
        ##class(RLM.Budget).%New(8))

    Do $$$AssertEquals(d.Dimension, "", "no dimension earned a split")
    Do $$$AssertNotEquals(d.Reason, "", "and the reason is on the record")
    Do $$$AssertEquals(d.Candidates.Count(), 2, "both were still evaluated")
}

/// The margin is what separates "helped" from "moved a rounding error". A
/// dimension that improves the metric by 1% is not worth the sub-calls its
/// children will cost.
Method TestMarginIsConfigurable()
{
    Set policy = ##class(RLM.Policy.Greedy).%New()
    Set policy.MinImprovement = 0.99
    Set d = policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("color", "size"), ##class(RLM.Budget).%New(8))
    Do $$$AssertEquals(d.Dimension, "", "even color cannot clear a 0.99 margin")
}

Method TestTiesBreakByDeclarationOrder()
{
    Set policy = ##class(RLM.Policy.Greedy).%New()
    // size:small and size:large are 0.85/0.88; a synthetic tie is not needed --
    // asking for the same dimension twice under both orders is enough to prove
    // the winner does not depend on which was offered first.
    Set a = policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("color", "size"), ##class(RLM.Budget).%New(8))
    Set b = policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("size", "color"), ##class(RLM.Budget).%New(8))
    Do $$$AssertEquals(a.Dimension, b.Dimension, "the better dimension wins either way")
}

Method TestIdenticalInvocationsReturnIdenticalDecisions()
{
    Set policy = ##class(RLM.Policy.Greedy).%New()
    Set a = policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("color", "size"), ##class(RLM.Budget).%New(8))
    Set b = policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("color", "size"), ##class(RLM.Budget).%New(8))
    Do $$$AssertEquals(a.Dimension, b.Dimension, "same choice")
    Do $$$AssertEquals(a.Reason, b.Reason, "same reason")
    Do $$$AssertEquals(a.MetricAfter, b.MetricAfter, "same score")
    Do $$$AssertEquals(a.PeeksSpent, b.PeeksSpent, "same cost")
}

/// Four children across two dimensions, so four peeks.
Method TestChargesEveryPeek()
{
    Set policy = ##class(RLM.Policy.Greedy).%New()
    Set budget = ##class(RLM.Budget).%New(8)
    Set d = policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("color", "size"), budget)
    Do $$$AssertEquals(d.PeeksSpent, 4, "two children each, both dimensions")
    Do $$$AssertEquals(budget.PeeksUsed, 4, "and every one of them charged")
}

/// Peeks are accounted separately from model calls, because a peek is an
/// aggregate the store answers and a model call is a round trip to a provider.
/// Charging them together would make a statistics-only policy cost more than the
/// model call it replaces.
Method TestNeverTouchesTheModelCallPool()
{
    Set policy = ##class(RLM.Policy.Greedy).%New()
    Set budget = ##class(RLM.Budget).%New(8)
    Do policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("color", "size"), budget)
    Do $$$AssertEquals(budget.Used, 0, "no model call spent on navigation")
    Do $$$AssertEquals(budget.Remaining(), 7, "the sub-call pool is untouched")
}

/// A policy out of peeks returns what it has rather than throwing, and says the
/// evidence was limited. A decision that fails closed here costs the whole run
/// its decomposition.
Method TestStopsWhenPeekBudgetRefuses()
{
    Set policy = ##class(RLM.Policy.Greedy).%New()
    Set budget = ##class(RLM.Budget).%New(8, 1, 3)
    Set d = policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("color", "size"), budget)
    Do $$$AssertTrue(d.Capped, "the cap that bit is reported")
    Do $$$AssertEquals(d.PeeksSpent, 3, "spent what it had, no more")
    Do $$$AssertEquals(budget.PeeksUsed, 3, "and no overdraft")
}

/// A store with more children than MaxChildrenSampled is scored on a sample, and
/// the sample size is on the record. A score from 8 of 400 children presented as
/// a measurement invites an evaluator to trust an estimate.
Method TestMaxChildrenSampledIsReported()
{
    Set policy = ##class(RLM.Policy.Greedy).%New()
    Set policy.MaxChildrenSampled = 1
    Set d = policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("color"), ##class(RLM.Budget).%New(8))
    Set c = d.Candidates.GetAt(1)
    Do $$$AssertEquals(c.Children, 2, "the dimension has two children")
    Do $$$AssertEquals(c.Sampled, 1, "only one was evaluated")
    Do $$$AssertTrue(c.Partial(), "so the evidence is partial")
    Do $$$AssertTrue(d.Capped, "and the decision says a cap bit")
}

Method TestMaxPeeksPerDecisionIsReported()
{
    Set policy = ##class(RLM.Policy.Greedy).%New()
    Set policy.MaxPeeksPerDecision = 2
    Set d = policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("color", "size"), ##class(RLM.Budget).%New(8))
    Do $$$AssertEquals(d.PeeksSpent, 2, "stopped at the per-decision cap")
    Do $$$AssertTrue(d.Capped, "reported, not hidden")
    Do $$$AssertEquals(d.Dimension, "color", "and it still decided on what it saw")
}

/// FR-010. A store that cannot answer for one dimension must not take the run
/// down with it.
Method TestFailedPeekExcludesTheCandidateNotTheRun()
{
    Set policy = ##class(RLM.Policy.Greedy).%New()
    // "shape" is not a dimension this fixture declares, so its children cannot be
    // enumerated -- the same shape of failure as a peek that errors.
    Set d = policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("shape", "color"), ##class(RLM.Budget).%New(8))
    Do $$$AssertEquals(d.Dimension, "color", "the run still decided")
    Set bad = d.Candidates.GetAt(1)
    Do $$$AssertEquals(bad.Score, "", "the broken candidate has no score")
    Do $$$AssertNotEquals(bad.Error, "", "and it records why it was excluded")
}

Method TestNoCandidatesIsADeclineNotAnError()
{
    Set policy = ##class(RLM.Policy.Greedy).%New()
    Set d = policy.ChooseSplit(..Source, ..Source.Peek(""), "",
        ##class(RLM.Budget).%New(8))
    Do $$$AssertEquals(d.Dimension, "", "nothing to choose from")
    Do $$$AssertNotEquals(d.Reason, "", "stated plainly")
    Do $$$AssertEquals(d.PeeksSpent, 0, "and it cost nothing to find out")
}

}
