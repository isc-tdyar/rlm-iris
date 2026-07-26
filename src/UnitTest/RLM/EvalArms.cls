/// Tests for RLM.Eval.Arms: score, at every recorded decision, every candidate
/// dimension the run did not take.
///
/// This is what turns a trace from an audit log into an evaluation dataset. The
/// counterfactual is answerable because the model never authored a predicate: every
/// arm is a name the store itself offered, recorded at run time, so re-scoring it
/// is a peek and not a guess.
Class UnitTest.RLM.EvalArms Extends %UnitTest.TestCase
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

ClassMethod Scripted(n As %Integer = 8) As RLM.LLM.Null
{
    Set script = ""
    For i = 1:1:n { Set script = script_$ListBuild("finding "_i) }
    Quit ##class(RLM.LLM.Null).%New(script)
}

/// Record a Greedy run over the separating fixture. Greedy chooses `region`, so
/// `channel` is the arm nobody took.
ClassMethod Record(
	Output traceId As %Integer,
	source As RLM.Source = "") As %String
{
    Set src = $Select($IsObject(source):source, 1:..Source())
    Set engine = ##class(RLM.Engine).%New(src, ..Scripted(),
        ##class(RLM.Budget).%New(16), ##class(RLM.Policy.Greedy).%New())
    Set engine.DurableTrace = 1
    Quit engine.Run("how does this store divide?", .traceId)
}

/// The arm the run did not take carries a score, and that score is the one a
/// direct peek gives -- asserted against the fixture's hand-computed number rather
/// than against a second call to the same code.
Method TestAnUnchosenArmIsScored()
{
    Do ..Record(.traceId)
    Set result = ##class(RLM.Eval.Arms).Enumerate(..Source(), traceId)
    Do $$$AssertEquals(result.arms.%Size(), 1, "one unchosen candidate at the root")

    Set arm = result.arms.%Get(0)
    Do $$$AssertEquals(arm.dimension, ##class(UnitTest.RLM.FixtureSeparating).NotSeparating(), "the arm is the dimension not chosen")
    Do $$$AssertEquals(arm.chosen, ##class(UnitTest.RLM.FixtureSeparating).Separating(), "and it records what was chosen instead")
    Do $$$AssertEquals(arm.error, "", "it was scored")
    Do $$$AssertEquals($FNumber(arm.score, "", 3), $FNumber(##class(UnitTest.RLM.FixtureSeparating).ChannelScore(), "", 3), "and the score is the hand-computed one")
}

/// The chosen arm is not re-scored. It is already on the record with the metric
/// the run measured, and re-peeking it would spend budget to learn nothing.
Method TestTheChosenArmIsNotEnumerated()
{
    Do ..Record(.traceId)
    Set result = ##class(RLM.Eval.Arms).Enumerate(..Source(), traceId)
    Set chosen = ##class(UnitTest.RLM.FixtureSeparating).Separating()
    For i = 0:1:result.arms.%Size() - 1 {
        Do $$$AssertNotEquals(result.arms.%Get(i).dimension, chosen, "the chosen dimension is not an arm")
    }
}

/// Constitution V. Enumeration reads the store and the record; a model call here
/// would make the counterfactual a generated opinion.
Method TestEnumerationSpendsNoModelCall()
{
    Do ..Record(.traceId)
    Set result = ##class(RLM.Eval.Arms).Enumerate(..Source(), traceId)
    Do $$$AssertEquals(result.calls, 0, "no model call")
    Do $$$AssertTrue(result.peeks > 0, "but peeks were spent: "_result.peeks)
}

/// "Was declining right?" is the most interesting question a trace can be asked,
/// and it is only answerable if a declined decision still has its candidates
/// scored.
Method TestADeclinedDecisionStillScoresEveryCandidate()
{
    // The flat fixture's dimensions divide nothing, so Greedy declines.
    Set flat = ##class(UnitTest.RLM.FixtureFlat).%New()
    Do ..Record(.traceId, flat)
    Set decisions = ##class(RLM.Trace).Decisions(traceId, 1)
    Do $$$AssertTrue(decisions.Count() > 0, "a decision was recorded")
    Do $$$AssertNotTrue(decisions.GetAt(1).Chose(), "and it declined")

    Set result = ##class(RLM.Eval.Arms).Enumerate(flat, traceId)
    Do $$$AssertTrue(result.arms.%Size() > 0, "a declined decision still yields arms: "_result.arms.%Size())
    Set arm = result.arms.%Get(0)
    Do $$$AssertEquals(arm.chosen, "", "with no chosen dimension recorded against them")
    Do $$$AssertEquals(arm.error, "", "and they were scored anyway")
}

/// FR-005. 0 is a legitimate score meaning "divides nothing"; an unscorable arm
/// must not borrow it. Conflating the two makes the enumeration unreadable exactly
/// where a reader is looking hardest.
Method TestAnUnscorableArmCarriesItsReasonAndNoScore()
{
    Do ..Record(.traceId)
    // A source whose peeks fail: same dimensions, no statistics behind them.
    Set broken = ##class(UnitTest.RLM.FixtureSeparatingBroken).%New()
    Set result = ##class(RLM.Eval.Arms).Enumerate(broken, traceId)
    Do $$$AssertEquals(result.arms.%Size(), 1, "the arm is still reported")
    Set arm = result.arms.%Get(0)
    Do $$$AssertNotEquals(arm.error, "", "with a reason: "_arm.error)
    Do $$$AssertEquals(arm.score, "", "and no score -- not 0")
}

/// Constitution III. An enumeration that stopped early is indistinguishable from a
/// complete one unless it says so.
Method TestEnumerationIsBoundedAndReportsWhatItSpent()
{
    Do ..Record(.traceId)
    Set result = ##class(RLM.Eval.Arms).Enumerate(..Source(), traceId, 1)
    Do $$$AssertTrue(result.capped, "a budget below the arm cost sets capped")
    Do $$$AssertEquals(result.peeks, 1, "and it spent exactly the budget")
}

/// An uncapped enumeration says so too, or `capped` carries no information.
Method TestAnAffordableEnumerationIsNotCapped()
{
    Do ..Record(.traceId)
    Set result = ##class(RLM.Eval.Arms).Enumerate(..Source(), traceId, 64)
    Do $$$AssertNotTrue(result.capped, "a sufficient budget does not cap")
}

/// A run with nothing to enumerate reports zero arms. Reporting a failure would
/// make "this run had no alternatives" indistinguishable from "the enumeration
/// broke".
Method TestARunWithNoAlternativesYieldsNoArms()
{
    // One dimension only, so the root decision has no unchosen candidate.
    Set one = ##class(UnitTest.RLM.FixtureOneDim).%New()
    Do ..Record(.traceId, one)
    Set result = ##class(RLM.Eval.Arms).Enumerate(one, traceId)
    Do $$$AssertEquals(result.arms.%Size(), 0, "zero arms")
    Do $$$AssertEquals(result.error, "", "and no error")
}

/// A run id nobody recorded is a caller bug and says so, rather than returning an
/// empty enumeration that reads as "this run had no alternatives".
Method TestAnUnknownRunIsAnError()
{
    Set result = ##class(RLM.Eval.Arms).Enumerate(..Source(), 999999)
    Do $$$AssertNotEquals(result.error, "", "an unknown run is an error: "_result.error)
    Do $$$AssertEquals(result.arms.%Size(), 0, "with no arms")
}

/// Constitution II, at the level this feature operates on: an arm is a name the
/// store offered. One that is no longer a dimension of the store cannot be scored
/// and must not be invented into a predicate to try.
Method TestAnArmTheStoreNoLongerOffersIsRefused()
{
    Do ..Record(.traceId)
    Set narrowed = ##class(UnitTest.RLM.FixtureOneDim).%New()
    Set result = ##class(RLM.Eval.Arms).Enumerate(narrowed, traceId)
    Set found = 0
    For i = 0:1:result.arms.%Size() - 1 {
        Set arm = result.arms.%Get(i)
        If arm.dimension = ##class(UnitTest.RLM.FixtureSeparating).NotSeparating() {
            Set found = 1
            Do $$$AssertNotEquals(arm.error, "", "an arm the store no longer offers is refused: "_arm.error)
            Do $$$AssertEquals(arm.score, "", "and carries no score")
        }
    }
    Do $$$AssertTrue(found, "the arm was reported rather than dropped")
}

}
