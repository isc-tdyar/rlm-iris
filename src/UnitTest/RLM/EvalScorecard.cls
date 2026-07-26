/// Tests for RLM.Eval.Scorecard: run several policies over one store and report
/// what each one cost and how well it divided.
///
/// This is the milestone's headline question -- "does the model beat Greedy?" --
/// made answerable without a live provider. Every run here is an ordinary
/// `RLM.Engine.Run` with a scripted LLM, so the thing being scored is the thing a
/// caller would get in production.
///
/// Every assertion sits on one line: a macro's arguments cannot span source lines,
/// and a continued `$$$AssertTrue` is MPP5612.
Class UnitTest.RLM.EvalScorecard Extends %UnitTest.TestCase
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

ClassMethod Source() As UnitTest.RLM.FixtureSeparating
{
    Quit ##class(UnitTest.RLM.FixtureSeparating).%New()
}

ClassMethod Question() As %String
{
    Quit "how does this store divide?"
}

/// Every reply is "region", which is a legal answer for RLM.Policy.LLM (a
/// dimension the fixture offers) and serviceable prose for a sub-call or a
/// synthesis. One script can therefore serve every policy in a card without the
/// replies having to be dealt out by role.
ClassMethod Scripted(n As %Integer = 24) As RLM.LLM.Null
{
    Set script = ""
    For i = 1:1:n { Set script = script_$ListBuild("region") }
    Quit ##class(RLM.LLM.Null).%New(script)
}

ClassMethod Both() As %List
{
    Quit $ListBuild("RLM.Policy.Greedy", "UnitTest.RLM.PolicyBad")
}

/// FR-008. A row that reported only an objective would let a policy buy a better
/// division with ten times the calls and look strictly better for it.
Method TestOneRowPerPolicyWithCostAndObjective()
{
    Set card = ##class(RLM.Eval.Scorecard).Score(..Source(), ..Question(), ..Both(), ..Scripted())
    Do $$$AssertEquals(card.rows.%Size(), 2, "one row per policy")
    For i = 0:1:card.rows.%Size() - 1 {
        Set r = card.rows.%Get(i)
        Do $$$AssertNotEquals(r.policy, "", "the row names its policy: "_r.policy)
        Do $$$AssertNotEquals(r.runId, "", "and the run it came from: "_r.runId)
        Do $$$AssertTrue(r.calls > 0, "and what it cost in calls: "_r.calls)
        Do $$$AssertTrue(r.peeks > 0, "and in peeks: "_r.peeks)
        Do $$$AssertTrue(r.slices > 0, "and how many slices it examined: "_r.slices)
        Do $$$AssertEquals(r.error, "", "and it was scored")
        Do $$$AssertNotEquals(r.objective, "", "with an objective: "_r.objective)
    }
}

/// SC-005. The scorecard has to be able to tell a good division from a bad one,
/// and the only way to assert that is to run a policy that is bad on purpose.
Method TestAGoodPolicyOutranksABadOne()
{
    Set card = ##class(RLM.Eval.Scorecard).Score(..Source(), ..Question(), ..Both(), ..Scripted())
    Set good = card.rows.%Get(0), bad = card.rows.%Get(1)
    Do $$$AssertEquals(good.policy, "RLM.Policy.Greedy", "the first row is Greedy")
    Do $$$AssertEquals(bad.policy, "UnitTest.RLM.PolicyBad", "the second is the control")
    // Lower is better: the objective is the mean metric of what the run was left
    // holding.
    Set msg = "the good policy's objective is strictly better: "_good.objective_" < "_bad.objective
    Do $$$AssertTrue(good.objective < bad.objective, msg)
    // Asserted against the fixture's hand-computed number, not against a second
    // call to the same code.
    Set want = $FNumber(##class(UnitTest.RLM.FixtureSeparating).RegionScore(), "", 3)
    Do $$$AssertEquals($FNumber(good.objective, "", 3), want, "Greedy's objective is the separating dimension's child metric")
}

/// The question SPEC §5 leaves open, answered offline. A scripted provider is a
/// provider: the policy runs its real code path and spends real calls.
Method TestTheLLMPolicyIsScoredOffline()
{
    Set card = ##class(RLM.Eval.Scorecard).Score(..Source(), ..Question(), $ListBuild("RLM.Policy.LLM"), ..Scripted())
    Set r = card.rows.%Get(0)
    Do $$$AssertEquals(r.error, "", "the LLM policy was scored")
    Do $$$AssertNotEquals(r.objective, "", "with an objective: "_r.objective)
    Do $$$AssertEquals(r.chose, "region", "and it chose the dimension it named")
    // Greedy spends no call deciding; this policy spends one per decision, and the
    // difference is the entire cost side of the comparison.
    Set greedy = ##class(RLM.Eval.Scorecard).Score(..Source(), ..Question(), $ListBuild("RLM.Policy.Greedy"), ..Scripted())
    Set gcalls = greedy.rows.%Get(0).calls
    Do $$$AssertTrue(r.calls > gcalls, "and it cost more calls than Greedy: "_r.calls_" > "_gcalls)
}

/// SC-003. Two scorecards over an unchanged store render byte for byte the same,
/// or no comparison drawn from one of them means anything.
Method TestScoringIsDeterministic()
{
    Set a = ##class(RLM.Eval.Scorecard).Score(..Source(), "q", ..Both(), ..Scripted())
    Set b = ##class(RLM.Eval.Scorecard).Score(..Source(), "q", ..Both(), ..Scripted())
    Set ra = ##class(RLM.Eval.Scorecard).Render(a)
    Set rb = ##class(RLM.Eval.Scorecard).Render(b)
    Do $$$AssertNotEquals(ra, "", "the card rendered")
    Do $$$AssertEquals(ra, rb, "two scorecards over an unchanged store render identically")
    // The run ids differ between the two cards, which is exactly why they are on
    // the data and not in the rendering.
    Do $$$AssertNotEquals(a.rows.%Get(0).runId, b.rows.%Get(0).runId, "the two cards are from different runs")
}

/// FR-010. An objective computed from a run that failed halfway is a number with
/// no meaning attached, and it would sit in the table looking exactly like one
/// that has.
Method TestAFailedPolicyRowReportsTheFailure()
{
    Set llm = ..Scripted()
    // Call 1 is the decision, call 2 the first sub-call. Failing the sub-call is
    // the case that matters: the run continues and produces a report, so nothing
    // else would stop it from being scored.
    Set llm.FailAtCall = 2
    Set card = ##class(RLM.Eval.Scorecard).Score(..Source(), ..Question(), $ListBuild("RLM.Policy.LLM"), llm)
    Set r = card.rows.%Get(0)
    Do $$$AssertNotEquals(r.error, "", "the failure is reported: "_r.error)
    Do $$$AssertEquals(r.objective, "", "and no objective was computed")
}

/// FR-009. Cost and objective are separate figures and are never netted into one
/// ranking number -- a future "helpful" combined column is precisely the
/// regression this asserts against, because it would decide the tradeoff on the
/// reader's behalf with weights nobody chose.
Method TestCostAndObjectiveAreSeparateFigures()
{
    Set card = ##class(RLM.Eval.Scorecard).Score(..Source(), "q", ..Both(), ..Scripted())
    Set text = ##class(RLM.Eval.Scorecard).Render(card)
    Set header = $ZConvert($Piece(text, $Char(10), 1), "L")
    Do $$$AssertTrue($Find(header, "calls") > 0, "the card has a calls column")
    Do $$$AssertTrue($Find(header, "peeks") > 0, "and a peeks column")
    Do $$$AssertTrue($Find(header, "objective") > 0, "and an objective column")
    Do $$$AssertEquals($Find(header, "combined"), 0, "and no combined column")
    Do $$$AssertEquals($Find(header, "rank"), 0, "and no rank column")
    Do $$$AssertEquals($Find(header, "overall"), 0, "and no overall column")
}

/// Objective reads the store's own recorded figures. A card scored against a
/// different store's trace would be comparing two populations, so it refuses.
Method TestObjectiveRefusesAForeignTrace()
{
    Set card = ##class(RLM.Eval.Scorecard).Score(..Source(), "q", $ListBuild("RLM.Policy.Greedy"), ..Scripted())
    Set runId = card.rows.%Get(0).runId
    Set other = ##class(UnitTest.RLM.Fixture).%New()
    Set obj = ##class(RLM.Eval.Scorecard).Objective(other, runId, .err)
    Do $$$AssertEquals(obj, "", "no objective from another store's trace")
    Do $$$AssertNotEquals(err, "", "and it says why: "_err)
}

/// A run that examined no slice has nothing to average, and 0 would read as a
/// perfect division.
Method TestARunWithNoSlicesHasNoObjective()
{
    // The flat fixture divides nothing, so Greedy declines and no leaf is examined.
    Set flat = ##class(UnitTest.RLM.FixtureFlat).%New()
    Set card = ##class(RLM.Eval.Scorecard).Score(flat, "q", $ListBuild("RLM.Policy.Greedy"), ..Scripted())
    Set r = card.rows.%Get(0)
    Do $$$AssertEquals(r.objective, "", "no objective, not 0")
    Do $$$AssertNotEquals(r.error, "", "and a reason: "_r.error)
}

/// An unknown policy class is that row's failure and not the card's: a caller
/// comparing four policies must not lose the other three to one typo.
Method TestAnUnknownPolicyIsThatRowsFailure()
{
    Set policies = $ListBuild("RLM.Policy.Greedy", "RLM.Policy.NoSuchThing")
    Set card = ##class(RLM.Eval.Scorecard).Score(..Source(), "q", policies, ..Scripted())
    Do $$$AssertEquals(card.rows.%Size(), 2, "both rows are present")
    Do $$$AssertEquals(card.rows.%Get(0).error, "", "the good row is scored")
    Set bad = card.rows.%Get(1).error
    Do $$$AssertNotEquals(bad, "", "the bad row carries its failure: "_bad)
}

}
