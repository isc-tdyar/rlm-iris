/// Tests for the split metric over a global.
///
/// The metric is the only thing that makes `RLM.Policy.Greedy` work on a store
/// with no schema. It has one job: answer "does splitting here divide the
/// population, or does it hand back one child holding everything?" A metric that
/// returned a constant would pass a self-consistency check and produce
/// decompositions that split on whatever comes first.
///
/// So the assertions are separations, not values: an even fixture must score high
/// and a skewed one low, on the same code path, with the threshold between them.
Class UnitTest.RLM.SourceGlobalMetric Extends %UnitTest.TestCase
{

Method OnBeforeOneTest(testname As %String) As %Status
{
    Do ##class(UnitTest.RLM.FixtureGlobal).Build()
    Quit $$$OK
}

ClassMethod On(ref As %String) As RLM.Source.Global
{
    Quit ##class(RLM.Source.Global).%New(ref, "^||RLM*", .sc)
}

/// `^||RLMBig` holds five level-1 subscripts of a hundred leaves each. Splitting
/// there genuinely divides the store, and the metric has to say so.
Method TestEvenChildrenScoreHigh()
{
    Set src = ..On(##class(UnitTest.RLM.FixtureGlobal).#BIGREF)
    Set m = src.SplitMetric(src.Peek(""))
    Do $$$AssertTrue(m > 0.9, "even children score high, got "_m)
}

/// `^||RLMSkew` puts 95 of its 100 leaves under one child. The split is almost
/// no split at all, and a metric that cannot tell this from the even case cannot
/// drive a policy.
Method TestSkewedChildrenScoreLow()
{
    Set src = ..On(##class(UnitTest.RLM.FixtureGlobal).#SKEWREF)
    Set m = src.SplitMetric(src.Peek(""))
    Do $$$AssertTrue(m < 0.3, "a 95% child scores low, got "_m)
}

/// The same assertion stated as an ordering, which is what the policy actually
/// consumes. Two thresholds could both be met by a metric that got the direction
/// backwards on some third store; the ordering could not.
Method TestEvenBeatsSkewed()
{
    Set even = ..On(##class(UnitTest.RLM.FixtureGlobal).#BIGREF)
    Set skew = ..On(##class(UnitTest.RLM.FixtureGlobal).#SKEWREF)
    Set ordered = even.SplitMetric(even.Peek("")) > skew.SplitMetric(skew.Peek(""))
    Do $$$AssertTrue(ordered, "dividing beats not dividing")
}

/// One child is not a division. Splitting on it costs a sub-call and produces a
/// slice identical to its parent, so `ShouldSplit` has to be false as well --
/// the score alone is advisory.
Method TestASingleChildScoresZero()
{
    Set src = ..On(##class(UnitTest.RLM.FixtureGlobal).#ONEREF)
    Set peek = src.Peek("")
    Do $$$AssertEquals(peek.children, 1, "the fixture has one child")
    Do $$$AssertEquals(src.SplitMetric(peek), 0, "which divides nothing")
    Do $$$AssertNotTrue(src.ShouldSplit(peek), "so it is not worth splitting")
}

/// An empty store has nothing to score and must return 0 rather than erroring on
/// a division by its own node count.
Method TestAnEmptySliceScoresZero()
{
    Set src = ##class(RLM.Source.Global).%New("^||RLMNoSuchXYZ", "^||RLM*", .sc)
    Do $$$AssertStatusOK(sc, "allowed and absent")
    Do $$$AssertEquals(src.SplitMetric(src.Peek("")), 0, "nothing to divide")
}

/// Across every slice of every fixture, in range. A normalized entropy that
/// leaves the range is an arithmetic bug that a threshold test can easily miss.
Method TestTheMetricIsInRange()
{
    Set f = "UnitTest.RLM.FixtureGlobal"
    Set refs = $ListBuild($parameter(f, "REF"), $parameter(f, "BIGREF"), $parameter(f, "ONEREF"), $parameter(f, "SKEWREF"))
    Set ptr = 0
    While $ListNext(refs, ptr, ref) {
        Set src = ..On(ref)
        Set m = src.SplitMetric(src.Peek(""))
        Do $$$AssertTrue((m >= 0) && (m <= 1), ref_" root scores "_m)

        // And at every child, where a per-slice division is done again.
        Set dims = src.Dimensions()
        Continue:'dims.%IsDefined("s1")
        Set it = dims.%Get("s1").children.%GetIterator()
        While it.%GetNext(, .child) {
            Set pred = src.Predicate($ListBuild("s1:"_child.token))
            Set cm = src.SplitMetric(src.Peek(pred))
            Do $$$AssertTrue((cm >= 0) && (cm <= 1), ref_" ["_child.label_"] scores "_cm)
        }
    }
}

/// Constitution V. Two peeks of a store nobody wrote to must serialize
/// identically -- the test that catches a clock, a random tie-break, or an
/// unrounded float whose text differs between calls.
Method TestPeekingTwiceIsIdentical()
{
    Set src = ..On(##class(UnitTest.RLM.FixtureGlobal).#REF)
    Set first = src.Peek("").%ToJSON()
    Set second = src.Peek("").%ToJSON()
    Do $$$AssertEquals(first, second, "byte-identical peeks")

    // And across instances, so nothing is cached on the object either.
    Set other = ..On(##class(UnitTest.RLM.FixtureGlobal).#REF)
    Do $$$AssertEquals(other.Peek("").%ToJSON(), first, "and across two sources")
}

/// The point of the metric: a whole decomposition chooses its splits from the
/// store's own statistics, and the model is called only to describe a slice and
/// to synthesize the answer.
///
/// Counted as "every model call is accounted for by a sub-call or a synthesis",
/// rather than as a raw total: the total varies with the fixture's fanout, and a
/// number that has to be updated whenever the fixture grows is a number nobody
/// trusts. A decision that quietly started calling the model would break the
/// identity while leaving any total-based assertion intact.
Method TestGreedyChoosesWithoutAModelCall()
{
    Set src = ..On(##class(UnitTest.RLM.FixtureGlobal).#REF)
    Set llm = ##class(RLM.LLM.Null).%New()
    Set greedy = ##class(RLM.Policy.Greedy).%New()
    Set engine = ##class(RLM.Engine).%New(src, llm, , greedy)
    Set report = engine.Run("what is in here", .traceId)
    Do $$$AssertNotEquals(report, "", "the run produced a document")

    Set decided = 0, spoken = 0, seq = ""
    For  {
        Set seq = $Order(^||RLM.Trace(traceId, seq))
        Quit:seq=""
        Set role = $ListGet($Get(^||RLM.Trace(traceId, seq)), 1)
        If role = "decision" { Set decided = decided + 1 }
        If (role = "subcall") || (role = "synthesis") { Set spoken = spoken + 1 }
    }
    Do $$$AssertTrue(decided > 0, "the run did decide something")
    Do $$$AssertEquals(llm.Calls, spoken, "and every model call was a subcall or a synthesis")
}

}
