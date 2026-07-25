/// Tests for the slice grammar. No database, no language model.
///
/// The grammar is the security boundary: the model may only name a slice that
/// RLM.Slice can resolve, so every refusal below is a refusal the model cannot
/// talk its way past. These tests exist to keep that property from eroding.
Class UnitTest.RLM.Slice Extends %UnitTest.TestCase
{

Property Source As RLM.Source;

Method OnBeforeOneTest(testname As %String) As %Status
{
    Set ..Source = ##class(UnitTest.RLM.Fixture).%New()
    Quit $$$OK
}

Method TestResolvesSingleComponent()
{
    Set sc = ##class(RLM.Slice).Resolve(..Source, "color:red", .pred, .label)
    Do $$$AssertStatusOK(sc, "color:red resolves")
    Do $$$AssertEquals(pred, "color:red", "predicate is the fixture key")
    Do $$$AssertEquals(label, "red", "label comes from the dimension child")
}

Method TestResolvesNestedComponents()
{
    Set sc = ##class(RLM.Slice).Resolve(..Source, "color:red/size:small", .pred, .label)
    Do $$$AssertStatusOK(sc, "two-component path resolves")
    Do $$$AssertEquals(pred, "color:red/size:small", "predicate keeps order")
}

Method TestEmptyPathIsTheRoot()
{
    Set sc = ##class(RLM.Slice).Resolve(..Source, "", .pred, .label)
    Do $$$AssertStatusOK(sc, "empty path is the whole store")
    Do $$$AssertEquals(pred, "", "root predicate is empty")
}

/// The model invents a dimension. This is the case that would be an injection
/// if predicates were model-authored.
Method TestRefusesUnknownDimension()
{
    Set sc = ##class(RLM.Slice).Resolve(..Source, "shape:round", .pred, .label)
    Do $$$AssertStatusNotOK(sc, "unknown dimension refused")
}

Method TestRefusesUnknownToken()
{
    Set sc = ##class(RLM.Slice).Resolve(..Source, "color:green", .pred, .label)
    Do $$$AssertStatusNotOK(sc, "unknown token refused")
}

/// A component without exactly one colon is not a slice name. Accepting these
/// is how a grammar starts leaking into a query language.
Method TestRefusesMalformedComponent()
{
    Do $$$AssertStatusNotOK(##class(RLM.Slice).Resolve(..Source, "color", .p1), "no colon")
    Do $$$AssertStatusNotOK(##class(RLM.Slice).Resolve(..Source, "color:red:extra", .p2), "two colons")
    Do $$$AssertStatusNotOK(##class(RLM.Slice).Resolve(..Source, ":red", .p3), "empty dimension")
    Do $$$AssertStatusNotOK(##class(RLM.Slice).Resolve(..Source, "color:", .p4), "empty token")
}

/// Splitting twice on the same dimension cannot narrow anything, and allowing
/// it lets a confused model burn its whole budget going nowhere.
Method TestRefusesRepeatedDimension()
{
    Set sc = ##class(RLM.Slice).Resolve(..Source, "color:red/color:blue", .pred, .label)
    Do $$$AssertStatusNotOK(sc, "one dimension may appear once per path")
}

Method TestRefusesPathDeeperThanMaxDepth()
{
    Set deep = "color:red/size:small/color:blue/size:large"
    Set sc = ##class(RLM.Slice).Resolve(..Source, deep, .pred, .label)
    Do $$$AssertStatusNotOK(sc, "path beyond MAXDEPTH refused")
}

/// Injection attempts. The grammar has no escape hatch, so each of these is
/// just an unknown token.
Method TestRefusesInjectionAttempts()
{
    Set attempts = $ListBuild(
        "color:red' OR 1=1--",
        "color:red; DROP TABLE Foo",
        "color:red/../size:small",
        "^%SYS",
        "color:red UNION SELECT 1")
    Set ptr = 0
    While $ListNext(attempts, ptr, attempt) {
        Set sc = ##class(RLM.Slice).Resolve(..Source, attempt, .pred, .label)
        Do $$$AssertStatusNotOK(sc, "refused: "_attempt)
    }
}

Method TestMenuListsEveryChild()
{
    Set menu = ##class(RLM.Slice).Menu(..Source)
    Do $$$AssertNotEquals($Find(menu, "color:red"), 0, "menu names color:red")
    Do $$$AssertNotEquals($Find(menu, "color:blue"), 0, "menu names color:blue")
    Do $$$AssertNotEquals($Find(menu, "size:small"), 0, "menu names size:small")
    Do $$$AssertNotEquals($Find(menu, "size:large"), 0, "menu names size:large")
}

/// Whatever the menu advertises must resolve. If these ever disagree, the model
/// is being offered moves it will then be refused for making.
Method TestEveryAdvertisedSliceResolves()
{
    Set dims = ..Source.Dimensions()
    Set it = dims.%GetIterator()
    While it.%GetNext(.dim, .spec) {
        Set kids = spec.children.%GetIterator()
        While kids.%GetNext(, .child) {
            Set key = dim_":"_child.token
            Do $$$AssertStatusOK(##class(RLM.Slice).Resolve(..Source, key, .p), "advertised "_key)
        }
    }
}

}
