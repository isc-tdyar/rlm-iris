/// Bucketed dimensions: a continuous column split on declared breakpoints.
///
/// Two things are being proved here, and they pull in opposite directions. The
/// first is that a bucket set partitions correctly -- half-open, lower-inclusive,
/// with the rows that fall in no bucket counted rather than lost. The second is
/// that nothing downstream can tell a bucketed dimension from a categorical one:
/// FR-009 exists because a policy that could tell would score the two kinds
/// differently, and then a store's choice of representation would leak into its
/// decomposition.
///
/// Every assertion macro is called on one source line, because $$$macro(...)
/// cannot span lines in ObjectScript: a wrapped call is a syntax error and
/// %UnitTest then skips the class while still reporting "All PASSED".
Class UnitTest.RLM.SourceBucketed Extends %UnitTest.TestCase
{

Property Source As RLM.Source.Table;

Method OnBeforeAllTests() As %Status
{
    Quit ##class(UnitTest.RLM.Widget).Populate()
}

Method OnBeforeOneTest(testname As %String) As %Status
{
    Set ..Source = ##class(RLM.Source.Table).%New("UnitTest.RLM.Widget", "Price")
    Do ..Source.AddDimension("colour", "Colour")
    Quit $$$OK
}

/// A property the class does not have would produce broken SQL on every peek
/// that used it, and the run would then look like a store failure rather than a
/// configuration error. Refused when declared, as AddDimension already is.
Method TestRefusesUnknownProperty()
{
    Set sc = ..Source.AddBucketedDimension("r", "NoSuch", $ListBuild(3, 7))
    Set declared = ..Source.Dimensions().%IsDefined("r")
    Do $$$AssertStatusNotOK(sc, "unknown property refused at declaration")
    Do $$$AssertNotTrue(declared, "and no dimension was left behind")
}

/// No breakpoints means one child covering everything, which is a slice
/// identical to its parent -- the FR-011 case, arrived at by declaration rather
/// than by discovery.
Method TestRefusesEmptyBreakpoints()
{
    Set sc = ..Source.AddBucketedDimension("r", "Rating", "")
    Set declared = ..Source.Dimensions().%IsDefined("r")
    Do $$$AssertStatusNotOK(sc, "an empty breakpoint list is refused")
    Do $$$AssertNotTrue(declared, "and declares nothing")
}

/// Out-of-order breakpoints describe overlapping ranges, so a row would land in
/// two buckets and the children would over-count their parent.
Method TestRefusesUnorderedPoints()
{
    Set sc = ..Source.AddBucketedDimension("r", "Rating", $ListBuild(7, 3))
    Set dup = ..Source.AddBucketedDimension("r", "Rating", $ListBuild(3, 3))
    Set declared = ..Source.Dimensions().%IsDefined("r")
    Do $$$AssertStatusNotOK(sc, "descending breakpoints refused")
    Do $$$AssertStatusNotOK(dup, "and a repeated one too -- an empty range")
    Do $$$AssertNotTrue(declared, "neither declared a dimension")
}

/// n breakpoints, n+1 children, ascending, with ordinal tokens. Tokens are
/// ordinals rather than range strings so that rewording a label does not
/// invalidate a trace that named the child.
Method TestChildTokensAreOrdinals()
{
    Do ..Source.AddBucketedDimension("rating", "Rating", $ListBuild(3, 7))
    Set tokens = ..Tokens("rating")
    Do $$$AssertEquals(tokens, "b0,b1,b2", "two breakpoints, three children")
}

/// Derived labels carry the range, since the token deliberately does not.
Method TestDerivedLabelsCarryRange()
{
    Do ..Source.AddBucketedDimension("rating", "Rating", $ListBuild(3, 7))
    Set labels = ..Labels("rating")
    Set want = "Rating < 3,Rating [3,7),Rating >= 7"
    Do $$$AssertEquals(labels, want, "open below, half-open, open above")
}

/// Supplied labels override the derived ones one for one, because "low",
/// "medium" and "high" are what a reader of the report understands and the store
/// has no way to know that from the numbers.
Method TestSuppliedLabelsOverride()
{
    Set given = $ListBuild("low", "medium", "high")
    Do ..Source.AddBucketedDimension("rating", "Rating", $ListBuild(3, 7), given)
    Set labels = ..Labels("rating")
    Do $$$AssertEquals(labels, "low,medium,high", "the caller's words, in order")
    Do $$$AssertEquals(..Tokens("rating"), "b0,b1,b2", "tokens unaffected")
}

/// FR-008. A row exactly on a breakpoint lands in the upper bucket. Rating holds
/// 3 and two 7s, so getting this backwards moves three of ten rows.
Method TestBoundaryIsLowerInclusive()
{
    Do ..Source.AddBucketedDimension("rating", "Rating", $ListBuild(3, 7))
    Set below = ..Count("rating:b0")
    Set middle = ..Count("rating:b1")
    Set above = ..Count("rating:b2")
    Do $$$AssertEquals(below, 2, "ratings 1 and 2 are below 3")
    Do $$$AssertEquals(middle, 2, "3 and 5 -- 3 is in, 7 is not")
    Do $$$AssertEquals(above, 4, "both 7s, plus 8 and 9")
}

/// FR-008's other half: the children of a bucketed dimension do not sum to their
/// parent, and the difference is exactly the rows the buckets cannot see. If that
/// does not reconcile, the report's figures are unaccountable.
Method TestChildrenPlusNullsSumToParent()
{
    Do ..Source.AddBucketedDimension("rating", "Rating", $ListBuild(3, 7))
    Set parent = ..Source.Peek("").n
    Set kids = ..Count("rating:b0") + ..Count("rating:b1") + ..Count("rating:b2")
    Set nulls = ..Source.NullCount("", "rating")
    Do $$$AssertEquals(nulls, 2, "two rows have no rating")
    Do $$$AssertEquals(kids + nulls, parent, "and the arithmetic closes")
}

/// A null count is scoped by the predicate it is asked about, or the engine would
/// disclose the store's gap while describing a slice.
Method TestNullCountRespectsPredicate()
{
    Do ..Source.AddBucketedDimension("rating", "Rating", $ListBuild(3, 7))
    Do ##class(RLM.Slice).Resolve(..Source, "colour:blue", .pred)
    Set nulls = ..Source.NullCount(pred, "rating")
    Do $$$AssertEquals(nulls, 1, "one of the two null ratings is blue")
}

/// A store with no bucketed dimension has no gap to disclose, and must not pay a
/// query to say so.
Method TestNullCountZeroWithoutBuckets()
{
    Set nulls = ..Source.NullCount("", "colour")
    Set any = ..Source.NullCount("")
    Do $$$AssertEquals(nulls, 0, "a categorical dimension has no null bucket")
    Do $$$AssertEquals(any, 0, "and neither does the store")
}

/// FR-009, asserted field by field rather than by inspection: the spec of a
/// bucketed dimension has the same shape as a categorical one. A policy reading
/// these two objects has nothing to branch on, which is the point.
Method TestSpecShapeMatchesCategorical()
{
    Do ..Source.AddBucketedDimension("rating", "Rating", $ListBuild(3, 7))
    Set dims = ..Source.Dimensions()
    Set cat = ..Shape(dims.%Get("colour"))
    Set buk = ..Shape(dims.%Get("rating"))
    Do $$$AssertEquals(buk, cat, "same keys and same types, top level and child")
    Do $$$AssertNotEquals(buk, "", "and the shape is not vacuously empty")
}

/// The grammar is the same grammar. A bucketed slice name resolves, nests with a
/// categorical one, and a token outside the declared range is refused -- by the
/// existing whitelist, with no bucket-specific code in RLM.Slice.
Method TestBucketedSliceResolves()
{
    Do ..Source.AddBucketedDimension("rating", "Rating", $ListBuild(3, 7))
    Set ok = ##class(RLM.Slice).Resolve(..Source, "rating:b1", , .label)
    Set nested = ##class(RLM.Slice).Resolve(..Source, "colour:red/rating:b2", .np)
    Set bad = ##class(RLM.Slice).Resolve(..Source, "rating:b9", .bp)
    Do $$$AssertStatusOK(ok, "a bucket is a slice like any other")
    Do $$$AssertEquals(label, "Rating [3,7)", "labelled by its range")
    Do $$$AssertStatusOK(nested, "and nests with a categorical dimension")
    Do $$$AssertEquals(..Source.Peek(np).n, 2, "red ratings 7 and 9")
    Do $$$AssertStatusNotOK(bad, "a token outside the range is refused")
}

/// Rows in the slice named by `path`.
Method Count(path As %String) As %Integer
{
    Do ##class(RLM.Slice).Resolve(..Source, path, .predicate)
    Quit +..Source.Peek(predicate).n
}

/// A dimension's child tokens, comma-joined in declaration order.
Method Tokens(dimension As %String) As %String
{
    Quit ..Field(dimension, "token")
}

/// A dimension's child labels, comma-joined in declaration order.
Method Labels(dimension As %String) As %String
{
    Quit ..Field(dimension, "label")
}

Method Field(
	dimension As %String,
	field As %String) As %String
{
    Set out = ""
    Set spec = ..Source.Dimensions().%Get(dimension)
    If '$IsObject(spec) || '$IsObject(spec.children) { Quit "" }
    Set kids = spec.children.%GetIterator()
    While kids.%GetNext(, .child) {
        Set out = out_$Select(out="":"", 1:",")_child.%Get(field)
    }
    Quit out
}

/// A dimension spec reduced to its structure: which keys it has, of which types,
/// including its first child's. Comparing this across two dimensions is how
/// "indistinguishable" is asserted rather than described.
ClassMethod Shape(spec As %DynamicObject) As %String
{
    If '$IsObject(spec) { Quit "" }
    Set out = ..Keys(spec)
    If $IsObject(spec.children) {
        Set kids = spec.children.%GetIterator()
        If kids.%GetNext(, .child) { Set out = out_" child{"_..Keys(child)_"}" }
    }
    Quit out
}

/// `key:type` pairs of one dynamic object, sorted, so the comparison does not
/// depend on insertion order.
ClassMethod Keys(obj As %DynamicObject) As %String
{
    Set it = obj.%GetIterator()
    While it.%GetNext(.key, .value) {
        Set sorted(key) = obj.%GetTypeOf(key)
    }
    Set out = "", key = ""
    For  {
        Set key = $Order(sorted(key), 1, type)
        Quit:key=""
        Set out = out_$Select(out="":"", 1:",")_key_":"_type
    }
    Quit out
}

}
