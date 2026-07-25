/// Tests for the split-decision record.
///
/// The record has to serve three readers -- the engine acts on it, the trace
/// stores it, the report discloses it -- so the assertions here are mostly about
/// completeness: a decision that explains only its failures has to be
/// reverse-engineered on every other read.
Class UnitTest.RLM.Decision Extends %UnitTest.TestCase
{

Method TestReasonIsPopulatedOnSuccess()
{
    Set d = ##class(RLM.Decision).%New("UnitTest.Policy", 0.9)
    Do d.Choose("color", 0.22, "lowest weighted child metric of 2 candidates")
    Do $$$AssertEquals(d.Dimension, "color", "the chosen dimension")
    Do $$$AssertNotEquals(d.Reason, "", "and why, even though it succeeded")
    Do $$$AssertEquals(d.MetricBefore, 0.9, "metric of the parent slice")
    Do $$$AssertEquals(d.MetricAfter, 0.22, "score of the winner")
}

Method TestDeclineHasNoDimensionButKeepsAReason()
{
    Set d = ##class(RLM.Decision).%New("UnitTest.Policy", 0.9)
    Do d.Decline("no dimension reduced the metric")
    Do $$$AssertEquals(d.Dimension, "", "declined")
    Do $$$AssertEquals(d.MetricAfter, "", "no after-metric to report")
    Do $$$AssertNotEquals(d.Reason, "", "but the reason is on the record")
    Do $$$AssertNotTrue(d.Chose(), "and Chose() says so")
}

Method TestCandidatesPreserveDeclarationOrder()
{
    Set d = ##class(RLM.Decision).%New("UnitTest.Policy", 0.9)
    Do d.AddCandidate("color", 0.22, 2, 2)
    Do d.AddCandidate("size", 0.86, 2, 2)
    Do d.AddCandidate("weight", 0.89, 2, 2)
    Do $$$AssertEquals(d.Candidates.Count(), 3, "all three recorded")
    Do $$$AssertEquals(d.Candidates.GetAt(1).Dimension, "color", "first declared")
    Do $$$AssertEquals(d.Candidates.GetAt(3).Dimension, "weight", "last declared")
}

Method TestAddCandidateReturnsWhatItAppended()
{
    Set d = ##class(RLM.Decision).%New("UnitTest.Policy", 0.9)
    Set c = d.AddCandidate("color", 0.22, 400, 8)
    Do $$$AssertTrue($IsObject(c), "the candidate comes back for further filling")
    Set c.ChildMetrics = $ListBuild("red:600:0.20")
    Set got = d.Candidates.GetAt(1).ChildMetrics
    Do $$$AssertEquals($ListGet(got, 1), "red:600:0.20", "same object, not a copy")
}

/// Partial evidence has to be distinguishable by degree, not just by flag: 8 of
/// 10 children and 8 of 400 warrant different confidence in the same score.
Method TestSampledIsSeparateFromChildren()
{
    Set d = ##class(RLM.Decision).%New("UnitTest.Policy", 0.9)
    Set full = d.AddCandidate("color", 0.22, 2, 2)
    Set part = d.AddCandidate("zip", 0.30, 400, 8)
    Do $$$AssertNotTrue(full.Partial(), "every child evaluated")
    Do $$$AssertTrue(part.Partial(), "8 of 400 is partial evidence")
}

Method TestFailedCandidateCarriesItsError()
{
    Set d = ##class(RLM.Decision).%New("UnitTest.Policy", 0.9)
    Set c = d.AddCandidate("size", "", 2, 0)
    Set c.Error = "peek failed: no fixture row"
    Do $$$AssertEquals(c.Score, "", "no score to report")
    Do $$$AssertNotEquals(c.Error, "", "excluded, and it says why")
}

Method TestCappedDefaultsOffAndIsSettable()
{
    Set d = ##class(RLM.Decision).%New("UnitTest.Policy", 0.9)
    Do $$$AssertNotTrue(d.Capped, "nothing limited this decision yet")
    Set d.Capped = 1
    Do $$$AssertTrue(d.Capped, "a cap that bit is reported")
}

}
