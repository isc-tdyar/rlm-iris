/// Tests for RLM.Source.Interop, over real Ens.MessageHeader rows.
///
/// Real rows rather than a fixture extent, because the whole claim of this source is
/// that it decomposes a live message flow: the extent, the column names, the status
/// enumeration and the timestamp type all come from Ensemble, and a stand-in class
/// would assert none of them. A test that passed over a fixture and failed over
/// Ens.MessageHeader would be worse than no test.
///
/// The rows this test plants are deleted by recorded id in OnAfterOneTest -- never by
/// wiping the extent. The extent may hold rows this test did not create (a shipped
/// container does), so every count is asserted against a baseline taken before the
/// insert rather than against the planted number.
///
/// Every assertion sits on one line: a macro's arguments cannot span source lines.
Class UnitTest.RLM.SourceInterop Extends %UnitTest.TestCase
{

/// Ids of the rows this test planted, so they can be removed without touching
/// anything else in the extent.
Property Planted As %List;

/// Rows in the extent before the insert.
Property Baseline As %Integer;

/// A marker in a header's Description, so a leak test has something to look for.
ClassMethod Marker() As %String
{
    Quit "SECRET-INTEROP-4c81"
}

/// The planted distribution, chosen so no assertion can pass by coincidence:
///
/// ```text
/// source    target    status                 hour
/// --------  --------  ---------------------  ----
/// RLMSRCA   RLMTGTX   9 Completed            2
/// RLMSRCA   RLMTGTX   9 Completed            2
/// RLMSRCA   RLMTGTY   9 Completed            5
/// RLMSRCA   RLMTGTY   8 Error                5
/// RLMSRCB   RLMTGTX   8 Error                5
/// RLMSRCB   RLMTGTY   9 Completed           11
/// RLMSRCC   RLMTGTX   3 Delivered           11
/// ```
///
/// Seven rows: source sizes 4/2/1 (uneven), two errors, two targets, three distinct
/// hours out of the 24 the dimension always offers, and one status outside the
/// error/completed pair.
ClassMethod Rows() As %List
{
    Quit $ListBuild(
        "RLMSRCA|RLMTGTX|9|2", "RLMSRCA|RLMTGTX|9|2",
        "RLMSRCA|RLMTGTY|9|5", "RLMSRCA|RLMTGTY|8|5",
        "RLMSRCB|RLMTGTX|8|5", "RLMSRCB|RLMTGTY|9|11",
        "RLMSRCC|RLMTGTX|3|11")
}

Method OnBeforeOneTest(testname As %String) As %Status
{
    Set ..Baseline = ..Count()
    Set ..Planted = ""
    Set ptr = 0
    While $ListNext(..Rows(), ptr, row) {
        Set h = ##class(Ens.MessageHeader).%New()
        Set h.SourceConfigName = $Piece(row, "|", 1)
        Set h.TargetConfigName = $Piece(row, "|", 2)
        Set h.Status = $Piece(row, "|", 3)
        Set h.Type = 1
        Set h.Priority = 2
        Set h.Description = ..Marker()
        // A fixed date so the hour bucketing is asserted against a known value rather
        // than against whenever the suite happens to run. Zero-padded by taking the
        // last two characters of "0"_hour: $Justify pads on the left with spaces and
        // there is no left-aligning form of it.
        Set hour = $Extract("0"_$Piece(row, "|", 4), *-1, *)
        Set h.TimeCreated = "2026-07-20 "_hour_":30:00"
        Set sc = h.%Save()
        If $$$ISERR(sc) { Quit }
        Set ..Planted = ..Planted_$ListBuild(h.%Id())
    }
    Quit $Get(sc, $$$OK)
}

Method OnAfterOneTest(testname As %String) As %Status
{
    Set ptr = 0
    While $ListNext(..Planted, ptr, id) {
        Do ##class(Ens.MessageHeader).%DeleteId(id)
    }
    Set ..Planted = ""
    Quit $$$OK
}

/// Rows in the extent right now.
ClassMethod Count() As %Integer
{
    Set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT COUNT(*) AS n FROM Ens.MessageHeader")
    If 'rs.%Next() { Quit 0 }
    Quit +rs.%Get("n")
}

/// A source over the planted rows only, so a stray row in the extent cannot change
/// what an assertion sees.
Method Source() As RLM.Source.Interop
{
    Set s = ##class(RLM.Source.Interop).%New()
    Quit s
}

/// The predicate naming just this test's rows: every planted source, and nothing
/// else. Used where an assertion has to be exact about counts.
Method Mine() As %String
{
    Quit ..Source().Predicate($ListBuild("source:RLMSRCA"))
}

/// The menu. Four dimensions, with the config names taken from the data rather than
/// from a configured production -- a source that only worked against a running
/// production would be untestable and would refuse on most machines.
Method TestDimensionsOffersSourceTargetStatusAndHour()
{
    Set dims = ..Source().Dimensions()
    Do $$$AssertTrue(dims.%IsDefined("source"), "source is a dimension")
    Do $$$AssertTrue(dims.%IsDefined("target"), "target is a dimension")
    Do $$$AssertTrue(dims.%IsDefined("status"), "status is a dimension")
    Do $$$AssertTrue(dims.%IsDefined("hour"), "hour is a dimension")
    Set tokens = ""
    For i = 0:1:dims.source.children.%Size() - 1 {
        Set tokens = tokens_dims.source.children.%Get(i).token_" "
    }
    Do $$$AssertTrue($Find(tokens, "RLMSRCA") > 0, "the planted sources are children: "_tokens)
    Do $$$AssertTrue($Find(tokens, "RLMSRCB") > 0, "including the second: "_tokens)
    Do $$$AssertTrue($Find(tokens, "RLMSRCC") > 0, "and the third: "_tokens)
}

/// The peek over one known slice, asserted exactly. RLMSRCA's four rows: three
/// completed and one error, across two targets, busiest target RLMTGTX with two.
Method TestPeekMatchesThePlantedDistribution()
{
    Set s = ..Source()
    Set peek = s.Peek(s.Predicate($ListBuild("source:RLMSRCA")))
    Do $$$AssertEquals(peek.n, 4, "the slice holds four rows")
    Do $$$AssertEquals(peek.errors, 1, "one of them is an error")
    Do $$$AssertEquals(peek.sources, 1, "one source config")
    Do $$$AssertEquals(peek.targets, 2, "two target configs")
    Do $$$AssertEquals(peek.busiest, "RLMTGTX", "and the busiest target is named")
}

/// A cap is disclosed rather than silently applied, and the description words the
/// count as a floor. A capped count read as exact is a wrong number presented as a
/// right one.
Method TestACappedPeekSaysSoAndDescribesTheCountAsAFloor()
{
    Set s = ..Source()
    Set s.MaxRows = 3
    Set peek = s.Peek("")
    Do $$$AssertEquals(peek.capped, 1, "the peek says it was capped")
    Do $$$AssertEquals(peek.n, 3, "and stopped at the cap")
    Set text = s.Describe("all", peek)
    Do $$$AssertTrue($Find(text, "at least") > 0, "the description is a floor: "_text)
    Set s2 = ..Source()
    Set plain = s2.Describe("all", s2.Peek(..Mine()))
    Do $$$AssertTrue($Find(plain, "at least") = 0, "an uncapped one is not: "_plain)
}

/// The metric: how mixed the slice's source-target routing is. 0 when every message
/// takes the same route, higher when they take several.
Method TestSplitMetricIsZeroForOneRouteAndHigherForSeveral()
{
    Set s = ..Source()
    Set one = s.SplitMetric(s.Peek(s.Predicate($ListBuild("source:RLMSRCC"))))
    Do $$$AssertEquals(one, 0, "a slice on one route scores 0")
    Set mixed = s.SplitMetric(s.Peek(s.Predicate($ListBuild("source:RLMSRCA"))))
    Do $$$AssertTrue(mixed > 0, "a slice over two routes scores above 0: "_mixed)
    Do $$$AssertTrue(mixed <= 1, "and never above 1: "_mixed)
}

/// Constitution I, at the level this source can enforce it: a described slice carries
/// counts and config names, never message content. The marker is planted in every
/// planted header's Description.
Method TestNoBodyOrDescriptionReachesTheDescribedText()
{
    Set s = ..Source()
    Set peek = s.Peek(..Mine())
    Set text = s.Describe("mine", peek)
    Do $$$AssertTrue($Find(text, ..Marker()) = 0, "the description carries no marker: "_text)
    Do $$$AssertTrue($Find(peek.%ToJSON(), ..Marker()) = 0, "and neither does the peek")
    Set json = peek.%ToJSON()
    Do $$$AssertTrue($Find(json, "MessageBody") = 0, "no body class name: "_json)
    Do $$$AssertTrue($Find(json, "Description") = 0, "and no description key: "_json)
}

/// The status enumeration is described by its meaning, and a code outside the
/// enumeration is described by its value and marked unknown rather than dropped --
/// a dropped status is a slice that silently holds no rows.
Method TestAStatusCodeIsLabelledAndAnUnknownOneIsKept()
{
    Set dims = ..Source().Dimensions()
    Set labels = ""
    For i = 0:1:dims.status.children.%Size() - 1 {
        Set labels = labels_dims.status.children.%Get(i).token_"="_dims.status.children.%Get(i).label_" "
    }
    Do $$$AssertTrue($Find(labels, "Error") > 0, "the error code is labelled: "_labels)
    Do $$$AssertTrue($Find(labels, "Completed") > 0, "and so is completed: "_labels)
    Set unknown = ##class(RLM.Source.Interop).StatusLabel(42)
    Do $$$AssertTrue($Find(unknown, "42") > 0, "an unknown code keeps its value: "_unknown)
    Do $$$AssertTrue($Find(unknown, "unknown") > 0, "and is marked unknown: "_unknown)
}

/// US2. A populated interop-enabled extent does not refuse.
///
/// The other side of the refusal assertions below: without it, a Ready that returned
/// 0 unconditionally would pass every one of them.
Method TestAPopulatedInteropExtentDoesNotRefuse()
{
    Set ready = ..Source().Ready(.reason)
    Do $$$AssertEquals(ready, 1, "a populated interop extent is ready")
    Do $$$AssertEquals(reason, "", "with no reason to give")
}

/// US2. An empty extent refuses, naming emptiness.
///
/// Asserted over an empty fixture rather than by emptying Ens.MessageHeader: deleting
/// the container's messages to test a refusal would be a destructive test, and the
/// count is the same query either way.
Method TestAnEmptyExtentRefusesNamingEmptiness()
{
    Do ##class(UnitTest.RLM.FixtureExtent).Wipe()
    Set s = ##class(RLM.Source.InteropProbe).%New("UnitTest.RLM.FixtureExtent")
    Set ready = s.Ready(.reason)
    Do $$$AssertEquals(ready, 0, "an empty extent refuses")
    Do $$$AssertTrue($Find(reason, "no messages") > 0, "naming emptiness: "_reason)
}

/// US5. The hour menu is a property of the dimension, not of the data: a store
/// spanning three hours offers the same 24 children as one spanning one, so a policy's
/// fanout does not grow with how long the production has been running.
Method TestTheHourDimensionOffersAFixedMenuWhateverTheDataSpans()
{
    Set dims = ..Source().Dimensions()
    Do $$$AssertEquals(dims.hour.children.%Size(), 24, "the hour dimension offers 24 children")
    Set s = ..Source()
    Set narrow = s.Dimensions(s.Predicate($ListBuild("source:RLMSRCC")))
    Do $$$AssertEquals(narrow.hour.children.%Size(), 24, "and still 24 over a one-hour slice")
    Do $$$AssertEquals(dims.hour.children.%Get(0).token, 0, "keyed by the hour itself")
    Do $$$AssertEquals(dims.hour.children.%Get(23).token, 23, "through to the last")
}

/// US5. A slice over one hour holds exactly the planted rows for it: the derived term
/// binds the hour rather than splicing it, and a bucketing that was off by one would
/// return a plausible count for the wrong hour.
Method TestAnHourSliceHoldsExactlyTheRowsPlantedInIt()
{
    Set s = ..Source()
    Set mine = ..Mine()
    Set two = s.Peek(mine_s.Term(mine, "DATEPART('hour', TimeCreated)", "=", 2))
    Do $$$AssertEquals(two.n, 2, "RLMSRCA planted two rows in hour 2")
    Set five = s.Peek(mine_s.Term(mine, "DATEPART('hour', TimeCreated)", "=", 5))
    Do $$$AssertEquals(five.n, 2, "and two in hour 5")
    Set three = s.Peek(mine_s.Term(mine, "DATEPART('hour', TimeCreated)", "=", 3))
    Do $$$AssertEquals(three.n, 0, "and none in hour 3")
}

/// US5, the reconciliation guarantee, asserted with `=` and no tolerance: a parent's
/// count equals the sum of its children's plus the disclosed gap. This is
/// Constitution III at the arithmetic level -- a report whose figures do not add up
/// is not a report that merely rounds.
Method TestChildCountsPlusTheDisclosedGapEqualTheParentExactly()
{
    Set s = ..Source()
    Set mine = ..Mine()
    Set parent = s.Peek(mine).n
    Set sum = 0
    For h = 0:1:23 {
        Set sum = sum + s.Peek(mine_s.Term(mine, "DATEPART('hour', TimeCreated)", "=", h)).n
    }
    Set gap = s.NullCount(mine, "hour")
    Do $$$AssertEquals(sum + gap, parent, "the hours plus the gap equal the parent exactly")
    // Through Predicate, the public encoder, rather than by assembling a term over a
    // column: a caller has no business naming columns, and a reconciliation asserted
    // through a path no caller uses would prove nothing about the ones they do.
    Set tsum = 0, dims = s.Dimensions()
    For i = 0:1:dims.target.children.%Size() - 1 {
        Set token = dims.target.children.%Get(i).token
        Set tsum = tsum + s.Peek(s.Predicate($ListBuild("source:RLMSRCA", "target:"_token))).n
    }
    Do $$$AssertEquals(tsum + s.NullCount(mine, "target"), parent, "and so does a categorical dimension")
}

/// US5. A row whose TimeCreated is null is in no hour, and NullCount is what says so.
/// Without it the hours would silently under-count their parent.
Method TestANullTimestampIsCountedAsTheGapRatherThanLost()
{
    Set h = ##class(Ens.MessageHeader).%New()
    Set h.SourceConfigName = "RLMSRCNULL"
    Set h.TargetConfigName = "RLMTGTX"
    Set h.Status = 9
    Set h.Type = 1
    Set h.Priority = 2
    Set sc = h.%Save()
    Do $$$AssertStatusOK(sc, "a header with no TimeCreated saves")
    Set ..Planted = ..Planted_$ListBuild(h.%Id())
    Set s = ..Source()
    Set p = s.Predicate($ListBuild("source:RLMSRCNULL"))
    Do $$$AssertEquals(s.Peek(p).n, 1, "the slice holds the row")
    Set sum = 0
    For i = 0:1:23 {
        Set sum = sum + s.Peek(p_s.Term(p, "DATEPART('hour', TimeCreated)", "=", i)).n
    }
    Do $$$AssertEquals(sum, 0, "no hour claims it")
    Do $$$AssertEquals(s.NullCount(p, "hour"), 1, "and the gap discloses it")
}

/// US2. A namespace without interop refuses, and does so before the count -- in such
/// a namespace "no messages" would be true and misleading, sending the reader to look
/// for a production rather than at the namespace.
Method TestANonInteropNamespaceRefusesNamingThat()
{
    Set s = ##class(RLM.Source.InteropProbe).%New()
    Set s.Enabled = 0
    Set ready = s.Ready(.reason)
    Do $$$AssertEquals(ready, 0, "a non-interop namespace refuses")
    Do $$$AssertTrue($Find(reason, "interoperability") > 0, "naming interop: "_reason)
    Do $$$AssertTrue($Find(reason, "no messages") = 0, "and not emptiness: "_reason)
}

}
