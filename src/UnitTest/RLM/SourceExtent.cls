/// Tests for RLM.Source.Extent: the SQL plumbing both RLM.Source.Interop and
/// RLM.Source.Audit sit on.
///
/// Extent is abstract -- it has no peek and no metric, because a message flow and
/// an audit log measure "mixed" differently and a shared answer would be wrong for
/// both. What is shared is everything that turns a dimension declaration into SQL,
/// and that is what is asserted here, through a minimal concrete subclass over a
/// real table.
///
/// A real table matters: every method under test writes SQL. A declarative fixture
/// would exercise none of it and would pass with the SQL broken.
///
/// Every assertion sits on one line: a macro's arguments cannot span source lines.
Class UnitTest.RLM.SourceExtent Extends %UnitTest.TestCase
{

Method OnBeforeOneTest(testname As %String) As %Status
{
    Quit ##class(UnitTest.RLM.FixtureExtent).Build()
}

Method OnAfterOneTest(testname As %String) As %Status
{
    Do ##class(UnitTest.RLM.FixtureExtent).Wipe()
    Quit $$$OK
}

/// A source over the fixture with both kinds of dimension declared.
ClassMethod Source() As UnitTest.RLM.ExtentProbe
{
    Set s = ##class(UnitTest.RLM.ExtentProbe).%New("UnitTest.RLM.FixtureExtent")
    Do s.AddDimension("region", "Region")
    Do s.AddDimension("channel", "Channel")
    Do s.AddBucketedDimension("size", "Amount", $ListBuild(50, 100))
    Quit s
}

/// A declaration checked against the dictionary, because a bad dimension would
/// otherwise produce broken SQL on every peek that used it and the run would look
/// like a store problem rather than a configuration one.
Method TestADimensionOverAMissingPropertyIsRefused()
{
    Set s = ##class(UnitTest.RLM.ExtentProbe).%New("UnitTest.RLM.FixtureExtent")
    Set sc = s.AddDimension("nope", "NoSuchProperty")
    Do $$$AssertStatusNotOK(sc, "a dimension over a missing property is refused")
    Set text = $System.Status.GetErrorText(sc)
    Do $$$AssertTrue($Find(text, "NoSuchProperty") > 0, "and names it: "_text)
    Do $$$AssertStatusOK(s.AddDimension("region", "Region"), "a real property is accepted")
}

/// The menu. Children are discovered from the data for a categorical dimension and
/// declared for a bucketed one, and a policy must not be able to tell which is
/// which.
Method TestDimensionsDiscoversCategoricalChildrenAndDeclaresBuckets()
{
    Set dims = ..Source().Dimensions()
    Do $$$AssertEquals(dims.region.children.%Size(), 3, "region has three children")
    Set tokens = ""
    For i = 0:1:dims.region.children.%Size() - 1 {
        Set tokens = tokens_dims.region.children.%Get(i).token_" "
    }
    Do $$$AssertTrue($Find(tokens, "north") > 0, "including north: "_tokens)
    Do $$$AssertTrue($Find(tokens, "south") > 0, "and south: "_tokens)
    Do $$$AssertTrue($Find(tokens, "east") > 0, "and east: "_tokens)
    // Two nulls are not a child. A null-valued row is in no slice of this
    // dimension, which is what NullCount discloses.
    Do $$$AssertEquals(dims.channel.children.%Size(), 2, "channel has two children, not three")
    // Three breakpoints' worth of children from two edges: below, between, above.
    Do $$$AssertEquals(dims.size.children.%Size(), 3, "two breakpoints make three buckets")
    Do $$$AssertEquals(dims.size.children.%Get(0).token, "b0", "bucket tokens are ordinals")
}

/// A bucketed dimension needs something to divide with.
Method TestABucketedDimensionWithNoBreakpointIsRefused()
{
    Set s = ##class(UnitTest.RLM.ExtentProbe).%New("UnitTest.RLM.FixtureExtent")
    Set sc = s.AddBucketedDimension("size", "Amount", "")
    Do $$$AssertStatusNotOK(sc, "no breakpoint is refused")
    Set sc2 = s.AddBucketedDimension("size", "Amount", $ListBuild(100, 50))
    Do $$$AssertStatusNotOK(sc2, "and descending breakpoints are refused")
    Set sc3 = s.AddBucketedDimension("size", "Amount", $ListBuild(50, 50))
    Do $$$AssertStatusNotOK(sc3, "and so are equal ones")
}

/// Predicate encodes and Where decodes. The two are asserted together because the
/// only thing that matters about the encoding is that the decoder agrees with it.
Method TestAPredicateRoundTripsThroughWhere()
{
    Set s = ..Source()
    Set p = s.Predicate($ListBuild("region:north"))
    Set where = s.WhereProbe(p, .args)
    Do $$$AssertTrue($Find(where, "WHERE") > 0, "a categorical term becomes a WHERE: "_where)
    Do $$$AssertTrue($Find(where, "?") > 0, "with the value bound, not spliced: "_where)
    Do $$$AssertEquals($ListLength(args), 1, "one bound value")
    Do $$$AssertEquals($ListGet(args, 1), "north", "and it is the token")
}

/// A middle bucket is bounded on both sides; the first and last are bounded on one.
/// Getting this wrong makes children over-count or under-count their parent.
Method TestABucketTermIsBoundedOnBothSidesOnlyInTheMiddle()
{
    Set s = ..Source()
    Do s.WhereProbe(s.Predicate($ListBuild("size:b1")), .mid)
    Do $$$AssertEquals($ListLength(mid), 2, "the middle bucket binds two values")
    Do s.WhereProbe(s.Predicate($ListBuild("size:b0")), .lo)
    Do $$$AssertEquals($ListLength(lo), 1, "the first bucket binds one")
    Do s.WhereProbe(s.Predicate($ListBuild("size:b2")), .hi)
    Do $$$AssertEquals($ListLength(hi), 1, "and so does the last")
}

/// Two components are one conjunction. A predicate that dropped the second would
/// return the parent's figures for a child slice -- plausible numbers about the
/// wrong population.
Method TestTwoComponentsBecomeOneConjunction()
{
    Set s = ..Source()
    Set where = s.WhereProbe(s.Predicate($ListBuild("region:north", "channel:web")), .args)
    Do $$$AssertTrue($Find(where, "AND") > 0, "two terms are ANDed: "_where)
    Do $$$AssertEquals($ListLength(args), 2, "with two bound values")
}

/// The SQL name comes from the dictionary, not from the class name. Package to
/// schema is not a string transformation: `User` maps to `SQLUser`, and a derived
/// `USER` is a reserved word that fails to parse.
Method TestTheTableNameIsReadFromTheDictionary()
{
    Set name = ..Source().SQLTableProbe()
    Do $$$AssertNotEquals(name, "", "a table name came back: "_name)
    Set rs = ##class(RLM.Source.Extent).Query("SELECT COUNT(*) AS n FROM "_name, .sc)
    Do $$$AssertStatusOK(sc, "and it names a table SQL can query: "_name)
    Do rs.%Next()
    Do $$$AssertEquals(+rs.%Get("n"), ##class(UnitTest.RLM.FixtureExtent).Total(), "holding the fixture's rows")
}

/// The bounded distribution: the whole point is that a slice with ten thousand
/// distinct groups costs the same peek as one with three.
Method TestTheDistributionIsBoundedAndOrderedByCount()
{
    Set s = ..Source()
    Set dist = s.DistributionProbe("", $ListBuild("Region"), 2, .total)
    Do $$$AssertEquals(dist.%Size(), 2, "a top-2 distribution has two entries, not three")
    Do $$$AssertEquals(dist.%Get(0).n, 5, "ordered by count descending: north's 5 first")
    Do $$$AssertEquals(dist.%Get(0).key, "north", "and keyed by the value")
    // The covered total is what the entropy's remainder bucket is computed from, so
    // it must count the whole slice rather than the truncated part.
    Do $$$AssertEquals(total, ##class(UnitTest.RLM.FixtureExtent).Total(), "the total covers every row")
}

/// Normalized entropy, with the properties a policy relies on: 0 when one group
/// holds everything, 1 when they are even, and something between when skewed.
Method TestEntropyIsZeroForOneGroupAndOneForAnEvenSplit()
{
    Set one = ##class(RLM.Source.Extent).Entropy($ListBuild(10), 10)
    Do $$$AssertEquals(one, 0, "one group holding everything scores 0")
    Set even = ##class(RLM.Source.Extent).Entropy($ListBuild(5, 5), 10)
    Do $$$AssertEquals(even, 1, "two even groups score 1")
    Set skew = ##class(RLM.Source.Extent).Entropy($ListBuild(9, 1), 10)
    Do $$$AssertTrue(skew > 0, "a skewed split scores above 0: "_skew)
    Do $$$AssertTrue(skew < 1, "and below 1: "_skew)
    Set none = ##class(RLM.Source.Extent).Entropy("", 0)
    Do $$$AssertEquals(none, 0, "nothing to divide scores 0")
}

/// The remainder past the top k counts as one more group. Understating evenness is
/// the safe direction: it cannot make a useless split look good.
Method TestEntropyCountsTheRemainderAsOneGroup()
{
    // 4+3 named of 10: the missing 3 must appear as a third group rather than
    // being dropped, which would make the split look more even than it is.
    Set withRest = ##class(RLM.Source.Extent).Entropy($ListBuild(4, 3), 10)
    Set without = ##class(RLM.Source.Extent).Entropy($ListBuild(4, 3), 7)
    Do $$$AssertNotEquals(withRest, without, "an uncovered remainder changes the score")
}

/// The reconciliation guarantee, at the level it is implemented: rows a dimension
/// cannot cover are counted so a report can disclose them.
Method TestNullCountClosesTheGapForACategoricalDimension()
{
    Set s = ..Source()
    Set nulls = s.NullCount("", "channel")
    Set want = ##class(UnitTest.RLM.FixtureExtent).ChannelNulls()
    Do $$$AssertEquals(nulls, want, "the null rows are counted")
    Do $$$AssertEquals(s.NullCount("", "region"), 0, "and a dimension with no nulls reports 0")
    Do $$$AssertEquals(s.NullCount("", ""), 0, "and no dimension reports 0 rather than the table")
}

/// A cap is a floor. The bound is on the rows counted, not on the one aggregate row
/// that comes back -- a cap applied to the wrong thing does nothing at all.
Method TestARowCapIsReportedAndBoundsTheCount()
{
    Set s = ..Source()
    Set s.MaxRows = 5
    Set n = s.CountProbe("", .capped)
    Do $$$AssertEquals(n, 5, "the count stops at the cap")
    Do $$$AssertEquals(capped, 1, "and says it was capped")
    Set s.MaxRows = 0
    Set n2 = s.CountProbe("", .capped2)
    Do $$$AssertEquals(n2, ##class(UnitTest.RLM.FixtureExtent).Total(), "uncapped counts every row")
    Do $$$AssertEquals(capped2, 0, "and says so")
}

}
