/// Tests for subscript shape without subscript content.
///
/// This is what lets a model say "level 1 is a date and level 2 is a facility
/// code" having read neither. It gets a type tally, two moments of the value
/// lengths, and the busiest few children by name -- and from that it can reason
/// about a 40 GB global it will never see a byte of.
///
/// The load-bearing assertion in this class is TestPeekSizeIsIndependentOfStoreSize.
/// Everything else in the package is a design claim; that one is the measurement.
Class UnitTest.RLM.SourceGlobalShape Extends %UnitTest.TestCase
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

/// Numeric, string and list counts against the numbers written down in the
/// fixture. `$ISVALIDNUM` is the classifier, and it calls "2019-11-04" a string
/// and "42" a number, which is what makes the tally worth reporting.
Method TestSubscriptTypeMix()
{
    Set f = "UnitTest.RLM.FixtureGlobal"
    Set peek = ..On($parameter(f, "REF")).Peek("")
    Do $$$AssertEquals(peek.subNumeric, $classmethod(f, "RootSubNumeric"), "numeric subscripts")
    Do $$$AssertEquals(peek.subString, $classmethod(f, "RootSubString"), "string subscripts")
    Do $$$AssertEquals(peek.subList, $classmethod(f, "RootSubList"), "list subscripts")
}

/// The three counts partition the children exactly. A classifier that counted a
/// subscript twice would report a mix that reads plausibly and sums wrong, and a
/// model comparing "3 of 5 are dates" against a total would be comparing against
/// the wrong total.
Method TestTypeMixPartitionsTheChildren()
{
    Set f = "UnitTest.RLM.FixtureGlobal"
    Set refs = $ListBuild($parameter(f, "REF"), $parameter(f, "BIGREF"), $parameter(f, "ONEREF"), $parameter(f, "SKEWREF"))
    Set ptr = 0
    While $ListNext(refs, ptr, ref) {
        Set peek = ..On(ref).Peek("")
        Set total = peek.subNumeric + peek.subString + peek.subList
        Do $$$AssertEquals(total, peek.children, ref_": the mix sums to the children")
    }
}

/// Mean and population sd against hand computation. The fixture's nine values
/// have lengths 2,2,2,5,5,5,8,8,8: mean exactly 5, variance exactly 6.
Method TestValueLengthMoments()
{
    Set f = "UnitTest.RLM.FixtureGlobal"
    Set peek = ..On($parameter(f, "REF")).Peek("")
    Set wantMean = $classmethod(f, "ValueLenMean")
    Set wantSd = $classmethod(f, "ValueLenSd")
    Do $$$AssertTrue($ZAbs(peek.valueLenMean - wantMean) < 0.01, "mean is "_peek.valueLenMean)
    Do $$$AssertTrue($ZAbs(peek.valueLenSd - wantSd) < 0.01, "sd is "_peek.valueLenSd)
}

/// A slice with no values at all reports 0 for both rather than dividing by its
/// own data-node count. `^||RLMTest(7)` is a pure pointer node.
Method TestMomentsAreZeroWithNoValues()
{
    Set src = ..On(##class(UnitTest.RLM.FixtureGlobal).#REF)
    Set peek = src.Peek("")
    Do $$$AssertTrue(peek.dataNodes > 0, "the root does hold values")

    Set empty = ##class(RLM.Source.Global).%New("^||RLMNoSuchXYZ", "^||RLM*", .sc)
    Set epeek = empty.Peek("")
    Do $$$AssertEquals(epeek.valueLenMean, 0, "no values, no mean")
    Do $$$AssertEquals(epeek.valueLenSd, 0, "and no spread")
}

/// A single value has a mean and a spread of zero, not a <FUNCTION> from a
/// negative variance. Floating point makes the variance of one sample very
/// slightly negative often enough to matter.
Method TestASingleValueHasZeroSpread()
{
    Set src = ..On(##class(UnitTest.RLM.FixtureGlobal).#ONEREF)
    Set peek = src.Peek("")
    Do $$$AssertEquals(peek.dataNodes, 1, "exactly one value")
    Do $$$AssertEquals(peek.valueLenSd, 0, "so no spread")
    Do $$$AssertTrue(peek.valueLenMean > 0, "but a mean")
}

/// `topFanout` is bounded, ordered descending, and every token in it round-trips
/// to the label beside it -- so a model naming the busiest child names a slice
/// that resolves.
Method TestTopFanoutIsBoundedAndOrdered()
{
    Set src = ..On(##class(UnitTest.RLM.FixtureGlobal).#BIGREF)
    Set src.TopN = 3
    Set peek = src.Peek("")
    Do $$$AssertTrue(peek.topFanout.%Size() <= 3, "bounded at TopN")
    Do $$$AssertTrue(peek.topFanout.%Size() > 0, "and not empty")

    Set prev = "", it = peek.topFanout.%GetIterator()
    While it.%GetNext(, .child) {
        If prev '= "" {
            Do $$$AssertTrue(child.n <= prev, "descending: "_child.n_" after "_prev)
        }
        Set prev = child.n
        Set back = ##class(RLM.Source.Global).Decode(child.token)
        Do $$$AssertEquals(back, child.label, "token round-trips to its label")
    }

    // ^||RLMBig's children are all the same size, so the loop above only ever
    // compared equal counts -- it would pass on an unsorted list. The skewed
    // fixture is where the ordering is actually load-bearing: the busiest child
    // is the one a model asked to follow the data should be shown first.
    Set skew = ..On(##class(UnitTest.RLM.FixtureGlobal).#SKEWREF)
    Set top = skew.Peek("").topFanout
    Do $$$AssertTrue(top.%Size() > 1, "more than one child to order")
    Do $$$AssertEquals(top.%Get(0).label, "hot", "the busiest child comes first")
    Do $$$AssertTrue(top.%Get(0).n > top.%Get(1).n, "strictly ahead of the next")
}

/// The package's central claim, measured. A store a hundred times larger must
/// produce a peek of essentially the same size, because the peek is aggregates
/// over a bounded walk and not a sample of the data.
Method TestPeekSizeIsIndependentOfStoreSize()
{
    Set f = "UnitTest.RLM.FixtureGlobal"
    Set small = ..On($parameter(f, "REF")).Peek("").%ToJSON()
    Set big = ..On($parameter(f, "BIGREF")).Peek("").%ToJSON()

    // Both fit in a paragraph. If a peek ever grew with the store, this is the
    // assertion that would catch it before a 40 GB global did.
    Do $$$AssertTrue($Length(small) < 2000, "the small peek is "_$Length(small)_" chars")
    Do $$$AssertTrue($Length(big) < 2000, "the big peek is "_$Length(big)_" chars")

    // ^||RLMBig holds roughly 25x the nodes of ^||RLMTest. The peeks may differ
    // by a few digits of a count; they must not differ by a factor.
    Set ratio = $Select($Length(small) = 0: 0, 1: $Length(big) / $Length(small))
    Do $$$AssertTrue((ratio > 0.9) && (ratio < 1.1), "size ratio is "_ratio)
}

/// Constitution I, SC-006. A value planted at exactly one node must appear in no
/// peek, no description and no prompt the engine builds. This is the assertion
/// that would fail the day someone adds a "sample value" field for debugging.
Method TestNoStoredValueReachesTheDescription()
{
    Set secret = ##class(UnitTest.RLM.FixtureGlobal).PlantSecret()
    Set src = ..On(##class(UnitTest.RLM.FixtureGlobal).#REF)

    Set peek = src.Peek("")
    Do $$$AssertEquals(peek.%ToJSON() [ secret, 0, "no value in the peek")
    Do $$$AssertEquals(src.Describe("^||RLMTest", peek) [ secret, 0, "nor in the description")

    // And nowhere in a whole run's output. RLM.LLM.Null records the prompts it
    // was given, so this covers what the model would have been shown as well as
    // what the reader sees.
    Set llm = ##class(RLM.LLM.Null).%New()
    Set greedy = ##class(RLM.Policy.Greedy).%New()
    Set engine = ##class(RLM.Engine).%New(src, llm, , greedy)
    Set report = engine.Run("what is in here", .traceId)
    Do $$$AssertEquals(report [ secret, 0, "nor in the report")

    Set key = "", leaked = 0
    For  {
        Set text = llm.Seen.GetNext(.key)
        Quit:key=""
        If text [ secret { Set leaked = leaked + 1 }
    }
    Do $$$AssertEquals(leaked, 0, "nor in any prompt the model was given")
    Do $$$AssertTrue(llm.Calls > 0, "and the model was in fact called")
}

}
