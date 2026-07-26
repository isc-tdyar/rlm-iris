/// Tests for RLM.Replay: re-run a recorded decomposition from its trace plus the
/// store, with no model call.
///
/// This is Constitution V made executable. The claim is not "a replay produces a
/// plausible report" but "a replay produces *the* report", so most of what is
/// asserted below is equality against the original run's own output rather than
/// against a shape.
Class UnitTest.RLM.Replay Extends %UnitTest.TestCase
{

Method OnBeforeOneTest(testname As %String) As %Status
{
    Kill ^RLM.Trace
    Quit $$$OK
}

Method OnAfterOneTest(testname As %String) As %Status
{
    Kill ^RLM.Trace
    Quit $$$OK
}

ClassMethod Source() As UnitTest.RLM.Fixture
{
    Quit ##class(UnitTest.RLM.Fixture).%New("widgets")
}

/// Enough replies for a root decision plus one sub-call per child plus synthesis.
///
/// Distinct replies, not one repeated: a replay that returned the wrong row's text
/// would still match if every row said the same thing.
ClassMethod Scripted(n As %Integer = 8) As RLM.LLM.Null
{
    Set script = ""
    For i = 1:1:n { Set script = script_$ListBuild("finding number "_i) }
    Quit ##class(RLM.LLM.Null).%New(script)
}

/// Record a run and return its report. `traceId` comes back for the replay.
ClassMethod Record(
	Output traceId As %Integer,
	Output llm As RLM.LLM.Null,
	question As %String = "how does this store divide?",
	rootPath As %String = "",
	maxDepth As %Integer = 1) As %String
{
    Set llm = ..Scripted()
    Set engine = ##class(RLM.Engine).%New(..Source(), llm,
        ##class(RLM.Budget).%New(16), ##class(RLM.Policy.Greedy).%New())
    Set engine.DurableTrace = 1
    Set engine.MaxDepth = maxDepth
    Quit engine.Run(question, .traceId, rootPath)
}

/// The headline claim, and the strongest form of it available: the replayed
/// document equals the recorded one, character for character.
Method TestAReplayedReportEqualsTheOriginal()
{
    Set original = ..Record(.traceId, .llm)
    Do $$$AssertEquals($Find(original, "sub-call for"), 0, "no sub-call failed in the recorded run")
    Do $$$AssertTrue(llm.Calls > 1, "the recorded run actually called the model: "_llm.Calls)

    Set replay = ##class(RLM.Replay).%New(..Source(), traceId)
    Set sc = replay.Run(.report)
    Do $$$AssertStatusOK(sc, "the replay ran")
    Do $$$AssertEquals(report, original, "the replayed report equals the original")
}

/// The point of a replay. Zero calls, asserted on the replay's own counter and on
/// a fresh Null that would record any call the replay tried to make.
Method TestReplaySpendsNoModelCall()
{
    Do ..Record(.traceId, .llm)
    Set replay = ##class(RLM.Replay).%New(..Source(), traceId)
    Do replay.Run(.report)
    Do $$$AssertEquals(replay.Calls, 0, "the replay made no model call")
    Do $$$AssertTrue(replay.Decisions > 0, "and it did reproduce decisions: "_replay.Decisions)
}

/// SC-002. Two replays of one trace over an unchanged store agree.
Method TestTwoReplaysAreByteIdentical()
{
    Do ..Record(.traceId, .llm)
    Do ##class(RLM.Replay).%New(..Source(), traceId).Run(.first)
    Do ##class(RLM.Replay).%New(..Source(), traceId).Run(.second)
    Do $$$AssertNotEquals(first, "", "the first replay produced a report")
    Do $$$AssertEquals(first, second, "two replays agree")
}

/// The decisions are the thing an evaluation scores, so they are asserted
/// individually rather than left to the report comparison.
Method TestEveryDecisionIsReproduced()
{
    Do ..Record(.traceId, .llm)
    Set recorded = ##class(RLM.Trace).Decisions(traceId, 1)
    Do $$$AssertTrue(recorded.Count() > 0, "the run recorded at least one decision")

    Set replay = ##class(RLM.Replay).%New(..Source(), traceId)
    Do replay.Run(.report)
    Set again = replay.ReplayedDecisions
    Do $$$AssertEquals(again.Count(), recorded.Count(), "same number of decisions")
    For i = 1:1:recorded.Count() {
        Set a = recorded.GetAt(i), b = again.GetAt(i)
        Do $$$AssertEquals(b.Dimension, a.Dimension, "decision "_i_" chose the same dimension")
        Do $$$AssertEquals(+b.MetricAfter, +a.MetricAfter, "decision "_i_" scored the same")
    }
}

/// A deeper run has decisions below the root. A replay that reproduced only the
/// root would still match on a depth-1 run, so depth 2 is where the recursion is
/// actually tested.
Method TestADeeperRunReplaysToTheSameDocument()
{
    Set original = ..Record(.traceId, .llm, "how does this store divide?", "", 2)
    Do $$$AssertEquals($Find(original, "sub-call for"), 0, "no sub-call failed")
    Set replay = ##class(RLM.Replay).%New(..Source(), traceId)
    Do replay.Run(.report)
    Do $$$AssertEquals(report, original, "a depth-2 run replays exactly")
    Do $$$AssertTrue(replay.Decisions > 1, "more than one decision reproduced: "_replay.Decisions)
}

/// A scoped run is a run over a slice. Its report says so, and the scope lives in
/// the trace's config rather than being asked of the caller again.
Method TestAScopedRunReplaysWithinItsScope()
{
    Set original = ..Record(.traceId, .llm, "what is true of red?", "color:red", 1)
    Set replay = ##class(RLM.Replay).%New(..Source(), traceId)
    Do replay.Run(.report)
    Do $$$AssertEquals(report, original, "a scoped run replays exactly")
}

/// A run whose sub-call failed recorded that failure. The replay must reproduce
/// the failure, not quietly succeed where the original did not.
Method TestAFailedSubCallIsReproducedNotRepaired()
{
    Set llm = ..Scripted()
    Set llm.FailAtCall = 2
    Set engine = ##class(RLM.Engine).%New(..Source(), llm,
        ##class(RLM.Budget).%New(16), ##class(RLM.Policy.Greedy).%New())
    Set engine.DurableTrace = 1
    Set original = engine.Run("how does this store divide?", .traceId)
    Do $$$AssertNotEquals($Find(original, "sub-call for"), 0, "the recorded run has a failed sub-call")

    Set replay = ##class(RLM.Replay).%New(..Source(), traceId)
    Do replay.Run(.report)
    Do $$$AssertEquals(report, original, "the failure is reproduced verbatim")
}

/// FR-011. A trace written before the text sidecar existed cannot be replayed
/// into the same report, so it is refused by version rather than replayed into a
/// different document that claims to be a reproduction.
Method TestAVersionOneTraceIsRefused()
{
    Set trace = ##class(RLM.Trace).%New(1)
    Do trace.Add("subcall", 1, "color:red", "UnitTest.RLM.Fixture", 0.2, 10, 10, "null")
    Set replay = ##class(RLM.Replay).%New(..Source(), trace.RunId)
    Do $$$AssertNotTrue(replay.Verify(.reason), "a v1 trace does not verify")
    Do $$$AssertNotEquals($Find(reason, "1"), 0, "the reason names the version found: "_reason)
    Do $$$AssertNotEquals($Find(reason, "2"), 0, "and the version supported: "_reason)
}

/// A replay of a run that was never recorded is a caller bug, and it must say so
/// rather than producing an empty report that reads like a store with nothing in
/// it.
Method TestAnUnknownRunIsRefused()
{
    Set replay = ##class(RLM.Replay).%New(..Source(), 999999)
    Do $$$AssertNotTrue(replay.Verify(.reason), "an unknown run does not verify")
    Do $$$AssertNotEquals(reason, "", "with a reason: "_reason)
    Set sc = replay.Run(.report)
    Do $$$AssertStatusNotOK(sc, "and Run refuses too")
    Do $$$AssertEquals(replay.Calls, 0, "having called nothing")
}

/// A process-private trace has no metadata, so it is not replayable and says so.
/// The alternative -- treating a missing fingerprint as "nothing to check" -- would
/// make the whole US4 refusal opt-out by accident.
Method TestAProcessPrivateRunIsRefused()
{
    Set llm = ..Scripted()
    Set engine = ##class(RLM.Engine).%New(..Source(), llm,
        ##class(RLM.Budget).%New(16), ##class(RLM.Policy.Greedy).%New())
    Set original = engine.Run("how does this store divide?", .traceId)
    Do $$$AssertNotEquals(original, "", "the run produced a report")
    Set replay = ##class(RLM.Replay).%New(..Source(), traceId)
    Do $$$AssertNotTrue(replay.Verify(.reason), "a private trace does not verify: "_reason)
}

}
