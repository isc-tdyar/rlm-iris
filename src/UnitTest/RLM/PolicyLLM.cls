/// Tests for the model-driven split policy.
///
/// The behaviour under test is the one the engine had before policies existed,
/// so most of these assertions are about what did *not* change. The two that are
/// new are the narrowing: the model now names a dimension rather than a list of
/// slice paths, and an unrecognised name is a decline rather than a refusal the
/// run has to recover from.
Class UnitTest.RLM.PolicyLLM Extends %UnitTest.TestCase
{

Property Source As RLM.Source;

Method OnBeforeOneTest(testname As %String) As %Status
{
    Set ..Source = ##class(UnitTest.RLM.Fixture).%New("fixture store")
    Quit $$$OK
}

Method TestReturnsTheDimensionTheModelNamed()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("size"))
    Set policy = ##class(RLM.Policy.LLM).%New(llm)
    Set d = policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("color", "size"), ##class(RLM.Budget).%New(8))

    // `size` is the worse split on this fixture, which is the point: this policy
    // reports what the model chose, not what the statistics would have chosen.
    Do $$$AssertEquals(d.Dimension, "size", "the model's choice, not the better one")
    Do $$$AssertEquals(d.PolicyClass, "RLM.Policy.LLM", "who decided")
    Do $$$AssertNotEquals(d.Reason, "", "and it says the model decided")
}

/// Whitespace and a trailing commentary line are what a real provider actually
/// returns; the first non-empty stripped line is the whole of the parsing.
Method TestSurroundingWhitespaceIsToleratedNotParsed()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("  color  "_$Char(10)_"because"))
    Set policy = ##class(RLM.Policy.LLM).%New(llm)
    Set d = policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("color", "size"), ##class(RLM.Budget).%New(8))
    Do $$$AssertEquals(d.Dimension, "color", "stripped, and only the first line read")
}

/// FR-006, and Constitution II. A name the store does not offer must not become a
/// split, and the reader must be able to see what the model actually said --
/// otherwise a hallucination reads as a store that could not be divided.
Method TestHallucinatedDimensionBecomesADecline()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("shape"))
    Set policy = ##class(RLM.Policy.LLM).%New(llm)
    Set d = policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("color", "size"), ##class(RLM.Budget).%New(8))

    Do $$$AssertEquals(d.Dimension, "", "no split was made")
    Do $$$AssertNotTrue(d.Chose(), "and Chose() says so")
    Set quoted = $Find(d.Reason, "shape")
    Do $$$AssertNotEquals(quoted, 0, "the model's answer is quoted back")
}

/// The word `none` is a legitimate answer, and it must land on the same path as
/// an invented name: a decline with a reason, not an error.
Method TestNoneIsADecline()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("none"))
    Set policy = ##class(RLM.Policy.LLM).%New(llm)
    Set d = policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("color", "size"), ##class(RLM.Budget).%New(8))
    Do $$$AssertEquals(d.Dimension, "", "declined on the model's own say-so")
    Do $$$AssertNotEquals(d.Reason, "", "with a reason")
}

/// Constitution I, at the policy boundary. The prompt may carry aggregates and
/// candidate names and nothing else.
Method TestPromptListsOnlyCandidatesAndAggregates()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("color"))
    Set policy = ##class(RLM.Policy.LLM).%New(llm)
    Do policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("color", "size"), ##class(RLM.Budget).%New(8))

    Set prompt = llm.PromptAt(1)
    Do $$$AssertNotEquals($Find(prompt, "n=1000"), 0, "the aggregate is present")
    Do $$$AssertNotEquals($Find(prompt, "color"), 0, "both candidates are offered")
    Do $$$AssertNotEquals($Find(prompt, "size"), 0, "including the loser")
    // A child's figures belong to the sub-call that examines it. Offering them
    // here would make the choice a measurement, which is Greedy's job, and would
    // grow the prompt with the store's fan-out.
    Set leak = $Find(prompt, "n=600")
    Do $$$AssertEquals(leak, 0, "no child statistics reach the choice")
}

/// A dimension the engine did not offer must not be offered by the prompt
/// either, or the model is being invited to name something that will be refused.
Method TestUnofferedDimensionIsNotInThePrompt()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("color"))
    Set policy = ##class(RLM.Policy.LLM).%New(llm)
    Do policy.ChooseSplit(..Source, ..Source.Peek(""), $ListBuild("color"),
        ##class(RLM.Budget).%New(8))
    Set offered = $Find(llm.PromptAt(1), "size")
    Do $$$AssertEquals(offered, 0, "only the candidates the engine computed")
}

Method TestChargesExactlyOneModelCall()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("color"))
    Set policy = ##class(RLM.Policy.LLM).%New(llm)
    Set budget = ##class(RLM.Budget).%New(8)
    Do policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("color", "size"), budget)

    Do $$$AssertEquals(budget.Used, 1, "one call to choose, no more")
    Do $$$AssertEquals(llm.Calls, 1, "and the provider saw exactly one")
    // This policy measures nothing, so it must not spend the peek pool either.
    Do $$$AssertEquals(budget.PeeksUsed, 0, "and no peek was taken")
}

/// The counterpart to Greedy's TestNeverTouchesTheModelCallPool: the reserved
/// synthesis slot is barred to both pools, so a policy cannot leave a run unable
/// to answer.
Method TestCannotConsumeTheReservedSlot()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("color"))
    Set policy = ##class(RLM.Policy.LLM).%New(llm)
    Set budget = ##class(RLM.Budget).%New(1)
    Set d = policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("color", "size"), budget)

    Do $$$AssertEquals(llm.Calls, 0, "the reserved slot was not spent")
    Do $$$AssertNotTrue(d.Chose(), "so no split was chosen")
    Do $$$AssertTrue(d.Capped, "and the cap that bit is reported")
}

/// A provider failure is a decline, not an exception: obligation 7. The run has a
/// reserved synthesis slot precisely so it can still answer coarsely.
Method TestProviderFailureIsADeclineNotAThrow()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("color"))
    Set llm.FailAtCall = 1
    Set policy = ##class(RLM.Policy.LLM).%New(llm)
    Set d = policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("color", "size"), ##class(RLM.Budget).%New(8))
    Do $$$AssertNotTrue(d.Chose(), "no split")
    Do $$$AssertNotEquals(d.Reason, "", "and the failure is on the record")
}

/// Every candidate goes on the record whether or not the model mentioned it.
/// Without this the trace of an LLM run cannot be re-scored against the arms it
/// did not take, which is the whole of User Story 3.
Method TestAllCandidatesAreRecordedNotJustTheChoice()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("color"))
    Set policy = ##class(RLM.Policy.LLM).%New(llm)
    Set d = policy.ChooseSplit(..Source, ..Source.Peek(""),
        $ListBuild("color", "size"), ##class(RLM.Budget).%New(8))

    Do $$$AssertEquals(d.Candidates.Count(), 2, "both arms recorded")
    Do $$$AssertEquals(d.Candidates.GetAt(1).Dimension, "color", "declaration order")
    // No score on any of them: this policy did not measure anything, and an
    // unscored arm is honest where a copied parent metric would not be.
    Do $$$AssertEquals(d.Candidates.GetAt(2).Score, "", "and neither was scored")
    Do $$$AssertEquals(d.MetricAfter, "", "nor was the choice itself")
}

Method TestNoCandidatesIsADeclineWithoutAModelCall()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("color"))
    Set policy = ##class(RLM.Policy.LLM).%New(llm)
    Set budget = ##class(RLM.Budget).%New(8)
    Set d = policy.ChooseSplit(..Source, ..Source.Peek(""), "", budget)

    Do $$$AssertEquals(llm.Calls, 0, "nothing to ask about, so nothing was asked")
    Do $$$AssertEquals(budget.Used, 0, "and nothing charged")
    Do $$$AssertNotEquals(d.Reason, "", "stated plainly")
}

}
