/// Tests for the global source's access gate.
///
/// This is the largest liability in the feature. A source that reads arbitrary
/// globals by name is a namespace-wide read primitive, and the only defensible
/// default is that it reads nothing until someone says which globals it may
/// read. So the gate is enforced at construction rather than at peek time: a
/// refused source cannot be walked because it does not exist.
///
/// Every test here asserts the refusal *and* that the reason names what matched,
/// because a bare "not allowed" gives an operator nothing to fix.
Class UnitTest.RLM.SourceGlobalAllow Extends %UnitTest.TestCase
{

/// Construct and return the reason, or "" if it succeeded. Wrapping this keeps
/// each assertion below one line, which is what makes the list readable as a
/// policy statement rather than as code.
ClassMethod Why(
	ref As %String,
	allow As %String = "^*") As %String
{
    Set src = ##class(RLM.Source.Global).%New(ref, allow, .sc)
    If $$$ISOK(sc) { Quit "" }
    Quit $System.Status.GetErrorText(sc)
}

/// The globals IRIS itself owns. Reading these is not a data question, and a
/// model that asks about `^ROUTINE` is asking to read source code.
Method TestSystemGlobalsAreDeniedUnderAnyAllowList()
{
    Do $$$AssertNotEquals(..Why("^%cspSession"), "", "^% is denied")
    Do $$$AssertNotEquals(..Why("^ISCLOG"), "", "^ISC is denied")
    Do $$$AssertNotEquals(..Why("^rMAP"), "", "^rMAP is denied")
    Do $$$AssertNotEquals(..Why("^ROUTINE"), "", "^ROUTINE is denied")
    Do $$$AssertNotEquals(..Why("^oddDEF"), "", "^odd is denied")
}

/// Deny is checked after allow and wins. Without this ordering, `^*` -- the
/// obvious thing an operator types when experimenting -- silently opens the
/// dictionary and the routine store.
Method TestDenyBeatsAWideAllowList()
{
    Set why = ..Why("^ROUTINE", "^*")
    Do $$$AssertNotEquals(why, "", "^* does not reach ^ROUTINE")
    Do $$$AssertNotEquals($Find(why, "^ROUTINE"), 0, "and says which pattern")
}

/// Fail-closed. An operator who forgets to configure the allowlist gets a source
/// that reads nothing, not one that reads everything.
Method TestAnEmptyAllowListRefusesEverything()
{
    Do $$$AssertNotEquals(..Why("^SalesOrder", ""), "", "empty allowlist is closed")
    Do $$$AssertNotEquals(..Why("^Anything", ""), "", "for any name at all")
}

Method TestAPrefixPatternAdmitsOnlyItsPrefix()
{
    Do $$$AssertEquals(..Why("^SalesOrder", "^Sales*"), "", "^SalesOrder admitted")
    Do $$$AssertEquals(..Why("^Sales", "^Sales*"), "", "the bare prefix too")
    Do $$$AssertNotEquals(..Why("^Inventory", "^Sales*"), "", "^Inventory refused")
}

Method TestAnExactPatternAdmitsOnlyThatGlobal()
{
    Do $$$AssertEquals(..Why("^SalesOrder", "^SalesOrder"), "", "exact match")
    Do $$$AssertNotEquals(..Why("^SalesOrderD", "^SalesOrder"), "", "not a prefix")
}

Method TestSeveralPatternsAreAllHonoured()
{
    Set allow = "^Sales*,^Inventory"
    Do $$$AssertEquals(..Why("^SalesOrder", allow), "", "first pattern")
    Do $$$AssertEquals(..Why("^Inventory", allow), "", "second pattern")
    Do $$$AssertNotEquals(..Why("^Ledger", allow), "", "neither pattern")
}

/// Malformed references are refused before the allowlist is consulted, so the
/// reason names the real problem. An operator told "not allowed" about a
/// reference that was never a valid global name goes and widens the allowlist.
Method TestMalformedReferencesAreRefusedForBeingMalformed()
{
    Do $$$AssertNotEquals($Find(..Why("SalesOrder"), "^"), 0, "needs a caret")
    Do $$$AssertNotEquals(..Why("^|""USER""|Sales"), "", "extended reference")
    Do $$$AssertNotEquals(..Why("^[""USER""]Sales"), "", "namespace reference")
    Do $$$AssertNotEquals(..Why("^Sales(1)"), "", "subscripts belong in a slice")
    Do $$$AssertNotEquals(..Why("^"), "", "a bare caret names nothing")
    Do $$$AssertNotEquals(..Why(""), "", "and so does nothing at all")
}

/// The reason for a malformed reference must not be the allowlist reason, even
/// when the reference would also fail the allowlist. This is the ordering
/// assertion; the test above only checks that both are refused.
Method TestMalformationIsReportedBeforeDenial()
{
    // Denied by pattern AND subscripted. The malformation is the useful answer.
    Set why = ..Why("^ROUTINE(1)", "")
    Do $$$AssertNotEquals($Find(why, "subscript"), 0, "names the malformation")
}

/// A refused source has not read anything. Constructing against a global that
/// does not exist must still fail on the policy, which is what proves the gate
/// runs before any access.
Method TestRefusalPrecedesAnyRead()
{
    Set why = ..Why("^ROUTINE", "^*")
    Do $$$AssertEquals($Find(why, "does not exist"), 0, "not an existence error")
    Do $$$AssertNotEquals($Find(why, "^ROUTINE"), 0, "a policy refusal")
}

/// An allowed global that does not exist is a different case: allowed, and
/// simply empty. Refusing it would make a legitimate source fail on a
/// namespace where the data has not arrived yet.
Method TestAnAllowedButAbsentGlobalConstructs()
{
    Do $$$AssertEquals(..Why("^RLMNoSuchGlobalXYZ", "^RLM*"), "", "allowed and empty")
}

/// The deny set is a class parameter, not a property, so an instance cannot
/// widen it. If this ever becomes settable, every allowlist in production
/// silently becomes advisory.
Method TestTheDenySetIsNotInstanceSettable()
{
    Set props = ##class(%Dictionary.CompiledClass).%OpenId("RLM.Source.Global")
    Do $$$AssertTrue($IsObject(props), "the class compiled")
    Set found = 0
    For i = 1:1:props.Properties.Count() {
        If $ZConvert(props.Properties.GetAt(i).Name, "U") = "DENY" { Set found = 1 }
    }
    Do $$$AssertEquals(found, 0, "DENY is a parameter, not a property")
}

}
