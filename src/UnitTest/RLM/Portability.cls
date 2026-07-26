/// Constitution VI over the whole `rlm-core` package, not one class at a time.
///
/// The existing portability tests each name the classes their own milestone added, which
/// means a class added by the *next* milestone is portable only until someone forgets.
/// M5 is exactly that risk: it introduced a real `%AI.*` dependency into the repository
/// for the first time, and the thing keeping it out of `rlm-core` is a package boundary
/// nobody is forced to respect.
///
/// So this walks every class in the `RLM` package and asserts what the module claims:
/// no `%AI.*`, and no `%AI.*` in a property type either -- a property is the way the
/// dependency would arrive silently, since `RLMAIHub.Provider.AuditPolicy` is precisely
/// how it does arrive in the module that is allowed to have it.
///
/// Runs on the portable container, where a failure is the compile error it describes.
///
/// Every assertion sits on one line: a macro's arguments cannot span source lines.
Class UnitTest.RLM.Portability Extends %UnitTest.TestCase
{

/// Every compiled class in the `RLM` package.
ClassMethod Classes() As %List
{
    Set out = "", rs = ##class(%SQL.Statement).%ExecDirect(, "select Name from %Dictionary.CompiledClass where Name %STARTSWITH 'RLM.'")
    While rs.%Next() { Set out = out_$ListBuild(rs.%Get("Name")) }
    Quit out
}

/// No class in `rlm-core` names `%AI.*` in any method body.
///
/// Method source only, which is deliberate: the documentation comments in
/// `RLM.Engine` and `RLM.LLM` say the words "no reference to %AI.*", and a text search
/// that counted those would make the claim unassertable by stating it.
Method TestNoCoreClassReferencesAIHubInCode()
{
    Set classes = ..Classes()
    Do $$$AssertTrue($ListLength(classes) > 20, "the package was enumerated: "_$ListLength(classes)_" class(es)")
    Set offenders = "", ptr = 0
    While $ListNext(classes, ptr, cls) {
        Set text = ##class(UnitTest.RLM.EndToEndReplay).SourceTextOf(cls)
        If text [ "%AI." { Set offenders = offenders_$ListBuild(cls) }
    }
    Do $$$AssertEquals($ListToString(offenders, ", "), "", "no core class calls %AI.*")
}

/// And none declares a property or a superclass of an `%AI.*` type.
///
/// The silent path. A `Property X As %AI.Policy.Audit` compiles to `ERROR #5373` on an
/// IRIS without AI Hub and takes the whole class with it -- no method body involved, so
/// the check above would pass and `zpm load` would still fail on a customer's 2026.1.
Method TestNoCoreClassDeclaresAnAIHubTypeOrSuperclass()
{
    Set classes = ..Classes(), offenders = "", ptr = 0
    While $ListNext(classes, ptr, cls) {
        Set def = ##class(%Dictionary.CompiledClass).%OpenId(cls)
        If '$IsObject(def) { Continue }
        If def.Super [ "%AI." { Set offenders = offenders_$ListBuild(cls_" (super)") }
        For i = 1:1:def.Properties.Count() {
            Set p = def.Properties.GetAt(i)
            If p.Type [ "%AI." { Set offenders = offenders_$ListBuild(cls_"."_p.Name) }
        }
        For i = 1:1:def.Methods.Count() {
            Set m = def.Methods.GetAt(i)
            If m.ReturnType [ "%AI." { Set offenders = offenders_$ListBuild(cls_"."_m.Name_"()") }
            If m.FormalSpec [ "%AI." { Set offenders = offenders_$ListBuild(cls_"."_m.Name_"(arg)") }
        }
    }
    Do $$$AssertEquals($ListToString(offenders, ", "), "", "no core class declares an %AI.* type")
}

/// The engine's own dependencies, named rather than counted.
///
/// Constitution VI is specific: `RLM.Engine` depends on `RLM.Source`, `RLM.LLM`,
/// `RLM.Budget`, `RLM.Trace` and `RLM.Report`, and on no HTTP client and no SQL. The
/// two negatives are what make the engine testable without a network or a table, and
/// they are the ones that erode -- a single `%SQL.Statement` for "just this one count"
/// would not fail any other test in the suite.
Method TestTheEngineReachesNoNetworkAndNoSQL()
{
    Set text = ##class(UnitTest.RLM.EndToEndReplay).SourceTextOf("RLM.Engine")
    Do $$$AssertTrue($Length(text) > 2000, "the engine source was read: "_$Length(text))
    Do $$$AssertEquals(text [ "%Net.", 0, "the engine has no HTTP client")
    Do $$$AssertEquals(text [ "%SQL.Statement", 0, "and runs no SQL of its own")
    Do $$$AssertEquals(text [ "%AI.", 0, "and names no AI Hub class")
}

}
