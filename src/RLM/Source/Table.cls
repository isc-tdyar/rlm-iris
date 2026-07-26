/// A SQL table or view as a decomposition source.
///
/// Every peek is a GROUP BY executed by IRIS over rows that are never copied
/// anywhere. That is the difference between this and loading a table into a
/// Python REPL: there is no extract step, the aggregate can be answered from an
/// index, and a slice is an authorizable query rather than an opaque variable in
/// someone's process.
///
/// Dimension children are discovered from the data rather than declared. A
/// hand-maintained token list drifts from the table on the first insert, and the
/// failure is silent in the worst direction: the model is refused for naming a
/// slice that does exist.
///
/// The SQL is assembled from class metadata only. Dimension properties are
/// checked against the compiled class when declared, and tokens are bound as
/// parameters, so nothing a model says reaches the query as text.
///
/// Dimensions are declared with *property* names and every query is written with
/// *column* names, and the two are only the same string by coincidence. On a class
/// created by DDL they are routinely different -- `reject_fraction` the column is
/// `rejectfraction` the property -- so a source that used one name for both could
/// not be declared and queried at the same time: the property name fails in SQL
/// and the column name fails validation. SQLTable() and Column() are the two
/// translations, and both read the dictionary rather than deriving a name.
Class RLM.Source.Table Extends RLM.Source
{

/// Class whose extent is being decomposed.
Property ClassName As %String;

/// Numeric property the split metric is computed over. Optional: without one the
/// metric falls back to how unevenly rows are distributed.
Property Measure As %String;

/// Stop counting at this many rows. 0 means no cap.
Property MaxRows As %Integer [ InitialExpression = 0 ];

/// dimension name -> property name.
Property Dims As array Of %String;

/// Declaration order, so the menu and the discovered children stay stable
/// between runs. An unstable menu makes two traces incomparable.
Property DimOrder As %List;

/// dimension name -> breakpoints, ascending, for the bucketed dimensions only.
/// A dimension appears here or in neither place; Dims holds the property for both
/// kinds, so everything that resolves a term works the same way for each.
Property Buckets As array Of %List;

/// dimension name -> child labels supplied by the caller, one per child. Absent
/// when the labels are derived from the edges.
Property BucketLabels As array Of %List;

Method %OnNew(
	className As %String,
	measure As %String = "") As %Status
{
    Set ..ClassName = className
    Set ..Measure = measure
    Set ..Name = className_$Select(measure="":"", 1:" by "_measure)
    Quit $$$OK
}

/// Declare a dimension over a property.
///
/// Refused if the property does not exist: a bad dimension would otherwise
/// produce broken SQL on every peek that used it, and the run would look like a
/// store problem rather than a configuration one.
Method AddDimension(
	dimension As %String,
	property As %String) As %Status
{
    If '##class(%Dictionary.CompiledProperty).%ExistsId(..ClassName_"||"_property) {
        Set msg = "'"_property_"' is not a property of "_..ClassName
        Quit $$$ERROR($$$GeneralError, msg)
    }
    Do ..Dims.SetAt(property, dimension)
    If '$ListFind(..DimOrder, dimension) {
        Set ..DimOrder = ..DimOrder_$ListBuild(dimension)
    }
    Quit $$$OK
}

/// Declare a dimension over the ranges of a numeric property.
///
/// `n` breakpoints yield `n+1` children: the first covers everything below
/// `breakpoints(1)`, the last everything from `breakpoints(n)` up, and child `i`
/// covers `[breakpoints(i), breakpoints(i+1))` -- half-open and lower-inclusive,
/// so a row sitting exactly on an edge lands in the upper bucket and lands in
/// exactly one.
///
/// Tokens are ordinals (`b0` … `bn`) rather than range strings, so rewording a
/// label does not invalidate a trace that named the child. The range lives in the
/// label, which is what the model is shown.
///
/// Everything is validated here rather than at peek time, for the same reason
/// AddDimension checks its property: a bad declaration discovered mid-run makes a
/// configuration error look like a store failure.
Method AddBucketedDimension(
	dimension As %String,
	property As %String,
	breakpoints As %List,
	labels As %List = "") As %Status
{
    If '##class(%Dictionary.CompiledProperty).%ExistsId(..ClassName_"||"_property) {
        Quit $$$ERROR($$$GeneralError, "'"_property_"' is not a property of "_..ClassName)
    }
    Set n = $ListLength(breakpoints)
    If n = 0 {
        // One child covering everything is a slice identical to its parent, which
        // FR-011 excludes wherever it arises.
        Set msg = "'"_dimension_"' needs at least one breakpoint to divide anything"
        Quit $$$ERROR($$$GeneralError, msg)
    }
    // `seen` counts rather than testing `prev` for emptiness: a first breakpoint of
    // 0 compares equal to "" numerically, and the check would then skip the row
    // after it.
    Set bad = 0, seen = 0, prev = "", ptr = 0
    While $ListNext(breakpoints, ptr, edge) {
        // Strictly ascending numbers. Equal edges describe an empty range;
        // descending ones describe overlapping ranges, and a row landing in two
        // buckets makes the children over-count their parent.
        If (edge '= +edge) || (seen && (edge '> prev)) { Set bad = 1 Quit }
        Set prev = edge, seen = seen + 1
    }
    If bad {
        Set msg = "'"_dimension
            _"' breakpoints must be numbers in strictly ascending order"
        Quit $$$ERROR($$$GeneralError, msg)
    }
    If (labels '= "") && ($ListLength(labels) '= (n + 1)) {
        Set msg = "'"_dimension_"' has "_(n + 1)_" children but "
            _$ListLength(labels)_" label(s) were supplied"
        Quit $$$ERROR($$$GeneralError, msg)
    }

    Do ..Dims.SetAt(property, dimension)
    Do ..Buckets.SetAt(breakpoints, dimension)
    If labels '= "" { Do ..BucketLabels.SetAt(labels, dimension) }
    If '$ListFind(..DimOrder, dimension) {
        Set ..DimOrder = ..DimOrder_$ListBuild(dimension)
    }
    Quit $$$OK
}

/// `path` is accepted and ignored. A table's columns exist in every slice and
/// its distinct values are discovered from the whole table, so the answer here
/// does not depend on where the caller is standing.
Method Dimensions(path As %String = "") As %DynamicObject
{
    Set out = {}
    Set ptr = 0
    While $ListNext(..DimOrder, ptr, dim) {
        Set property = ..Dims.GetAt(dim)
        Set spec = {"label": (property), "children": []}
        // A bucketed dimension's children are declared, so they are emitted
        // without touching the table -- and in the same shape a discovered child
        // has, because FR-009 is the requirement that a policy cannot tell the two
        // kinds apart.
        If ..Buckets.IsDefined(dim) {
            Set edges = ..Buckets.GetAt(dim)
            Set given = ..BucketLabels.GetAt(dim)
            For i = 0:1:$ListLength(edges) {
                Set label = $Select(given'="":$ListGet(given, i + 1),
                    1:..BucketLabel(property, edges, i))
                Do spec.children.%Push({"token": ("b"_i), "label": (label)})
            }
            Do out.%Set(dim, spec)
            Continue
        }
        // %EXACT, because DISTINCT on a %String returns the collated value --
        // SQLUPPER by default. Advertising "RED" for a row holding "red" makes
        // the model name a slice the grammar then correctly refuses, and the
        // resulting run looks like a model failure rather than a discovery bug.
        Set col = ..Column(property)
        Set rs = ..Query("SELECT DISTINCT %EXACT("_col_") AS v FROM "_..SQLTable()
            _" WHERE "_col_" IS NOT NULL ORDER BY %EXACT("_col_")", .sc)
        If $$$ISERR(sc) { Do out.%Set(dim, spec) Continue }
        While rs.%Next() {
            Do spec.children.%Push({"token": (rs.%Get("v")), "label": (rs.%Get("v"))})
        }
        Do out.%Set(dim, spec)
    }
    Quit out
}

/// Build the WHERE clause. Called only by RLM.Slice with components it has
/// already checked against Dimensions(), and tokens are carried as a delimited
/// value list rather than spliced into text -- Peek binds them as parameters.
/// The term encoding, widened. Each term is `property<C2>operator<C2>value`; a
/// categorical component contributes one term with `=`, and a bucket contributes
/// one or two with `>=` and `<`. The operator comes from this method and never
/// from anything a model said, so the widening adds no authoring surface: it adds
/// two more literals this class may write.
Method Predicate(components As %List) As %String
{
    Set out = "", ptr = 0
    While $ListNext(components, ptr, comp) {
        Set dim = $Piece(comp, ":", 1), token = $Piece(comp, ":", 2)
        // The column, not the property: a term is decoded straight into a WHERE
        // clause by Where(), so translating here is what keeps that method a pure
        // decoder with nothing to look up.
        Set property = ..Column(..Dims.GetAt(dim))
        If '..Buckets.IsDefined(dim) {
            Set out = out_..Term(out, property, "=", token)
            Continue
        }
        // Token `bi` is the i'th bucket: bounded below by edge i and above by edge
        // i+1, with the first and last bucket each missing one side. Both bounds
        // are dropped for a token outside the range, but RLM.Slice has already
        // refused those -- the guard is here so a term list is never assembled
        // from an ordinal this dimension does not have.
        Set edges = ..Buckets.GetAt(dim)
        Set i = +$Extract(token, 2, *)
        If ($Extract(token) '= "b") || (i < 0) || (i > $ListLength(edges)) { Continue }
        If i > 0 { Set out = out_..Term(out, property, ">=", $ListGet(edges, i)) }
        If i < $ListLength(edges) {
            Set out = out_..Term(out, property, "<", $ListGet(edges, i + 1))
        }
    }
    Quit out
}

/// One encoded term, with its leading separator when it is not the first.
ClassMethod Term(
	sofar As %String,
	property As %String,
	op As %String,
	value As %String) As %String
{
    Quit $Select(sofar="":"", 1:$Char(1))_property_$Char(2)_op_$Char(2)_value
}

Method Peek(predicate As %String = "") As %DynamicObject
{
    Set where = ..Where(predicate, .args)

    Set sel = "COUNT(*) AS n"
    If ..Measure '= "" {
        // The measure reaches SQL through the select list rather than the WHERE
        // clause, so it needs the same translation by a separate path.
        Set m = ..Column(..Measure)
        Set sel = sel_", MIN("_m_") AS lo, MAX("_m_") AS hi"
            _", AVG("_m_") AS mean"
    }
    Set sql = "SELECT "_sel_" FROM "_..SQLTable()_where
    If ..MaxRows {
        // Counting a capped subset requires the cap to apply to the rows, not to
        // the one aggregate row that comes back.
        Set sql = "SELECT COUNT(*) AS n FROM (SELECT TOP "_..MaxRows_" %ID FROM "
            _..SQLTable()_where_")"
    }

    Set rs = ..Query(sql, .sc, args)
    If $$$ISERR(sc) { Quit {"error": ($System.Status.GetErrorText(sc))} }
    If 'rs.%Next() { Quit {"error": "aggregate returned no row"} }

    Set peek = {"n": (rs.%Get("n")), "capped": 0}
    If ..MaxRows && (peek.n >= ..MaxRows) { Set peek.capped = 1 }
    If (..Measure '= "") && '..MaxRows {
        Set peek.min = rs.%Get("lo")
        Set peek.max = rs.%Get("hi")
        Set peek.mean = rs.%Get("mean")
    }
    Quit peek
}

/// Decode a term list into a WHERE clause and its bound values.
///
/// Shared by Peek and NullCount rather than open-coded in each: the two would then
/// be able to disagree about which rows a predicate names, and the null count
/// exists precisely to reconcile against the counts Peek returns.
Method Where(
	predicate As %String,
	Output args As %List) As %String
{
    Set where = "", args = "", ptr = 0
    While $ListNext($ListFromString(predicate, $Char(1)), ptr, term) {
        Continue:term=""
        Set where = where_$Select(where="":" WHERE ", 1:" AND ")
            _$Piece(term, $Char(2), 1)_" "_$Piece(term, $Char(2), 2)_" ?"
        Set args = args_$ListBuild($Piece(term, $Char(2), 3))
    }
    Quit where
}

/// The derived label of bucket `i`, carrying the range the token does not.
ClassMethod BucketLabel(
	property As %String,
	edges As %List,
	i As %Integer) As %String
{
    Set n = $ListLength(edges)
    If i = 0 { Quit property_" < "_$ListGet(edges, 1) }
    If i = n { Quit property_" >= "_$ListGet(edges, n) }
    Quit property_" ["_$ListGet(edges, i)_","_$ListGet(edges, i + 1)_")"
}

/// Rows inside `predicate` whose bucketed property is null, and which therefore
/// appear in none of `dimension`'s children.
///
/// Only a bucketed dimension can have any: a categorical dimension's children are
/// enumerated from the data, so every value it found is a child. Returning 0
/// without querying for the other cases keeps the disclosure free where there is
/// nothing to disclose.
Method NullCount(
	predicate As %String = "",
	dimension As %String = "") As %Integer
{
    If dimension = "" { Quit 0 }
    If '..Buckets.IsDefined(dimension) { Quit 0 }
    Set property = ..Column(..Dims.GetAt(dimension))
    Set where = ..Where(predicate, .args)
    Set where = where_$Select(where="":" WHERE ", 1:" AND ")_property_" IS NULL"
    Set rs = ..Query("SELECT COUNT(*) AS n FROM "_..SQLTable()_where, .sc, args)
    If $$$ISERR(sc) { Quit 0 }
    If 'rs.%Next() { Quit 0 }
    Quit +rs.%Get("n")
}

Method Describe(
	label As %String,
	peek As %DynamicObject) As %String
{
    If peek.error '= "" { Quit label_": unavailable ("_peek.error_")" }
    // A capped count is worded as a floor. "n=50000" and "n=at least 50000" lead
    // a reader to different conclusions, and only one of them is true.
    Set out = label_": n="_$Select(peek.capped:"at least "_peek.n, 1:peek.n)
    If peek.min '= "" {
        Set out = out_", "_..Measure_" min="_peek.min_" max="_peek.max
            _" mean="_$FNumber(peek.mean, "", 2)
    }
    Quit out
}

/// Relative spread of the measure within the slice, clamped to 0-1.
///
/// A slice whose measure is tightly grouped is one population; a wide spread
/// means the slice still mixes several. Without a measure, fall back to size
/// relative to the whole store, which at least prefers splitting the big slice.
Method SplitMetric(peek As %DynamicObject) As %Numeric
{
    If peek.error '= "" { Quit 0 }
    If (peek.min = "") || (peek.mean = "") || (+peek.mean = 0) { Quit 0 }
    Set spread = (peek.max - peek.min) / $ZAbs(peek.mean)
    Quit $Select(spread > 1:1, 1:spread)
}

/// SQL name of the extent, from the dictionary.
///
/// Not derived from the class name. Package-to-schema is not a string
/// transformation: `User` maps to schema `SQLUser`, and a derived `USER` is a
/// reserved word, so the query does not merely name the wrong table -- it fails to
/// parse, and every peek on any store in USER comes back as an error. SqlTableName
/// can be overridden independently of the class name as well.
///
/// The derivation is kept as the fallback for a class that is not compiled, where
/// there is no dictionary entry to read and the caller is about to get an error
/// from SQL either way: a guess names the table the caller probably meant, which
/// makes the error message the useful one.
Method SQLTable() As %String
{
    Set c = ##class(%Dictionary.CompiledClass).%OpenId(..ClassName, , .sc)
    If $IsObject($Get(c)), c.SqlSchemaName '= "", c.SqlTableName '= "" {
        Quit c.SqlSchemaName_"."_c.SqlTableName
    }
    Set schema = $Piece(..ClassName, ".", 1, $Length(..ClassName, ".") - 1)
    Quit $Translate(schema, ".", "_")_"."_$Piece(..ClassName, ".", $Length(..ClassName, "."))
}

/// SQL column name of a property, from the dictionary.
///
/// The one place a property name becomes a column name. Every query in this class
/// goes through it, because a single path that skipped it would be a query that
/// disagreed with the others about which column a dimension names -- which is the
/// same failure the shared Where() exists to prevent one level up.
///
/// Falls back to the property name for anything not in the dictionary (a computed
/// alias, an uncompiled class), which is what this class did everywhere before the
/// translation existed.
Method Column(property As %String) As %String
{
    If property = "" { Quit "" }
    Set p = ##class(%Dictionary.CompiledProperty).%OpenId(..ClassName_"||"_property, , .sc)
    If $IsObject($Get(p)), p.SqlFieldName '= "" { Quit p.SqlFieldName }
    Quit property
}

/// Run a query, returning a result set. Errors come back as a status rather than
/// an exception so a failed peek costs the run one call, not the report.
///
/// `args` is a %List of parameter values; %Execute needs them as a
/// count-subscripted array, so the conversion happens here rather than at every
/// call site.
ClassMethod Query(
	sql As %String,
	Output sc As %Status,
	args As %List = "") As %SQL.StatementResult
{
    Set sc = $$$OK
    Set p = 0, ptr = 0
    While $ListNext(args, ptr, v) {
        Set p = p + 1, param(p) = v
    }
    Set param = p
    Try {
        Set stmt = ##class(%SQL.Statement).%New()
        Set sc = stmt.%Prepare(sql)
        If $$$ISERR(sc) { Quit }
        Set rs = stmt.%Execute(param...)
        If rs.%SQLCODE < 0 {
            Set sc = $$$ERROR($$$GeneralError, "SQLCODE "_rs.%SQLCODE_": "_rs.%Message)
        }
    } Catch e {
        Set sc = e.AsStatus()
    }
    Quit $Get(rs)
}

}
