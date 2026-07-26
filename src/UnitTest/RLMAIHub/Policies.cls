/// `RLMAIHub.Provider` against AI Hub's authorization and audit seams.
///
/// These seams are what an AI Hub instance offers that a raw HTTP client does not: a
/// completion is authorized before it happens and logged after, by policies the
/// instance owns. Wiring them is most of the argument for the module existing.
///
/// The assertions divide in two. Behavioural: a refusal costs no provider call and
/// comes back as a status, a policy that throws does too, and an audit sink that
/// throws changes nothing. Disclosure: what the audit record contains, and in
/// particular what it does not -- neither the prompt nor the completion. Constitution I
/// is written about what reaches a model, but the prompt carries slice statistics about
/// a store the caller may not be permitted to export, and an audit sink is somewhere
/// those would persist.
///
/// Every assertion sits on one line: a macro's arguments cannot span source lines.
Class UnitTest.RLMAIHub.Policies Extends %UnitTest.TestCase
{

/// A provider wired to a scripted stub, with no policies attached yet.
ClassMethod Wire(
	script As %List = "",
	Output stub As UnitTest.RLMAIHub.StubProvider) As RLMAIHub.Provider
{
    Set stub = ##class(UnitTest.RLMAIHub.StubProvider).%New(script)
    Set p = ##class(RLMAIHub.Provider).%New("stub", "test-model")
    Set p.Provider = stub
    Quit p
}

/// Neither policy is required. An instance that configures no policy must not be
/// harder to use than one that does.
Method TestBothPoliciesAreOptional()
{
    Set p = ..Wire($ListBuild("an answer"), .stub)
    Set out = p.Complete("i", "p", .sc)
    Do $$$AssertStatusOK(sc, "a completion with no policies attached succeeds")
    Do $$$AssertEquals(out, "an answer", "and returns its text")
}

/// The audit policy is told the outcome, its duration, and the status.
Method TestTheAuditPolicyIsToldTheOutcomeWithADuration()
{
    Set p = ..Wire($ListBuild("an answer"), .stub)
    Set audit = ##class(UnitTest.RLMAIHub.StubAudit).%New()
    Set p.AuditPolicy = audit
    Do p.Complete("i", "p", .sc)
    Do $$$AssertStatusOK(sc, "the completion succeeded")
    Do $$$AssertEquals(audit.Calls, 1, "the audit policy was called once")
    Do $$$AssertStatusOK($List(audit.SeenStatus, 1), "and told the call succeeded")
    Set ms = $List(audit.SeenDuration, 1)
    Do $$$AssertTrue(ms?1.N, "with a duration in whole milliseconds: "_ms)
    Set result = $List(audit.SeenResult, 1)
    Do $$$AssertTrue($Find(result, """ok"":1") > 0, "and a result saying so: "_result)
}

/// A failed completion is audited too, with its status and its reason.
///
/// The case that matters more than the success: an audit trail that records only the
/// calls that worked describes a system that never fails.
Method TestAFailedCompletionIsAuditedWithItsStatus()
{
    Set p = ..Wire($ListBuild("never reached"), .stub)
    Set stub.ThrowOnCall = 1
    Set audit = ##class(UnitTest.RLMAIHub.StubAudit).%New()
    Set p.AuditPolicy = audit
    Do p.Complete("i", "p", .sc)
    Do $$$AssertStatusNotOK(sc, "the completion failed")
    Do $$$AssertEquals(audit.Calls, 1, "and the audit policy was still called")
    Do $$$AssertStatusNotOK($List(audit.SeenStatus, 1), "and told it failed")
    Do $$$AssertTrue($Find($List(audit.SeenResult, 1), """ok"":0") > 0, "in the result too")
}

/// The audit record carries no prompt and no completion text.
///
/// Constitution I read the other way. The prompt holds slice statistics about a store
/// the caller may not export and the completion holds the model's reading of them;
/// neither belongs in a sink whose retention the run does not control. The policy is
/// told the shape of the call -- who, which provider, which model, how many tokens --
/// and the report stays the only place the content appears.
Method TestTheAuditRecordCarriesNoPromptOrCompletionText()
{
    Set p = ..Wire($ListBuild("SENTINELREPLY4471"), .stub)
    Set audit = ##class(UnitTest.RLMAIHub.StubAudit).%New()
    Set p.AuditPolicy = audit
    Do p.Complete("SENTINELINSTRUCTIONS9012", "SENTINELPROMPT3355", .sc)
    Do $$$AssertStatusOK(sc, "the completion succeeded")
    Set all = audit.AllOf(1)
    Do $$$AssertTrue($Length(all) > 20, "the policy was given something: "_all)
    Do $$$AssertEquals($Find(all, "SENTINELINSTRUCTIONS9012"), 0, "no instructions reached the audit record")
    Do $$$AssertEquals($Find(all, "SENTINELPROMPT3355"), 0, "no prompt reached it either")
    Do $$$AssertEquals($Find(all, "SENTINELREPLY4471"), 0, "and no completion text")
    // And the other side: what it *is* told, so the record is not merely empty.
    Do $$$AssertTrue($Find(all, "test-model") > 0, "the model is named: "_all)
    Do $$$AssertTrue($Find(all, "rlm-aihub") > 0, "and the caller identified")
}

/// An audit sink that throws does not change the result.
///
/// Logging is not part of the completion. An instance whose audit policy is
/// misconfigured would otherwise fail every call in the run, which is a far larger
/// outage than the one it started as.
Method TestAThrowingAuditSinkDoesNotChangeTheResult()
{
    Set p = ..Wire($ListBuild("an answer"), .stub)
    Set audit = ##class(UnitTest.RLMAIHub.StubAudit).%New()
    Set audit.ThrowAlways = 1
    Set p.AuditPolicy = audit
    Set threw = 0
    Try {
        Set out = p.Complete("i", "p", .sc)
    } Catch {
        Set threw = 1
    }
    Do $$$AssertEquals(threw, 0, "a throwing audit sink does not propagate")
    Do $$$AssertStatusOK(sc, "and the completion still succeeded")
    Do $$$AssertEquals($Get(out), "an answer", "returning its text")
}

/// The authorization policy is consulted, and told what the call is.
Method TestTheAuthorizationPolicyIsConsultedBeforeTheCall()
{
    Set p = ..Wire($ListBuild("an answer"), .stub)
    Set auth = ##class(UnitTest.RLMAIHub.StubAuth).%New()
    Set p.AuthPolicy = auth
    Do p.Complete("i", "p", .sc)
    Do $$$AssertStatusOK(sc, "an authorized completion succeeds")
    Do $$$AssertEquals(auth.Calls, 1, "the policy was asked once")
    Do $$$AssertEquals($List(auth.SeenTool, 1), "rlm.completion", "and told which call it was")
}

/// A refusal is a status, and costs no provider call.
///
/// Asserted from the provider's counter, not only from the status. The point of
/// authorizing before the call is that a call the instance will not permit is never
/// made -- a refusal that arrived after the round-trip would still be billed, and on a
/// metered provider that is the difference the seam exists to make.
Method TestARefusedCompletionNeverReachesTheProvider()
{
    Set p = ..Wire($ListBuild("must not be reached"), .stub)
    Set auth = ##class(UnitTest.RLMAIHub.StubAuth).%New()
    Set auth.RefuseWith = "this namespace may not call out"
    Set p.AuthPolicy = auth
    Set out = p.Complete("i", "p", .sc)
    Do $$$AssertStatusNotOK(sc, "a refusal comes back as a status")
    Do $$$AssertEquals(out, "", "with no text")
    Do $$$AssertEquals(stub.Calls, 0, "and the provider was never called")
    Set text = $System.Status.GetErrorText(sc)
    Do $$$AssertTrue($Find(text, "refused") > 0, "the reason says it was refused: "_text)
    Do $$$AssertTrue($Find(text, "may not call out") > 0, "and carries the policy's own reason")
}

/// A policy that throws is a refusal, not an exception -- and not a pass.
///
/// The direction matters. A misconfigured authorization policy that threw and was
/// swallowed as OK would make every call in the run unauthorized while reporting
/// nothing, which is the precise failure the seam was added to prevent. Failing
/// closed costs the run a slot and says why.
Method TestAThrowingAuthorizationPolicyRefusesRatherThanPasses()
{
    Set p = ..Wire($ListBuild("must not be reached"), .stub)
    Set auth = ##class(UnitTest.RLMAIHub.StubAuth).%New()
    Set auth.ThrowAlways = 1
    Set p.AuthPolicy = auth
    Set threw = 0
    Try {
        Set out = p.Complete("i", "p", .sc)
    } Catch {
        Set threw = 1
    }
    Do $$$AssertEquals(threw, 0, "Complete did not throw")
    Do $$$AssertStatusNotOK(sc, "a throwing policy is a refusal, not a pass")
    Do $$$AssertEquals($Get(out), "", "with no text")
    Do $$$AssertEquals(stub.Calls, 0, "and no provider call was made")
    Do $$$AssertTrue($Find($System.Status.GetErrorText(sc), "policy failed") > 0, "naming the policy")
}

/// A refused completion is audited. Both seams are wired, and the refusal is on the
/// record: an unauthorized attempt is exactly the event an audit trail is for.
Method TestARefusedCompletionIsStillAudited()
{
    Set p = ..Wire($ListBuild("must not be reached"), .stub)
    Set auth = ##class(UnitTest.RLMAIHub.StubAuth).%New()
    Set auth.RefuseWith = "this namespace may not call out"
    Set audit = ##class(UnitTest.RLMAIHub.StubAudit).%New()
    Set p.AuthPolicy = auth, p.AuditPolicy = audit
    Do p.Complete("i", "p", .sc)
    Do $$$AssertStatusNotOK(sc, "the completion was refused")
    Do $$$AssertEquals(audit.Calls, 1, "and the refusal was audited")
    Do $$$AssertStatusNotOK($List(audit.SeenStatus, 1), "with its status")
    Do $$$AssertEquals(stub.Calls, 0, "and still no provider call")
}

}
