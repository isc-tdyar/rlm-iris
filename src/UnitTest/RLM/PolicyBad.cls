/// A policy that chooses the worst split it can find, on purpose.
///
/// US5 #2 asks that a regression in split quality fail a test. A scorecard that
/// only ever sees good policies cannot demonstrate that: every ranking it produces
/// is unfalsifiable. So this is the control -- it scores candidates exactly the way
/// `RLM.Policy.Greedy` does, and then picks the highest size-weighted child metric
/// instead of the lowest, and splits regardless of whether the split helps.
///
/// Deliberately no `MinImprovement` floor. Declining is Greedy's way of saying "no
/// division here is worth the calls", and a control that declined would be scored
/// as a run with no leaves rather than as a run with bad leaves.
Class UnitTest.RLM.PolicyBad Extends RLM.Policy
{

Method ChooseSplit(
	source As RLM.Source,
	peek As %DynamicObject,
	candidates As %List,
	budget As RLM.Budget,
	path As %String = "") As RLM.Decision
{
    Set before = source.SplitMetric(peek)
    Set d = ##class(RLM.Decision).%New($ClassName(), before)

    If $ListLength(candidates) = 0 {
        Do d.Decline("no dimension was available to split on")
        Quit d
    }

    Set peeks = 0, worst = "", worstScore = "", ptr = 0
    While $ListNext(candidates, ptr, dim) {
        Set kids = ..Children(source, dim, .csc, path)
        If $$$ISERR(csc) {
            Set c = d.AddCandidate(dim, "", 0, 0)
            Set c.Error = $System.Status.GetErrorText(csc)
            Continue
        }
        Set n = $ListLength(kids)
        Set c = d.AddCandidate(dim, "", n, 0)
        Set sumN = 0, sumWeighted = 0, sampled = 0
        For i = 1:1:n {
            If peeks >= ..MaxPeeksPerDecision {
                Set d.Capped = 1
                Quit
            }
            If $$$ISERR(budget.ChargePeek(1)) {
                Set d.Capped = 1
                Quit
            }
            Set peeks = peeks + 1
            Set childPeek = source.Peek(..ChildPredicate(source, path, dim,
                $ListGet(kids, i)))
            If '$IsObject(childPeek) || (childPeek.error '= "") {
                Set c.Error = "peek failed"
                Quit
            }
            Set sumN = sumN + (+childPeek.n)
            Set sumWeighted = sumWeighted
                + ((+childPeek.n) * source.SplitMetric(childPeek))
            Set sampled = sampled + 1
        }
        Set c.Sampled = sampled
        Continue:(sampled<2)||(sumN=0)
        Set score = sumWeighted / sumN
        Set c.Score = score
        If (worstScore = "") || (score > worstScore) {
            Set worstScore = score, worst = dim
        }
    }

    Set d.PeeksSpent = peeks
    If worst = "" {
        Do d.Decline("no candidate dimension could be scored")
        Quit d
    }
    Do d.Choose(worst, worstScore, "highest size-weighted child metric of "
        _d.Candidates.Count()_" candidate(s), which is the worst division "
        _"available: "_$FNumber(before, "", 3)_" -> "_$FNumber(worstScore, "", 3))
    Quit d
}

}
