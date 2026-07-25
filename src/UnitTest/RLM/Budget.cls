/// Tests for call accounting.
///
/// The reserved synthesis slot is the point of this class. A decomposition that
/// spends its last call on one more peek produces no answer at all, which is
/// strictly worse than a coarser answer -- so exploration is charged against a
/// smaller pool than synthesis is.
Class UnitTest.RLM.Budget Extends %UnitTest.TestCase
{

Method TestRemainingExcludesTheReservedSlot()
{
    Set b = ##class(RLM.Budget).%New(10)
    Do $$$AssertEquals(b.Remaining(), 9, "one call is held back for synthesis")
}

Method TestChargeConsumesTheExplorationPool()
{
    Set b = ##class(RLM.Budget).%New(5)
    Do $$$AssertStatusOK(b.Charge(3), "three peeks affordable")
    Do $$$AssertEquals(b.Used, 3, "used counts up")
    Do $$$AssertEquals(b.Remaining(), 1, "one exploration call left")
}

/// The case the class exists for.
Method TestExplorationCannotEatTheSynthesisSlot()
{
    Set b = ##class(RLM.Budget).%New(3)
    Do $$$AssertStatusOK(b.Charge(2), "two of three affordable")
    Do $$$AssertStatusNotOK(b.Charge(1), "the third is reserved")
    Do $$$AssertEquals(b.Used, 2, "a refused charge does not count")
}

Method TestSynthesisMayUseTheReservedSlot()
{
    Set b = ##class(RLM.Budget).%New(3)
    Do $$$AssertStatusOK(b.Charge(2), "exploration fills its pool")
    Do $$$AssertStatusOK(b.ChargeSynthesis(), "synthesis draws on the reserve")
    Do $$$AssertEquals(b.Used, 3, "budget fully spent")
    Do $$$AssertStatusNotOK(b.ChargeSynthesis(), "and nothing beyond it")
}

Method TestRemainingNeverGoesNegative()
{
    Set b = ##class(RLM.Budget).%New(2)
    Do b.Charge(1)
    Do b.ChargeSynthesis()
    Do $$$AssertEquals(b.Remaining(), 0, "floored at zero, not -1")
}

Method TestCanSpendAsksWithoutCharging()
{
    Set b = ##class(RLM.Budget).%New(4)
    Do $$$AssertTrue(b.CanSpend(3), "three affordable")
    Do $$$AssertNotTrue(b.CanSpend(4), "four is not")
    Do $$$AssertEquals(b.Used, 0, "asking is free")
}

}
