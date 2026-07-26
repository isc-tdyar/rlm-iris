/// The feature gate for M5: a whole decomposition through AI Hub, byte-identical to
/// the same decomposition through the portable provider.
///
/// This is the assertion the milestone is actually about. Every other test in the
/// package checks one seam of `RLMAIHub.Provider`; this one checks that the seam is
/// invisible. Two runs over the same fixture with the same replies, one through
/// `RLM.LLM.Null` and one through `RLMAIHub.Provider` over a scripted `%AI.Provider`,
/// must produce the same document and spend the same number of calls.
///
/// Equality of the document is the strong form of Constitution VI. If the two
/// providers differed at all -- an extra message, a reordered prompt, a retry, a tool
/// loop -- the documents would diverge, and every scorecard comparison between an AI
/// Hub arm and a REST arm would be measuring the provider rather than the model.
///
/// Equality of the call count is the strong form of the `%AI.Agent` rejection recorded
/// in plan.md. `%AI.Agent.Chat` runs a tool loop with `MaxIterations` defaulting to
/// 10; had this been built on it, the engine would charge one slot per decision while
/// the provider spent up to ten, and the budget in the report would be fiction.
///
/// Every assertion sits on one line: a macro's arguments cannot span source lines.
Class UnitTest.RLMAIHub.EndToEndAIHub Extends %UnitTest.TestCase
{

/// Identical replies on purpose: nothing here asserts on their content, and identical
/// replies keep the byte-identity assertion about the two providers rather than about
/// the script.
ClassMethod Script(n As %Integer = 24) As %String
{
    Set script = ""
    For i = 1:1:n { Set script = script_$ListBuild("divide by colour") }
    Quit script
}

ClassMethod Store() As RLM.Source
{
    Quit ##class(UnitTest.RLM.Fixture).%New("aihub fixture")
}

/// A run with whichever LLM it is handed. Everything else is held fixed, because
/// the provider is the only variable this test is allowed to have.
ClassMethod Run(
	llm As RLM.LLM,
	Output traceId As %Integer) As %String
{
    Set engine = ##class(RLM.Engine).%New(..Store(), llm,
        ##class(RLM.Budget).%New(24), ##class(RLM.Policy.Greedy).%New())
    Set engine.MaxDepth = 2
    Quit engine.Run("how does this store divide?", .traceId)
}

/// The milestone's claim, asserted directly.
Method TestTheDocumentIsIdenticalThroughEitherProvider()
{
    Set null = ##class(RLM.LLM.Null).%New(..Script())
    Set viaNull = ..Run(null)
    Do $$$AssertNotEquals(viaNull, "", "the portable run produced a document")
    Do $$$AssertEquals($Find(viaNull, "stopped early"), 0, "and did not abort")

    Set stub = ##class(UnitTest.RLMAIHub.StubProvider).%New(..Script())
    Set aihub = ##class(RLMAIHub.Provider).%New("stub", "null")
    Set aihub.Provider = stub
    Set viaAIHub = ..Run(aihub)

    Do $$$AssertEquals(viaAIHub, viaNull, "the AI Hub run produced the same document")
}

/// One bounded round-trip per decision, and the same number as the portable run.
///
/// Asserted from the stub's own counter rather than from the trace: the trace records
/// what the engine believes it spent, and the question here is what the provider was
/// actually asked to do.
Method TestTheCallCountMatchesThePortableRunExactly()
{
    Set null = ##class(RLM.LLM.Null).%New(..Script())
    Do ..Run(null)
    Set expected = null.Calls

    Set stub = ##class(UnitTest.RLMAIHub.StubProvider).%New(..Script())
    Set aihub = ##class(RLMAIHub.Provider).%New("stub", "null")
    Set aihub.Provider = stub
    Do ..Run(aihub)

    Do $$$AssertTrue(expected > 1, "the portable run made more than one call: "_expected)
    Do $$$AssertEquals(stub.Calls, expected, "and AI Hub made exactly as many")
}

/// Every call carried exactly two messages, system then user.
///
/// A loop would show up here before it showed up in the count: an agent's second
/// iteration appends the assistant turn and a tool result, so any call with more than
/// two messages is a loop this design does not permit.
Method TestEveryCallCarriedExactlyTheTwoMessages()
{
    Set stub = ##class(UnitTest.RLMAIHub.StubProvider).%New(..Script())
    Set aihub = ##class(RLMAIHub.Provider).%New("stub", "null")
    Set aihub.Provider = stub
    Do ..Run(aihub)

    Do $$$AssertTrue(stub.Calls > 1, "the run made several calls: "_stub.Calls)
    For i = 1:1:stub.Calls {
        Set msgs = stub.MessagesOf(i)
        Do $$$AssertEquals(msgs.%Size(), 2, "call "_i_" carried two messages")
        Do $$$AssertEquals(msgs.%Get(0).%Get("role"), "system", "call "_i_" opened with the system turn")
        Do $$$AssertEquals(msgs.%Get(1).%Get("role"), "user", "call "_i_" then the user turn")
    }
}

/// Constitution I, at the seam the milestone adds.
///
/// A provider is the one place a store's contents can leave the instance, and this is
/// the first provider that reaches an external service through machinery the run does
/// not own. So a sentinel value is planted *inside* the store and no message may carry
/// it: only slice statistics are allowed through.
///
/// `RLM.Source.Global` over the fixture global, because it is the only store in the
/// suite whose contents a test can actually plant a value in -- the declarative
/// fixtures hold their statistics in a class method and have no contents to leak.
///
/// A weaker version of this test would check the document. The document is what the
/// caller already sees; the messages are what left the building.
Method TestNoStoreContentReachedTheProvider()
{
    Do ##class(UnitTest.RLM.FixtureGlobal).Build()
    Set secret = ##class(UnitTest.RLM.FixtureGlobal).PlantSecret()
    Set store = ##class(RLM.Source.Global).%New(##class(UnitTest.RLM.FixtureGlobal).#REF, "^||RLM*", .sc)
    Do $$$AssertStatusOK(sc, "the global store opened")

    Set stub = ##class(UnitTest.RLMAIHub.StubProvider).%New(..Script())
    Set aihub = ##class(RLMAIHub.Provider).%New("stub", "null")
    Set aihub.Provider = stub
    Set engine = ##class(RLM.Engine).%New(store, aihub,
        ##class(RLM.Budget).%New(24), ##class(RLM.Policy.Greedy).%New())
    Set engine.MaxDepth = 2
    Do engine.Run("what is in this store?")

    Do $$$AssertTrue(stub.Calls > 0, "the provider was called: "_stub.Calls)
    Set leaked = 0
    For i = 1:1:stub.Calls {
        If $Find($List(stub.SeenMessages, i), secret) { Set leaked = leaked + 1 }
    }
    Do $$$AssertEquals(leaked, 0, "and no message carried the planted value")
}

/// A provider that fails mid-run costs one sub-call, not the report.
///
/// The whole reason `Complete` converts a throw into a status. An exception would
/// unwind through `RLM.Engine.Run`'s handler and the reader would receive "The
/// analysis stopped early" with an ObjectScript error code in place of the
/// decomposition -- everything before the failure thrown away along with it.
///
/// Three things are asserted, because any one alone can be satisfied dishonestly: the
/// report exists and still contains the decomposition, the failure is disclosed in it
/// rather than swallowed, and the run kept going past the failed call. The middle one
/// is Constitution III at the sub-call level: a slot that produced nothing must say so.
///
/// Disclosure is asserted as the engine's caveat -- "the sub-call for 'x' failed; that
/// slice is described by its statistics only" -- and not as the provider's error text.
/// The engine does not put a provider's message into the document, and it should not:
/// an error string is a fact about an outage, while the caveat is the fact the reader
/// needs, which is that a slice in front of them was never analysed.
Method TestAFailedCallCostsOneSubCallAndNotTheReport()
{
    Set stub = ##class(UnitTest.RLMAIHub.StubProvider).%New(..Script())
    Set stub.ThrowOnCall = 2
    Set aihub = ##class(RLMAIHub.Provider).%New("stub", "null")
    Set aihub.Provider = stub
    Set report = ..Run(aihub)

    Do $$$AssertNotEquals(report, "", "the run still produced a report")
    Do $$$AssertEquals($Find(report, "stopped early"), 0, "and did not abort: "_$Extract(report, 1, 200))
    Do $$$AssertTrue($Find(report, "Question") > 0, "the document is still a report")
    Do $$$AssertTrue(stub.Calls > 2, "and the run continued past the failed call: "_stub.Calls)
    Do $$$AssertTrue($Find(report, "sub-call") > 0, "the failed sub-call is disclosed in the report")
    Do $$$AssertTrue($Find(report, "statistics only") > 0, "saying what the reader is looking at instead")

    // The other side. Without it the two assertions above could be passing on
    // boilerplate every report carries, and the test would prove nothing.
    Set ok = ##class(UnitTest.RLMAIHub.StubProvider).%New(..Script())
    Set good = ##class(RLMAIHub.Provider).%New("stub", "null")
    Set good.Provider = ok
    Set cleanReport = ..Run(good)
    Do $$$AssertEquals($Find(cleanReport, "statistics only"), 0, "a run with no failure carries no such caveat")
}

/// The same failure, asserted from the trace rather than the document.
///
/// The report is what a reader sees; the trace is what an auditor replays. A failed
/// call that spent a slot but left no row would make the two disagree about how much
/// the run cost, and the budget line in the report would be the one that was wrong.
Method TestAFailedCallIsOnTheRecord()
{
    Kill ^RLM.Trace
    Set stub = ##class(UnitTest.RLMAIHub.StubProvider).%New(..Script())
    Set stub.ThrowOnCall = 2
    Set aihub = ##class(RLMAIHub.Provider).%New("stub", "null")
    Set aihub.Provider = stub
    Set engine = ##class(RLM.Engine).%New(..Store(), aihub,
        ##class(RLM.Budget).%New(24), ##class(RLM.Policy.Greedy).%New())
    Set engine.MaxDepth = 2
    Set engine.DurableTrace = 1
    Do engine.Run("how does this store divide?", .traceId)

    Set rows = 0, seq = ""
    For  {
        Set seq = $Order(^RLM.Trace(traceId, seq))
        Quit:seq=""
        Quit:seq'?1.N
        Set rows = rows + 1
    }
    Do $$$AssertTrue(rows > 2, "the trace recorded the run past the failure: "_rows_" row(s)")
    Kill ^RLM.Trace
}

/// A run the instance will not authorize produces a report that says so.
///
/// The worst outcome here is not the refusal. It is a document that reads as a
/// complete analysis of a store nobody was permitted to ask a model about -- every
/// slice present, every heading filled with statistics, and nothing to tell the reader
/// no model ever saw any of it. So the assertion is on disclosure: the report exists,
/// the slices are named, and each one says its analysis did not happen.
///
/// The provider's call count is asserted at zero for the same reason as the unit test:
/// authorization runs before the round-trip, so a refused run costs nothing at the
/// provider even though it costs slots in the budget.
Method TestARefusedRunDisclosesTheRefusalRatherThanOmittingTheSlices()
{
    Set stub = ##class(UnitTest.RLMAIHub.StubProvider).%New(..Script())
    Set aihub = ##class(RLMAIHub.Provider).%New("stub", "null")
    Set aihub.Provider = stub
    Set auth = ##class(UnitTest.RLMAIHub.StubAuth).%New()
    Set auth.RefuseWith = "this namespace may not call out"
    Set aihub.AuthPolicy = auth
    Set report = ..Run(aihub)

    Do $$$AssertNotEquals(report, "", "a refused run still produces a report")
    Do $$$AssertEquals(stub.Calls, 0, "and never reached the provider")
    Do $$$AssertTrue(auth.Calls > 0, "though the policy was asked: "_auth.Calls)
    Do $$$AssertTrue($Find(report, "Question") > 0, "the document is still a report")
    Do $$$AssertTrue($Find(report, "statistics only") > 0, "and discloses that no analysis happened")
}

}
