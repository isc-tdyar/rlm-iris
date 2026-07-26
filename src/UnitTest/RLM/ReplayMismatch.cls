/// Tests for the refusals: a replay against a store that is no longer the store
/// the trace was recorded against.
///
/// Constitution III applied one level up. A replay that ran anyway would produce a
/// document that differs from the original while claiming to reproduce it, which is
/// the undisclosed-cap failure with the stakes raised -- the reader is now auditing.
///
/// The mutation cases use RLM.Source.Global over the fixture global, because it is
/// the only store in the suite whose contents a test can actually change; the
/// declarative fixtures hold their statistics in a class method.
///
/// Every assertion sits on one line: a macro's arguments cannot span source lines.
Class UnitTest.RLM.ReplayMismatch Extends %UnitTest.TestCase
{

Method OnBeforeOneTest(testname As %String) As %Status
{
    Kill ^RLM.Trace
    Do ##class(UnitTest.RLM.FixtureGlobal).Build()
    Quit $$$OK
}

Method OnAfterOneTest(testname As %String) As %Status
{
    Kill ^RLM.Trace
    Quit $$$OK
}

ClassMethod Global() As RLM.Source.Global
{
    Quit ##class(RLM.Source.Global).%New(##class(UnitTest.RLM.FixtureGlobal).#REF, "^||RLM*", .sc)
}

ClassMethod Scripted(n As %Integer = 24) As RLM.LLM.Null
{
    Set script = ""
    For i = 1:1:n { Set script = script_$ListBuild("finding "_i) }
    Quit ##class(RLM.LLM.Null).%New(script)
}

/// Record a durable run over `source` and return its report.
ClassMethod Record(
	source As RLM.Source,
	Output traceId As %Integer) As %String
{
    Set engine = ##class(RLM.Engine).%New(source, ..Scripted(),
        ##class(RLM.Budget).%New(32), ##class(RLM.Policy.Greedy).%New())
    Set engine.DurableTrace = 1
    Quit engine.Run("what is in this store?", .traceId)
}

/// The headline refusal. One node added after the trace was written, and the
/// replay declines with a reason that says the store moved.
Method TestAMutatedStoreRefusesTheReplay()
{
    Do ..Record(..Global(), .traceId)
    // A new leaf under an existing level-1 subscript: the root's node count and
    // that slice's move, so the fingerprint must move with them.
    Set ^||RLMTest("2019-11-04", "BOS-GEN", 99) = "mutated"
    Set replay = ##class(RLM.Replay).%New(..Global(), traceId)
    Do $$$AssertNotTrue(replay.Verify(.reason), "a mutated store refuses the replay")
    Do $$$AssertTrue($Find(reason, "no longer matches") > 0, "and says the store moved: "_reason)
    Set sc = replay.Run(.report)
    Do $$$AssertStatusNotOK(sc, "and Run refuses too")
    Do $$$AssertTrue($Find(report, "was not run") > 0, "with a report that says so: "_report)
}

/// The other side of the same assertion. Without it the check could refuse
/// everything and every test above would still pass.
Method TestAnUnchangedStoreDoesNotRefuse()
{
    Set original = ..Record(..Global(), .traceId)
    Set replay = ##class(RLM.Replay).%New(..Global(), traceId)
    Do $$$AssertTrue(replay.Verify(.reason), "an unchanged store verifies: "_reason)
    Do $$$AssertStatusOK(replay.Run(.report), "and the replay runs")
    Do $$$AssertEquals(report, original, "producing the recorded document")
}

/// A trace from another store is refused before a peek is spent. Comparing two
/// stores' fingerprints is meaningless, and a comparison that happened to match
/// would be worse than one that failed.
Method TestAForeignSourceClassIsRefusedBeforeAnyPeek()
{
    Do ..Record(##class(UnitTest.RLM.FixtureSeparating).%New(), .traceId)
    // A different class, and one that records every predicate it is asked for --
    // the store is the only place that sees the questions.
    Set other = ##class(UnitTest.RLM.FixtureRecording).%New()
    Set replay = ##class(RLM.Replay).%New(other, traceId)
    Do $$$AssertNotTrue(replay.Verify(.reason), "a foreign source class is refused")
    Do $$$AssertTrue($Find(reason, "recorded against") > 0, "and names both classes: "_reason)
    Do $$$AssertEquals($ListLength(other.Peeked), 0, "and no peek was spent finding out")
}

/// Verify is a question, not a transaction. A caller that asks twice gets the same
/// answer, and asking does not consume the trace.
Method TestVerifyIsIdempotentAndDoesNotConsumeTheTrace()
{
    Set original = ..Record(..Global(), .traceId)
    Set replay = ##class(RLM.Replay).%New(..Global(), traceId)
    Set first = replay.Verify(.r1)
    Set second = replay.Verify(.r2)
    Do $$$AssertEquals(first, second, "two Verify calls agree")
    Do $$$AssertEquals(r1, r2, "with the same reason")
    Do $$$AssertStatusOK(replay.Run(.report), "and a Run after two Verifies still works")
    Do $$$AssertEquals(report, original, "reproducing the recorded document")
    // Twice more, on a fresh object, to catch a Verify that consumed the record.
    Set again = ##class(RLM.Replay).%New(..Global(), traceId)
    Do $$$AssertStatusOK(again.Run(.report2), "and a second replay still works")
    Do $$$AssertEquals(report2, original, "identically")
}

/// Constitution I. The fingerprint is derived from the peeks, never from the
/// contents, so a value stored in the global appears in no trace node. This is the
/// assertion that catches anyone "improving" the fingerprint into a digest of the
/// data -- which would be cheaper to write and would leak the store.
Method TestTheFingerprintDoesNotContainStoreContents()
{
    Set secret = ##class(UnitTest.RLM.FixtureGlobal).PlantSecret()
    Do ..Record(..Global(), .traceId)
    Set fp = ##class(RLM.Trace).Fingerprint(traceId, 1)
    Do $$$AssertNotEquals(fp, "", "a fingerprint was recorded: "_fp)
    Do $$$AssertEquals(fp?1.N, 1, "and it is a number, not a digest of anything")
    Do $$$AssertEquals($Find(fp, secret), 0, "the fingerprint does not contain the value")

    // And neither does any other node of the trace, at any subscript depth.
    Set found = 0, node = "^RLM.Trace("_traceId_")"
    For  {
        Set node = $Query(@node)
        Quit:node=""
        Quit:($Extract(node,1,$Length("^RLM.Trace("_traceId_","))'="^RLM.Trace("_traceId_",")
        Set val = @node
        If $Find(val, secret) { Set found = found + 1 }
    }
    Do $$$AssertEquals(found, 0, "and no trace node contains it either")
}

/// A mutation that leaves every aggregate identical does not move the
/// fingerprint, and that is the honest limit of the guarantee rather than a bug: a
/// decision is a function of the peeks, so if no peek figure moved, no decision
/// could have moved. Asserted so the limit is documented in a test rather than
/// only in a comment.
Method TestAMutationInvisibleToEveryPeekDoesNotRefuse()
{
    Do ..Record(..Global(), .traceId)
    // Same node, same value length, different contents. Every count and every
    // value-length moment is unchanged.
    Set ^||RLMTest(7, "z2", 1) = "XY"
    Set replay = ##class(RLM.Replay).%New(..Global(), traceId)
    Do $$$AssertTrue(replay.Verify(.reason), "a peek-invisible change does not refuse: "_reason)
}

/// A trace with no fingerprint is refused for the honest reason -- there is
/// nothing to compare -- rather than passing by default.
Method TestATraceWithNoFingerprintIsRefused()
{
    Do ..Record(..Global(), .traceId)
    Kill ^RLM.Trace(traceId, "fp")
    Set replay = ##class(RLM.Replay).%New(..Global(), traceId)
    Do $$$AssertNotTrue(replay.Verify(.reason), "no fingerprint is a refusal")
    Do $$$AssertTrue($Find(reason, "no store fingerprint") > 0, "for that reason: "_reason)
}

}
