/// A store whose SQL names are not its ObjectScript names.
///
/// Every other Table test uses a fixture where the two happen to agree, so the
/// whole class passes while resolving names two different ways: properties are
/// validated against %Dictionary.CompiledProperty and then the same string is
/// spliced into SQL as a column. On any table created by DDL those are different
/// strings, and the defect is not subtle -- no peek can succeed at all.
///
/// Both halves are asserted here because they fail in opposite directions and a
/// fix for one can leave the other broken:
///
/// - the schema: package `User` maps to schema `SQLUser`, and `USER` is a reserved
///   word, so a spliced-from-the-class-name schema does not merely miss, it fails
///   to parse
/// - the column: `Price` the property is `unit_price` the column
///
/// Every assertion macro is on one source line: $$$macro(...) cannot span lines,
/// and %UnitTest reports a wrapped one as a silently skipped class.
Class UnitTest.RLM.SourceSqlNames Extends %UnitTest.TestCase
{

Property Source As RLM.Source.Table;

Method OnBeforeAllTests() As %Status
{
    Quit ##class(UnitTest.RLM.WidgetSql).Populate()
}

Method OnBeforeOneTest(testname As %String) As %Status
{
    Set ..Source = ##class(RLM.Source.Table).%New("UnitTest.RLM.WidgetSql", "Price")
    Quit $$$OK
}

/// The extent's real SQL name, from the dictionary rather than from string surgery
/// on the class name. SqlTableName is overridden on the fixture and the package
/// does not map to the schema, so a derived name is wrong in both halves.
Method TestSQLTableComesFromTheDictionary()
{
    Set got = ..Source.SQLTable()
    Do $$$AssertEquals(got, "UnitTest_RLM.widget_sql", "schema and table as SQL sees them")
}

/// `User` is the one package where deriving the schema does not just return the
/// wrong name -- it returns a reserved word, and the query fails to parse. Asserted
/// against %Dictionary directly so it holds for any table in USER, which is where
/// every store this library is pointed at actually lives.
Method TestUserPackageMapsToSQLUserSchema()
{
    Set src = ##class(RLM.Source.Table).%New("UnitTest.RLM.WidgetSql")
    Do $$$AssertEquals($Piece(src.SQLTable(), ".", 1), "UnitTest_RLM", "schema resolved")
    Do $$$AssertEquals($Find(src.SQLTable(), "USER."), 0, "and never the reserved word")
}

/// A dimension is declared with the property name -- that is what the validation
/// accepts -- and the SQL it produces must name the column. Before the fix this
/// peek came back {"error": ... column not found}.
Method TestPeekOnRenamedColumnsSucceeds()
{
    Do ..Source.AddDimension("colour", "Colour")
    Set peek = ..Source.Peek()
    Do $$$AssertEquals(peek.error, "", "the root peek runs at all")
    Do $$$AssertEquals(peek.n, 10, "and counts every row")
}

/// The measure is a property name too, and it reaches SQL through a different path
/// (the select list, not the WHERE clause), so it can be missed by a fix that only
/// repairs predicates.
Method TestMeasureAggregatesOnRenamedColumn()
{
    Set peek = ..Source.Peek()
    Do $$$AssertEquals(peek.min, 9, "MIN over unit_price")
    Do $$$AssertEquals(peek.max, 104, "MAX over unit_price")
}

/// A predicate's property reaches SQL as a bound-value column reference. Same
/// defect, third path.
Method TestSlicePredicateFiltersOnRenamedColumn()
{
    Do ..Source.AddDimension("colour", "Colour")
    Set predicate = ..Source.Predicate($ListBuild("colour:red"))
    Set peek = ..Source.Peek(predicate)
    Do $$$AssertEquals(peek.error, "", "the slice peek runs")
    Do $$$AssertEquals(peek.n, 6, "and names the six red rows")
}

/// Discovered children come out of a DISTINCT over the column, so a dimension whose
/// property is renamed advertises no children at all before the fix -- and an empty
/// child list is indistinguishable from a genuinely empty table.
Method TestDiscoveredChildrenUseTheColumnName()
{
    Do ..Source.AddDimension("colour", "Colour")
    Set spec = ..Source.Dimensions().%Get("colour")
    Do $$$AssertEquals(spec.children.%Size(), 2, "both values discovered")
    Set tokens = ""
    Set it = spec.children.%GetIterator()
    While it.%GetNext(, .child) { Set tokens = tokens_child.token_" " }
    Do $$$AssertNotEquals($Find(tokens, "red"), 0, "red is a child")
    Do $$$AssertNotEquals($Find(tokens, "blue"), 0, "blue is a child")
}

/// A bucketed dimension over a renamed column, and the null count that reconciles
/// its children against their parent. NullCount builds its own WHERE, so it is a
/// fourth path to the same column name.
Method TestBucketedDimensionAndNullsOnRenamedColumn()
{
    Set sc = ..Source.AddBucketedDimension("r", "Rating", $ListBuild(3, 7))
    Do $$$AssertStatusOK(sc, "declared against the property name")
    Set total = 0
    For i = 0:1:2 {
        Set peek = ..Source.Peek(..Source.Predicate($ListBuild("r:b"_i)))
        Do $$$AssertEquals(peek.error, "", "bucket "_i_" peeks")
        Set total = total + peek.n
    }
    Set nulls = ..Source.NullCount("", "r")
    Do $$$AssertEquals(nulls, 2, "the two unrated rows are counted")
    Do $$$AssertEquals(total + nulls, 10, "children plus nulls sum to the parent")
}

/// The claim in one assertion: SQL naming is a transport detail. The same
/// population declared through the plain fixture and the hostile one must produce
/// the same numbers, or something about the naming has leaked into the counts.
Method TestRenamedStoreAgreesWithPlainStore()
{
    Do ##class(UnitTest.RLM.Widget).Populate()
    Set plain = ##class(RLM.Source.Table).%New("UnitTest.RLM.Widget", "Price")
    Do plain.AddDimension("colour", "Colour")
    Do ..Source.AddDimension("colour", "Colour")

    Set a = plain.Peek(plain.Predicate($ListBuild("colour:blue")))
    Set b = ..Source.Peek(..Source.Predicate($ListBuild("colour:blue")))
    Do $$$AssertEquals(a.n, b.n, "same count either way")
    Do $$$AssertEquals(a.min, b.min, "same minimum")
    Do $$$AssertEquals(a.max, b.max, "same maximum")
}

}
