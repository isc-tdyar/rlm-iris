/// Tests for the scripted language model.
///
/// Every engine test depends on this class behaving predictably, so it gets its
/// own tests rather than being trusted.
Class UnitTest.RLM.LLMNull Extends %UnitTest.TestCase
{

Method TestReturnsScriptedRepliesInOrder()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("first", "second"))
    Do $$$AssertEquals(llm.Complete("sys", "a", .sc1), "first", "first reply")
    Do $$$AssertEquals(llm.Complete("sys", "b", .sc2), "second", "second reply")
}

Method TestRecordsEveryPrompt()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("x"))
    Do llm.Complete("the instructions", "the prompt", .sc)
    Do $$$AssertEquals(llm.Calls, 1, "one call counted")
    Do $$$AssertEquals(llm.PromptAt(1), "the prompt", "prompt retained verbatim")
    Do $$$AssertEquals(llm.InstructionsAt(1), "the instructions", "instructions retained")
}

/// Running past the script is a test-authoring bug -- the engine made a call the
/// test did not anticipate. Failing loudly beats returning "" and letting the
/// engine limp on into a confusing downstream assertion.
Method TestRunningOffTheEndOfTheScriptFails()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("only"))
    Do llm.Complete("sys", "a", .sc1)
    Do $$$AssertStatusOK(sc1, "scripted call succeeds")
    Set out = llm.Complete("sys", "b", .sc2)
    Do $$$AssertStatusNotOK(sc2, "unscripted call is an error")
    Do $$$AssertEquals(out, "", "and returns nothing")
}

/// Simulating a provider failure must be possible without an unreachable
/// provider, or the engine's error path is never exercised.
Method TestScriptedFailure()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("ok"))
    Set llm.FailAtCall = 1
    Do llm.Complete("sys", "a", .sc)
    Do $$$AssertStatusNotOK(sc, "call 1 fails on demand")
    Do $$$AssertEquals(llm.Calls, 1, "a failed call still counts as a call")
}

}
