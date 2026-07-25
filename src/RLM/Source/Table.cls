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

Method Dimensions() As %DynamicObject
{
    Set out = {}
    Set ptr = 0
    While $ListNext(..DimOrder, ptr, dim) {
        Set property = ..Dims.GetAt(dim)
        Set spec = {"label": (property), "children": []}
        // %EXACT, because DISTINCT on a %String returns the collated value --
        // SQLUPPER by default. Advertising "RED" for a row holding "red" makes
        // the model name a slice the grammar then correctly refuses, and the
        // resulting run looks like a model failure rather than a discovery bug.
        Set rs = ..Query("SELECT DISTINCT %EXACT("_property_") AS v FROM "_..SQLTable()
            _" WHERE "_property_" IS NOT NULL ORDER BY %EXACT("_property_")", .sc)
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
Method Predicate(components As %List) As %String
{
    Set out = "", ptr = 0
    While $ListNext(components, ptr, comp) {
        Set dim = $Piece(comp, ":", 1), token = $Piece(comp, ":", 2)
        Set out = out_$Select(out="":"", 1:$Char(1))_..Dims.GetAt(dim)_$Char(2)_token
    }
    Quit out
}

Method Peek(predicate As %String = "") As %DynamicObject
{
    Set where = "", args = ""
    Set ptr = 0
    While $ListNext($ListFromString(predicate, $Char(1)), ptr, term) {
        Continue:term=""
        Set where = where_$Select(where="":" WHERE ", 1:" AND ")_$Piece(term, $Char(2), 1)_" = ?"
        Set args = args_$ListBuild($Piece(term, $Char(2), 2))
    }

    Set sel = "COUNT(*) AS n"
    If ..Measure '= "" {
        Set sel = sel_", MIN("_..Measure_") AS lo, MAX("_..Measure_") AS hi"
            _", AVG("_..Measure_") AS mean"
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

/// SQL name of the extent.
Method SQLTable() As %String
{
    Set schema = $Piece(..ClassName, ".", 1, $Length(..ClassName, ".") - 1)
    Quit $Translate(schema, ".", "_")_"."_$Piece(..ClassName, ".", $Length(..ClassName, "."))
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
