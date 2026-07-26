/// Choose a split from the store's own statistics. No model call.
///
/// One peek per child, scored as the size-weighted mean of the children's split
/// metrics. Weighting by size is what makes the score answer the question that
/// matters -- "if I split here, how mixed is what I am left with?" A dimension
/// leaving 95% of the store in one still-mixed child has barely helped, and the
/// weighted mean says so where an unweighted mean would be flattered by a tiny
/// clean child.
///
/// The raw child metrics go on the record alongside the score, because any single
/// scalar loses the shape of the split, and "did this isolate an outlier or halve
/// the population?" is not answerable from the summary. It also means the
/// aggregation can change later without invalidating existing traces.
///
/// This class is the baseline every run can be scored against, precisely because
/// it costs nothing to compute and cannot vary.
Class RLM.Policy.Greedy Extends RLM.Policy
{

/// How much a dimension must reduce the metric to be worth splitting on, as a
/// fraction of the parent's metric.
///
/// A dimension that improves the metric by a rounding error is not worth the
/// sub-calls its children will cost, so "helped a little" and "did not help" are
/// deliberately the same answer here.
Property MinImprovement As %Numeric [ InitialExpression = 0.05 ];

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

    Set peeks = 0, best = "", bestScore = ""
    Set ptr = 0
    While $ListNext(candidates, ptr, dim) {
        Set kids = ..Children(source, dim, .csc, path)
        If $$$ISERR(csc) {
            // FR-010: excluded, recorded, and the run continues. A store that
            // cannot answer for one dimension must not take the decomposition
            // down with it.
            Set c = d.AddCandidate(dim, "", 0, 0)
            Set c.Error = $System.Status.GetErrorText(csc)
            Continue
        }

        Set nkids = $ListLength(kids)
        Set want = $Select(nkids > ..MaxChildrenSampled:..MaxChildrenSampled, 1:nkids)
        Set c = d.AddCandidate(dim, "", nkids, 0)
        If want < nkids { Set d.Capped = 1 }

        Set sumN = 0, sumWeighted = 0, metrics = "", sampled = 0, failed = ""
        For i = 1:1:want {
            If peeks >= ..MaxPeeksPerDecision {
                Set d.Capped = 1
                Quit
            }
            Set psc = budget.ChargePeek(1)
            If $$$ISERR(psc) {
                Set d.Capped = 1
                Set failed = $System.Status.GetErrorText(psc)
                Quit
            }
            Set peeks = peeks + 1

            Set token = $ListGet(kids, i)
            // Within `path`, not at the root: scoring the store-wide `size:small`
            // while dividing `colour:red` returns a real number about the wrong
            // population, which is worse than an error.
            Set childPeek = source.Peek(..ChildPredicate(source, path, dim, token))
            If '$IsObject(childPeek) || (childPeek.error '= "") {
                Set failed = "peek failed for '"_dim_":"_token_"'"
                Quit
            }
            Set n = +childPeek.n
            Set m = source.SplitMetric(childPeek)
            Set metrics = metrics_$ListBuild(token_":"_n_":"_m)
            Set sumN = sumN + n
            Set sumWeighted = sumWeighted + (n * m)
            Set sampled = sampled + 1
        }

        Set c.Sampled = sampled
        Set c.ChildMetrics = metrics
        Set c.Error = failed
        // Fewer than two children scored says nothing about the split: one child
        // is the parent, and zero is no evidence at all.
        If sampled < 2 {
            If c.Error = "" { Set c.Error = "fewer than two children could be scored" }
            Continue
        }
        // Two children can be scored and still hold no rows between them. A derived
        // dimension emits a fixed menu -- `hour` offers 24 buckets whether or not
        // any message landed in them -- so a small extent scores several empty
        // slices, and an n-weighted mean over them divides by zero. Reported as an
        // unscoreable candidate rather than as a score, because "every child was
        // empty" is a fact about this dimension and 0 would read as a perfect split.
        If sumN = 0 {
            Set c.Error = "every sampled child was empty, so the split cannot be scored"
            Continue
        }
        Set score = sumWeighted / sumN
        Set c.Score = score
        If (bestScore = "") || (score < bestScore) {
            Set bestScore = score, best = dim
        }
        // Out of peeks with candidates still unexamined. Capped is set here as
        // well as inside the child loop, because exhausting the cap exactly on a
        // dimension boundary limits the decision just as much as running out
        // mid-dimension does -- and the boundary case is the one that would
        // otherwise report a full evaluation.
        If (peeks >= ..MaxPeeksPerDecision) && ($ListNext(candidates, ptr, next)) {
            Set d.Capped = 1
            Quit
        }
    }

    Set d.PeeksSpent = peeks

    If best = "" {
        Do d.Decline("no candidate dimension could be scored"
            _$Select(d.Capped:" within the peeks available", 1:""))
        Quit d
    }

    Set floor = before * (1 - ..MinImprovement)
    If bestScore > floor {
        Set msg = "no dimension reduced the metric by the required "
            _(..MinImprovement * 100)_"% (best was "_best_" at "
            _$FNumber(bestScore, "", 3)_" against "_$FNumber(before, "", 3)
            _" for the whole slice)"
        Do d.Decline(msg)
        Quit d
    }

    Set reason = "lowest size-weighted child metric of "_d.Candidates.Count()
        _" candidate(s): "_$FNumber(before, "", 3)_" -> "_$FNumber(bestScore, "", 3)
    Do d.Choose(best, bestScore, reason)
    Quit d
}

}
