/// Tests for RLM.Source.Audit.
///
/// Over a fixture with %SYS.Audit's column shape rather than over %SYS.Audit itself:
/// an audit row appears when the system decides to write one, so a test that provoked
/// real events would assert against whatever else the container logged at the same
/// moment. The one thing the fixture cannot stand in for -- that the real extent is
/// queryable and that the auditing-disabled refusal fires -- is asserted directly
/// against %SYS.Audit below.
///
/// Every assertion sits on one line: a macro's arguments cannot span source lines.
Class UnitTest.RLM.SourceAudit Extends %UnitTest.TestCase
{

Method OnBeforeOneTest(testname As %String) As %Status
{
    Quit ##class(UnitTest.RLM.FixtureAudit).Build()
}

Method OnAfterOneTest(testname As %String) As %Status
{
    Do ##class(UnitTest.RLM.FixtureAudit).Wipe()
    Quit $$$OK
}

/// A source over the fixture extent.
ClassMethod Source() As RLM.Source.Audit
{
    Quit ##class(RLM.Source.Audit).%New("UnitTest.RLM.FixtureAudit")
}

/// The menu, discovered from the data: an audit log's event sources and types are
/// open-ended, so a hardcoded menu would advertise children a given machine's log
/// does not hold and hide the ones it does.
Method TestDimensionsOffersTheFourAuditDimensions()
{
    Set dims = ..Source().Dimensions()
    Do $$$AssertTrue(dims.%IsDefined("eventsource"), "event source is a dimension")
    Do $$$AssertTrue(dims.%IsDefined("eventtype"), "event type is a dimension")
    Do $$$AssertTrue(dims.%IsDefined("user"), "user is a dimension")
    Do $$$AssertTrue(dims.%IsDefined("namespace"), "namespace is a dimension")
    Do $$$AssertEquals(dims.eventsource.children.%Size(), 3, "three event sources are discovered")
    Do $$$AssertEquals(dims.user.children.%Size(), 4, "and four users")
    Set tokens = ""
    For i = 0:1:dims.user.children.%Size() - 1 {
        Set tokens = tokens_dims.user.children.%Get(i).token_" "
    }
    Do $$$AssertTrue($Find(tokens, "alice") > 0, "named as the data holds them: "_tokens)
}

/// The peek over the whole fixture, asserted against the hand-counted distribution.
Method TestPeekMatchesThePlantedDistribution()
{
    Set peek = ..Source().Peek()
    Set f = "UnitTest.RLM.FixtureAudit"
    Do $$$AssertEquals(peek.n, $ClassMethod(f, "Total"), "every row is counted")
    Do $$$AssertEquals(peek.users, $ClassMethod(f, "Users"), "the users are counted")
    Do $$$AssertEquals(peek.namespaces, $ClassMethod(f, "Namespaces"), "and the namespaces")
    Do $$$AssertEquals(peek.dominant, $ClassMethod(f, "Dominant"), "the busiest user is named")
    Do $$$AssertEquals(peek.dominantn, $ClassMethod(f, "DominantCount"), "with their count")
}

/// The metric: how mixed the slice's event types are. A slice holding one kind of
/// event has nothing left to divide.
Method TestSplitMetricIsTheEventTypeEntropy()
{
    Set s = ..Source()
    Set one = s.SplitMetric(s.Peek(s.Predicate($ListBuild("eventtype:Login"))))
    Do $$$AssertEquals(one, 0, "a single-type slice scores 0")
    Set even = s.SplitMetric(s.Peek(s.Predicate($ListBuild("eventsource:%Ensemble"))))
    Do $$$AssertEquals(even, 1, "two types of one row each score 1")
    Set mixed = s.SplitMetric(s.Peek(s.Predicate($ListBuild("eventsource:%System"))))
    Do $$$AssertTrue(mixed > 0, "a skewed slice scores above 0: "_mixed)
    Do $$$AssertTrue(mixed < 1, "and below 1: "_mixed)
}

/// Constitution I. The audit log's payload columns are the most sensitive data any
/// source in this project touches, and none of the three reaches either the peek or
/// the described text.
Method TestNoAuditPayloadReachesThePeekOrTheDescription()
{
    Set s = ..Source()
    Set peek = s.Peek()
    Set marker = ##class(UnitTest.RLM.FixtureAudit).Marker()
    Do $$$AssertTrue($Find(peek.%ToJSON(), marker) = 0, "the peek carries no marker")
    Set text = s.Describe("all", peek)
    Do $$$AssertTrue($Find(text, marker) = 0, "and neither does the description: "_text)
    Do $$$AssertTrue($Find(peek.%ToJSON(), "EventData") = 0, "no payload key at all")
    Do $$$AssertTrue($Find(peek.%ToJSON(), "UserInfo") = 0, "and no connection detail")
}

/// The real extent, and the one refusal a fixture cannot express.
///
/// Asserted against whichever way this machine is configured rather than against a
/// fixed expectation: a test that assumed auditing was off would fail on a machine
/// where it is on, and vice versa, and either failure would say nothing about the
/// code.
Method TestTheRealAuditExtentIsReadableAndRefusesHonestly()
{
    Set s = ##class(RLM.Source.Audit).%New()
    Set ready = s.Ready(.reason)
    Set enabled = ##class(RLM.Source.Audit).AuditingEnabled()
    Set peek = s.Peek()
    Do $$$AssertTrue(peek.n '< 0, "the real audit extent is countable: "_peek.n)
    If 'enabled {
        Do $$$AssertEquals(ready, 0, "with auditing off the source refuses")
        Do $$$AssertTrue($Find(reason, "auditing") > 0, "naming auditing: "_reason)
    } ElseIf peek.n = 0 {
        Do $$$AssertEquals(ready, 0, "an empty audit log refuses")
        Do $$$AssertTrue($Find(reason, "no ") > 0, "naming emptiness: "_reason)
    } Else {
        Do $$$AssertEquals(ready, 1, "a populated, audited log is ready")
        Do $$$AssertEquals(reason, "", "with no reason to give")
    }
}

/// A fixture is not the audit log, so the system's auditing setting says nothing
/// about it. Refusing a fixture for that setting would make this source untestable on
/// a machine with auditing off.
Method TestAFixtureBackedSourceIsNotJudgedByTheSystemAuditFlag()
{
    Set s = ..Source()
    Set ready = s.Ready(.reason)
    Do $$$AssertEquals(ready, 1, "the populated fixture is ready: "_reason)
    Do $$$AssertTrue($Find(reason, "auditing") = 0, "for no auditing reason: "_reason)
    Do ##class(UnitTest.RLM.FixtureAudit).Wipe()
    Set empty = ..Source().Ready(.why)
    Do $$$AssertEquals(empty, 0, "and an empty one refuses")
    Do $$$AssertTrue($Find(why, "no ") > 0, "for emptiness: "_why)
}

}
