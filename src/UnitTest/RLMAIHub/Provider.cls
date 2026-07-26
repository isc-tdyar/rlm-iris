/// `RLMAIHub.Provider` against a scripted `%AI.Provider`.
///
/// The seam these tests defend is that `RLM.Engine` cannot tell this provider from
/// `RLM.LLM.REST`. So the assertions are mostly about equivalence: the same
/// two-message prompt shape, the same "never throw, return a status" contract, the
/// same refusal of a truncated completion -- reconstructed here, because AI Hub's
/// response object carries no finish reason to read.
///
/// Every assertion sits on one line: a macro's arguments cannot span source lines.
Class UnitTest.RLMAIHub.Provider Extends %UnitTest.TestCase
{

/// A provider wired to a scripted stub. The stub replaces `ChatComplete`, so no
/// provider is configured and no key exists anywhere in these tests.
ClassMethod Wire(
	script As %List = "",
	Output stub As UnitTest.RLMAIHub.StubProvider) As RLMAIHub.Provider
{
    Set stub = ##class(UnitTest.RLMAIHub.StubProvider).%New(script)
    Set p = ##class(RLMAIHub.Provider).%New("stub", "test-model")
    Set p.Provider = stub
    Quit p
}

/// The reply comes back, and construction needed no endpoint.
Method TestACompletionReturnsTheProvidersContent()
{
    Set p = ..Wire($ListBuild("divide by status"), .stub)
    Set out = p.Complete("instructions", "prompt", .sc)
    Do $$$AssertStatusOK(sc, "a scripted completion succeeds")
    Do $$$AssertEquals(out, "divide by status", "and returns the provider's content")
    Do $$$AssertEquals(stub.Calls, 1, "in exactly one call")
}

/// The prompt shape, asserted rather than assumed.
///
/// `RLM.LLM.REST` sends exactly two messages, system then user. If this provider
/// sent three, or folded the instructions into the user turn, the two providers
/// would be answering different questions and every comparison the scorecard makes
/// between them would be measuring the prompt rather than the model.
Method TestTheMessagesAreSystemThenUserExactlyAsRestSends()
{
    Set p = ..Wire($ListBuild("ok"), .stub)
    Do p.Complete("the instructions", "the prompt", .sc)
    Set msgs = stub.MessagesOf(1)
    Do $$$AssertEquals(msgs.%Size(), 2, "two messages, no more")
    Do $$$AssertEquals(msgs.%Get(0).%Get("role"), "system", "the first is the system role")
    Do $$$AssertEquals(msgs.%Get(0).%Get("content"), "the instructions", "carrying the instructions")
    Do $$$AssertEquals(msgs.%Get(1).%Get("role"), "user", "the second is the user role")
    Do $$$AssertEquals(msgs.%Get(1).%Get("content"), "the prompt", "carrying the prompt")
}

/// No URL, no key, no SSL configuration -- the point of the module (FR2).
Method TestConstructionNeedsNoUrlKeyOrSslConfiguration()
{
    Set p = ##class(RLMAIHub.Provider).%New("stub", "test-model")
    Do $$$AssertTrue($IsObject(p), "a provider is constructed from a name and a model alone")
    Do $$$AssertEquals(p.Model, "test-model", "and records the model for the trace")
    Do $$$AssertEquals(p.ProviderName, "stub", "and the provider name it was asked for")
    Set props = ##class(UnitTest.RLMAIHub.Manifests).CodeOnly(##class(UnitTest.RLMAIHub.Manifests).ReadFile("/home/irisowner/dev/src/RLMAIHub/Provider.cls"))
    Do $$$AssertEquals(props [ "BaseURL", 0, "the class has no BaseURL property to supply")
    Do $$$AssertEquals(props [ "APIKey", 0, "and no APIKey property")
    Do $$$AssertEquals(props [ "SSLConfiguration", 0, "and no SSLConfiguration property")
}

/// Sampling parameters reach the provider, and unset means unset.
///
/// Passing 0 for an unset `MaxTokens` would cap every completion at nothing; passing
/// 0 for an unset temperature silently makes a choice the caller did not make. Both
/// are the kind of default that is invisible until a report is wrong.
Method TestTemperatureAndMaxTokensArrivePassedThroughAndUnsetStaysUnset()
{
    Set p = ..Wire($ListBuild("ok"), .stub)
    Set p.Temperature = 0.25, p.MaxTokens = 512
    Do p.Complete("i", "p", .sc)
    Do $$$AssertEquals(+$List(stub.SeenTemperature, 1), 0.25, "the temperature arrives as given")
    Do $$$AssertEquals(+$List(stub.SeenMaxTokens, 1), 512, "and the token limit")
    Do $$$AssertEquals($List(stub.SeenModel, 1), "test-model", "and the model")

    Set q = ..Wire($ListBuild("ok"), .stub2)
    Set q.Temperature = "", q.MaxTokens = ""
    Do q.Complete("i", "p", .sc2)
    Do $$$AssertEquals($List(stub2.SeenTemperature, 1), "", "an unset temperature is passed as empty, not as 0")
    Do $$$AssertEquals($List(stub2.SeenMaxTokens, 1), "", "and an unset token limit is not passed as 0")
}

/// Readiness is a separate question from construction.
///
/// `%AI.Provider.Create("openai", {"api_key": "sk-not-a-real-key"})` returns a
/// provider object and lists capabilities, measured on 2026.3.0AI Build 126U. So a
/// constructed provider proves nothing about whether a call can be made, and a
/// caller that treated construction as readiness would discover the truth one
/// exhausted budget later.
Method TestReadinessIsAskedSeparatelyAndNamesItsReason()
{
    Set p = ..Wire($ListBuild("ok"), .stub)
    Do $$$AssertTrue(p.Ready(.reason), "a wired provider is ready")
    Do $$$AssertEquals(reason, "", "with no reason to give")

    Set q = ##class(RLMAIHub.Provider).%New("stub", "test-model")
    Set q.Provider = ""
    Do $$$AssertEquals(q.Ready(.r2), 0, "a provider that did not resolve is not ready")
    Do $$$AssertTrue($Length(r2) > 10, "and says so: "_r2)
    Do $$$AssertTrue($ZConvert(r2, "U") [ "PROVIDER", "naming the provider as the problem")
}

/// Usage is exposed on the object, not written into the trace.
///
/// `RLM.Engine` fills the trace's tokensIn/tokensOut with `$Length(prompt)` and
/// `$Length(out)` -- characters, not tokens. Writing real token counts into those
/// fields for this provider alone would make an AI Hub run and a REST run
/// incomparable in the one scorecard built to compare them, so the counts live
/// here and reconciling the trace stays a separate change.
Method TestUsageTokenCountsAreReadableAfterACall()
{
    Set p = ..Wire($ListBuild("ok"), .stub)
    Set stub.UsageJSON = "{""prompt_tokens"":41,""completion_tokens"":7,""total_tokens"":48}"
    Do p.Complete("i", "p", .sc)
    Do $$$AssertStatusOK(sc, "the call succeeded")
    Do $$$AssertEquals(p.LastPromptTokens, 41, "the prompt token count is readable")
    Do $$$AssertEquals(p.LastCompletionTokens, 7, "and the completion token count")
}

/// A provider that reports no usage leaves the counts empty rather than zero.
///
/// Zero is a measurement; empty is the absence of one. A scorecard that averaged
/// zeros for a provider that simply does not report usage would publish a confident
/// wrong number, which is Constitution III's failure in a different column.
Method TestAbsentUsageLeavesTheCountsEmptyRatherThanZero()
{
    Set p = ..Wire($ListBuild("ok"), .stub)
    Set stub.UsageJSON = ""
    Do p.Complete("i", "p", .sc)
    Do $$$AssertStatusOK(sc, "a reply with no usage block still succeeds")
    Do $$$AssertEquals(p.LastPromptTokens, "", "an unreported prompt count is empty, not 0")
    Do $$$AssertEquals(p.LastCompletionTokens, "", "and an unreported completion count")
}

// --- Phase 3: a failure costs one slot, not the report (US2) -----------------

/// A throwing provider becomes a status, not an exception.
///
/// `%AI.*` signals failure by throwing; `RLM.LLM`'s contract is "" plus a status.
/// The difference decides who absorbs an outage: a throw unwinds through
/// `RLM.Engine.Run`'s Catch and the whole run is reduced to "The analysis stopped
/// early", while a status costs the run one sub-call it then discloses.
Method TestAThrowingProviderIsAStatusAndNotAnException()
{
    Set p = ..Wire($ListBuild("never reached"), .stub)
    Set stub.ThrowOnCall = 1
    Set threw = 0
    Try {
        Set out = p.Complete("i", "p", .sc)
    } Catch {
        Set threw = 1
    }
    Do $$$AssertEquals(threw, 0, "Complete did not throw")
    Do $$$AssertStatusNotOK(sc, "it reported a status instead")
    Do $$$AssertEquals($Get(out), "", "and returned no text")
    Set text = $System.Status.GetErrorText(sc)
    Do $$$AssertTrue($Find(text, "stub") > 0, "naming the provider: "_text)
    Do $$$AssertTrue($Find(text, "failed") > 0, "and that it failed: "_text)
}

/// An empty completion is a failure, not an empty answer.
///
/// A provider can return a 200 with nothing in it. Passed through, the engine writes
/// an empty sub-call answer into the report and the reader sees a heading with
/// nothing under it -- indistinguishable from a slice that genuinely had nothing to
/// say. Refusing makes the difference visible.
Method TestAnEmptyCompletionIsARefusalNotAnAnswer()
{
    Set p = ..Wire($ListBuild(""), .stub)
    Set out = p.Complete("i", "p", .sc)
    Do $$$AssertStatusNotOK(sc, "an empty completion is refused")
    Do $$$AssertEquals(out, "", "and no text is returned")
    Do $$$AssertTrue($Find($System.Status.GetErrorText(sc), "empty") > 0, "for that reason")
}

/// A provider that returns nothing at all is refused rather than dereferenced.
///
/// Defensive on purpose: `ChatComplete` is declared to return `%AI.LLM.Response`, and
/// a nonconforming override or a future platform change returning "" would otherwise
/// be an `<INVALID OREF>` -- a throw, which is the one thing this class promises not
/// to do.
Method TestANonObjectResponseIsRefusedRatherThanDereferenced()
{
    Set p = ..Wire($ListBuild("ok"), .stub)
    Set stub.ReturnNothing = 1
    Set threw = 0
    Try {
        Set out = p.Complete("i", "p", .sc)
    } Catch {
        Set threw = 1
    }
    Do $$$AssertEquals(threw, 0, "Complete still did not throw")
    Do $$$AssertStatusNotOK(sc, "and refused")
    Do $$$AssertEquals($Get(out), "", "returning no text")
}

// --- Phase 4: truncation is refused without a finish reason (US3) ------------

/// A completion that reached the ceiling is refused, and its partial text withheld.
///
/// `%AI.LLM.Response` carries no finish reason -- `FromJSON` reads `content`, `usage`
/// and `tool_calls` and nothing else -- so `RLM.LLM.REST`'s `finish_reason = "length"`
/// refusal has no direct equivalent. Truncation is inferred from the reported
/// completion count reaching the requested limit.
///
/// The text is withheld rather than returned alongside the error, because a caller
/// that ignored the status would otherwise put half a sentence into a report as a
/// finding.
Method TestACompletionAtTheTokenCeilingIsRefused()
{
    Set p = ..Wire($ListBuild("the first half of a sentence that never fin"), .stub)
    Set p.MaxTokens = 16
    Set stub.UsageJSON = "{""prompt_tokens"":40,""completion_tokens"":16}"
    Set out = p.Complete("i", "p", .sc)
    Do $$$AssertStatusNotOK(sc, "a completion at the ceiling is refused")
    Do $$$AssertEquals(out, "", "and the partial text is not returned")
    Do $$$AssertTrue($Find($System.Status.GetErrorText(sc), "cut off") > 0, "naming truncation")
}

/// One token below the ceiling succeeds.
///
/// The other half of the previous assertion, and the one that keeps the proxy honest:
/// a check that refused everything would pass the test above and be useless. This
/// pins the boundary at `>=` rather than somewhere lower.
Method TestOneTokenBelowTheCeilingSucceeds()
{
    Set p = ..Wire($ListBuild("a complete answer"), .stub)
    Set p.MaxTokens = 16
    Set stub.UsageJSON = "{""prompt_tokens"":40,""completion_tokens"":15}"
    Set out = p.Complete("i", "p", .sc)
    Do $$$AssertStatusOK(sc, "one token below the ceiling is not truncation")
    Do $$$AssertEquals(out, "a complete answer", "and the text comes back")
}

/// With no ceiling requested, no truncation check runs.
///
/// A run that set no limit cannot have been truncated by one, and inventing a
/// comparison against an empty `MaxTokens` would refuse every call.
Method TestNoTokenCeilingMeansNoTruncationCheck()
{
    Set p = ..Wire($ListBuild("an answer of whatever length"), .stub)
    Set p.MaxTokens = ""
    Set stub.UsageJSON = "{""prompt_tokens"":40,""completion_tokens"":9999}"
    Set out = p.Complete("i", "p", .sc)
    Do $$$AssertStatusOK(sc, "no ceiling means no truncation check")
    Do $$$AssertEquals(out, "an answer of whatever length", "and the text comes back")
}

/// Absent usage is not evidence of truncation.
///
/// A provider is entitled to report no usage at all. Treating the resulting empty
/// count as "reached the limit" would refuse every completion from every provider
/// that does not report tokens -- a refusal with no measurement behind it, which is
/// Constitution III inverted: a cap claimed where none was observed.
Method TestAbsentUsageIsNotReadAsTruncation()
{
    Set p = ..Wire($ListBuild("a complete answer"), .stub)
    Set p.MaxTokens = 16
    Set stub.UsageJSON = ""
    Set out = p.Complete("i", "p", .sc)
    Do $$$AssertStatusOK(sc, "a provider that reports no usage is not refused")
    Do $$$AssertEquals(out, "a complete answer", "and its text comes back")
}

}
