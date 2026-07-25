/// Tests for the portable REST provider.
///
/// No network. What is tested is the part that breaks without one: the request
/// body the provider builds, and its handling of the response shapes a provider
/// actually returns -- including the ones that are not an answer.
Class UnitTest.RLM.LLMRest Extends %UnitTest.TestCase
{

Method TestBuildsAChatCompletionsBody()
{
    Set llm = ##class(RLM.LLM.REST).%New("https://example.invalid/v1", "gpt-x", "sk-test")
    Set body = llm.BuildBody("be terse", "the question")
    Set obj = {}.%FromJSON(body)
    Do $$$AssertEquals(obj.model, "gpt-x", "model echoed")
    Do $$$AssertEquals(obj.messages.%Get(0).role, "system", "instructions are the system turn")
    Do $$$AssertEquals(obj.messages.%Get(0).content, "be terse", "instructions verbatim")
    Do $$$AssertEquals(obj.messages.%Get(1).role, "user", "prompt is the user turn")
    Do $$$AssertEquals(obj.messages.%Get(1).content, "the question", "prompt verbatim")
}

Method TestParsesTheAssistantMessage()
{
    Set llm = ##class(RLM.LLM.REST).%New("https://example.invalid/v1", "gpt-x")
    Set json = {"choices":[{"message":{"content":"the answer"},"finish_reason":"stop"}]}
    Set out = llm.ParseResponse(json.%ToJSON(), .sc)
    Do $$$AssertStatusOK(sc, "well-formed response parses")
    Do $$$AssertEquals(out, "the answer", "content extracted")
}

/// A provider error arrives as HTTP 200 with an error object often enough that
/// treating it as an answer is a real failure mode -- the engine would put the
/// provider's error text in the report as findings.
Method TestProviderErrorObjectIsAnError()
{
    Set llm = ##class(RLM.LLM.REST).%New("https://example.invalid/v1", "gpt-x")
    Set json = {"error":{"message":"rate limited","type":"rate_limit_error"}}
    Set out = llm.ParseResponse(json.%ToJSON(), .sc)
    Do $$$AssertStatusNotOK(sc, "error object is not an answer")
    Do $$$AssertEquals(out, "", "and yields no text")
}

/// A response truncated by the token limit is not a complete answer. Returning
/// it silently is the self-truncation failure this package exists to avoid.
Method TestTruncatedResponseIsFlagged()
{
    Set llm = ##class(RLM.LLM.REST).%New("https://example.invalid/v1", "gpt-x")
    Set json = {"choices":[{"message":{"content":"half an ans"},"finish_reason":"length"}]}
    Set out = llm.ParseResponse(json.%ToJSON(), .sc)
    Do $$$AssertStatusNotOK(sc, "truncation is reported")
    Set found = $Find($System.Status.GetErrorText(sc), "truncated")
    Do $$$AssertNotEquals(found, 0, "and named as truncation")
}

Method TestGarbageResponseIsAnErrorNotAnAnswer()
{
    Set llm = ##class(RLM.LLM.REST).%New("https://example.invalid/v1", "gpt-x")
    Set out = llm.ParseResponse("not json at all", .sc)
    Do $$$AssertStatusNotOK(sc, "unparseable body is an error")
    Do $$$AssertEquals(out, "", "and yields no text")
}

/// An unreachable endpoint must return a status, not throw: the engine's caveat
/// path depends on getting an error back.
Method TestUnreachableEndpointReturnsAStatus()
{
    Set llm = ##class(RLM.LLM.REST).%New("http://127.0.0.1:1/v1", "gpt-x")
    Set llm.Timeout = 1
    Set out = llm.Complete("sys", "prompt", .sc)
    Do $$$AssertStatusNotOK(sc, "connection failure is a status")
    Do $$$AssertEquals(out, "", "and yields no text")
}

}
