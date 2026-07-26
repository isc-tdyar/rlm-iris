/// A SQL extent split by its own columns: the plumbing shared by every source whose
/// store is a table.
///
/// What lives here is everything that turns a dimension declaration into SQL --
/// declaring dimensions against the dictionary, encoding a resolved slice as terms,
/// decoding those terms into one WHERE clause, bounded distributions, normalized
/// entropy, the row count, and the two name translations SQL needs. What does not
/// live here is `Peek`, `Describe` and `SplitMetric`, because "how mixed is this
/// slice" means something different for a message flow than for a numeric measure,
/// and a shared answer would be wrong for both.
///
/// **Why `RLM.Source.Table` is not re-parented onto this class.** It could be: the
/// declaration, predicate and query code here started as a copy of Table's. It is
/// not, because Table is shipped, carries the largest test surface in the suite, and
/// its output is asserted byte for byte by the Gaia port tests. Re-parenting it to
/// recover eighty lines would put every one of those assertions at risk for no
/// behaviour change. The duplication is real and it is the price; it is written down
/// here so the next reader knows it was chosen rather than missed. If Table ever
/// needs changing for another reason, that is the moment to merge the two.
///
/// Dimensions are declared with *property* names and every query is written with
/// *column* names, and the two are only the same string by coincidence -- on a class
/// created by DDL `reject_fraction` the column is `rejectfraction` the property.
/// `SQLTable()` and `Column()` are the two translations, and both read the
/// dictionary rather than deriving a name.
///
/// Nothing a model says reaches a query as text. Tokens are carried as a delimited
/// term list and bound as parameters; the operators are literals this class writes.
Class RLM.Source.Extent Extends RLM.Source [ Abstract ]
{

/// Class whose extent is being decomposed.
Property ClassName As %String;

/// Stop counting at this many rows. 0 means no cap.
Property MaxRows As %Integer [ InitialExpression = 0 ];

/// How many groups a distribution names before the rest becomes one remainder
/// bucket. Bounded so a slice with ten thousand distinct groups costs the same peek
/// as one with three -- which is the property that makes a peek's size independent
/// of the slice's size.
Property TopN As %Integer [ InitialExpression = 5 ];

/// dimension name -> property name.
Property Dims As array Of %String;

/// Declaration order, so the menu stays stable between runs. An unstable menu makes
/// two traces incomparable.
Property DimOrder As %List;

/// dimension name -> breakpoints, ascending, for the bucketed dimensions only.
Property Buckets As array Of %List;

/// dimension name -> child labels supplied by the caller, one per child.
Property BucketLabels As array Of %List;

/// dimension name -> SQL expression to split on, when the dimension is over a
/// derived value rather than a stored column.
///
/// An hour-of-day dimension has no column: it is a function of a timestamp. Keeping
/// the expression here rather than in the property map means everything that
/// resolves a term works the same way for a derived dimension as for a stored one,
/// and only one method has to know the difference.
Property Derived As array Of %String;

Method %OnNew(className As %String) As %Status
{
    Set ..ClassName = className
    Set ..Name = className
    Quit $$$OK
}

/// Declare a dimension over a property.
///
/// Refused if the property does not exist: a bad dimension would otherwise produce
/// broken SQL on every peek that used it, and the run would look like a store
/// problem rather than a configuration one.
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

/// Declare a dimension over an SQL expression rather than a stored column, with its
/// children declared.
///
/// `children` is a %List of `token|label` pairs and `expression` is SQL this class's
/// author wrote. No part of either comes from a model: the children are a fixed
/// menu, and a term over this dimension binds the token as a parameter against the
/// expression.
Method AddDerivedDimension(
	dimension As %String,
	expression As %String,
	children As %List) As %Status
{
    If $ListLength(children) < 2 {
        // One child covering everything is a slice identical to its parent, which is
        // excluded wherever it arises.
        Set msg = "'"_dimension_"' needs at least two children to divide anything"
        Quit $$$ERROR($$$GeneralError, msg)
    }
    Do ..Derived.SetAt(expression, dimension)
    Do ..BucketLabels.SetAt(children, dimension)
    If '$ListFind(..DimOrder, dimension) {
        Set ..DimOrder = ..DimOrder_$ListBuild(dimension)
    }
    Quit $$$OK
}

/// Declare a dimension over the ranges of a numeric property.
///
/// `n` breakpoints yield `n+1` children: the first covers everything below
/// `breakpoints(1)`, the last everything from `breakpoints(n)` up, and child `i`
/// covers `[breakpoints(i), breakpoints(i+1))` -- half-open and lower-inclusive, so
/// a row sitting exactly on an edge lands in exactly one bucket.
///
/// Tokens are ordinals (`b0` … `bn`) rather than range strings, so rewording a label
/// does not invalidate a trace that named the child.
Method AddBucketedDimension(
	dimension As %String,
	property As %String,
	breakpoints As %List,
	labels As %List = "") As %Status
{
    If '##class(%Dictionary.CompiledProperty).%ExistsId(..ClassName_"||"_property) {
        Set msg = "'"_property_"' is not a property of "_..ClassName
        Quit $$$ERROR($$$GeneralError, msg)
    }
    Set n = $ListLength(breakpoints)
    If n = 0 {
        Set msg = "'"_dimension_"' needs at least one breakpoint to divide anything"
        Quit $$$ERROR($$$GeneralError, msg)
    }
    // `seen` counts rather than testing `prev` for emptiness: a first breakpoint of 0
    // compares equal to "" numerically, and the check would then skip the row after
    // it.
    Set bad = 0, seen = 0, prev = "", ptr = 0
    While $ListNext(breakpoints, ptr, edge) {
        // Strictly ascending numbers. Equal edges describe an empty range;
        // descending ones describe overlapping ranges, and a row landing in two
        // buckets makes the children over-count their parent.
        If (edge '= +edge) || (seen && (edge '> prev)) { Set bad = 1 Quit }
        Set prev = edge, seen = seen + 1
    }
    If bad {
        Set msg = "'"_dimension_"' breakpoints must be numbers in strictly ascending order"
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

/// `path` is accepted and ignored. A table's columns exist in every slice and its
/// distinct values are discovered from the whole extent, so the answer does not
/// depend on where the caller is standing.
Method Dimensions(path As %String = "") As %DynamicObject
{
    Set out = {}
    Set ptr = 0
    While $ListNext(..DimOrder, ptr, dim) {
        Set spec = {"label": (..Label(dim)), "children": []}
        // A derived dimension's children are a fixed menu, emitted without touching
        // the extent -- and in the same shape a discovered child has, because a
        // policy must not be able to tell the two kinds apart.
        If ..Derived.IsDefined(dim) {
            Set given = ..BucketLabels.GetAt(dim), p = 0
            While $ListNext(given, p, pair) {
                Set token = $Piece(pair, "|", 1), label = $Piece(pair, "|", 2)
                Do spec.children.%Push({"token": (token), "label": (label)})
            }
            Do out.%Set(dim, spec)
            Continue
        }
        If ..Buckets.IsDefined(dim) {
            Set edges = ..Buckets.GetAt(dim)
            Set given = ..BucketLabels.GetAt(dim)
            Set property = ..Dims.GetAt(dim)
            For i = 0:1:$ListLength(edges) {
                Set label = $Select(given'="":$ListGet(given, i + 1),
                    1:..BucketLabel(property, edges, i))
                Do spec.children.%Push({"token": ("b"_i), "label": (label)})
            }
            Do out.%Set(dim, spec)
            Continue
        }
        // %EXACT, because DISTINCT on a %String returns the collated value --
        // SQLUPPER by default. Advertising "RED" for a row holding "red" makes the
        // model name a slice the grammar then correctly refuses, and the run looks
        // like a model failure rather than a discovery bug.
        Set col = ..Column(..Dims.GetAt(dim))
        Set rs = ..Query("SELECT DISTINCT %EXACT("_col_") AS v FROM "_..SQLTable()
            _" WHERE "_col_" IS NOT NULL ORDER BY %EXACT("_col_")", .sc)
        If $$$ISERR(sc) { Do out.%Set(dim, spec) Continue }
        While rs.%Next() {
            Set v = rs.%Get("v")
            Do spec.children.%Push({"token": (v), "label": (..ChildLabel(dim, v))})
        }
        Do out.%Set(dim, spec)
    }
    Quit out
}

/// A dimension's own label. Overridable so a source can name a dimension in domain
/// terms rather than after the column it happens to sit on.
Method Label(dimension As %String) As %String
{
    If ..Derived.IsDefined(dimension) { Quit dimension }
    Quit ..Dims.GetAt(dimension)
}

/// A discovered child's label. Overridable so an enumerated code can be shown with
/// its meaning: a `Status` of 2 tells a reader nothing, and dropping the codes it
/// does not recognize would hide rows.
Method ChildLabel(
	dimension As %String,
	value As %String) As %String
{
    Quit value
}

/// Encode a resolved slice as a term list. Called only by RLM.Slice, with components
/// it has already checked against Dimensions().
///
/// Each term is `expression<C2>operator<C2>value`; a categorical component
/// contributes one term with `=`, a bucket one or two with `>=` and `<`, and a
/// derived dimension one against its expression. The operator comes from this method
/// and never from anything a model said.
Method Predicate(components As %List) As %String
{
    Set out = "", ptr = 0
    While $ListNext(components, ptr, comp) {
        Set dim = $Piece(comp, ":", 1), token = $Piece(comp, ":", 2)
        If ..Derived.IsDefined(dim) {
            Set out = out_..Term(out, ..Derived.GetAt(dim), "=", token)
            Continue
        }
        // The column, not the property: a term is decoded straight into a WHERE
        // clause by Where(), so translating here is what keeps that method a pure
        // decoder with nothing to look up.
        Set property = ..Column(..Dims.GetAt(dim))
        If '..Buckets.IsDefined(dim) {
            Set out = out_..Term(out, property, "=", token)
            Continue
        }
        // Token `bi` is the i'th bucket: bounded below by edge i and above by edge
        // i+1, with the first and last bucket each missing one side. RLM.Slice has
        // already refused an ordinal outside the range; the guard is here so a term
        // list is never assembled from one this dimension does not have.
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
	expression As %String,
	op As %String,
	value As %String) As %String
{
    Quit $Select(sofar="":"", 1:$Char(1))_expression_$Char(2)_op_$Char(2)_value
}

/// Decode a term list into a WHERE clause and its bound values.
///
/// Shared by every query in every subclass rather than open-coded per peek: two
/// decoders would eventually disagree about which rows a predicate names, and the
/// null count exists precisely to reconcile against the counts a peek returns.
Method Where(
	predicate As %String,
	Output args As %List) As %String [ Private ]
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

/// Rows in the slice, and whether the cap stopped the count.
///
/// A cap has to bound the rows counted, not the one aggregate row that comes back --
/// applied to the wrong thing it does nothing at all, which is a cap that reports
/// itself and does not exist.
Method Count(
	predicate As %String = "",
	Output capped As %Boolean) As %Integer [ Private ]
{
    Set capped = 0
    Set where = ..Where(predicate, .args)
    If ..MaxRows {
        Set sql = "SELECT COUNT(*) AS n FROM (SELECT TOP "_..MaxRows_" %ID FROM "
            _..SQLTable()_where_")"
    } Else {
        Set sql = "SELECT COUNT(*) AS n FROM "_..SQLTable()_where
    }
    Set rs = ..Query(sql, .sc, args)
    If $$$ISERR(sc) { Quit -1 }
    If 'rs.%Next() { Quit -1 }
    Set n = +rs.%Get("n")
    If ..MaxRows, n >= ..MaxRows { Set capped = 1 }
    Quit n
}

/// The `topK` largest groups of `columns` within the slice, largest first, plus the
/// slice's whole total.
///
/// Bounded by construction: a slice with ten thousand distinct groups returns the
/// same `topK` entries as one with three, so the peek's serialized size does not
/// follow the store's size. `total` counts every row in the slice, not just the
/// covered ones, because the entropy's remainder bucket is computed from the
/// difference -- and a total that counted only what it named would report every
/// truncated distribution as perfectly even.
///
/// Each entry is `{"key": ..., "n": ...}`, with a multi-column key joined by a space.
Method Distribution(
	predicate As %String,
	columns As %List,
	topK As %Integer,
	Output total As %Integer) As %DynamicArray [ Private ]
{
    Set out = [], total = 0
    Set where = ..Where(predicate, .args)
    // %EXACT everywhere, and aliased rather than read back by column name: the same
    // reason Dimensions uses it. A GROUP BY on a %String groups by the collated
    // value, so the key would come back "NORTH" for the child Dimensions advertised
    // as "north" -- a peek keyed differently from the menu it describes, which no
    // caller can join up and which would make an honest reconciliation impossible.
    Set cols = "", ptr = 0
    While $ListNext(columns, ptr, c) {
        Set cols = cols_$Select(cols="":"", 1:", ")_"%EXACT("_c_")"
    }
    If cols = "" { Quit out }
    Set select = "", i = 0, ptr = 0
    While $ListNext(columns, ptr, c) {
        Set i = i + 1
        Set select = select_"%EXACT("_c_") AS k"_i_", "
    }
    Set sql = "SELECT TOP "_(+topK)_" "_select_"COUNT(*) AS n FROM "_..SQLTable()
        _where_" GROUP BY "_cols_" ORDER BY COUNT(*) DESC, "_cols
    Set rs = ..Query(sql, .sc, args)
    If $$$ISERR(sc) { Quit out }
    Set n = $ListLength(columns)
    While rs.%Next() {
        Set key = ""
        For p = 1:1:n { Set key = key_$Select(p=1:"", 1:" ")_rs.%Get("k"_p) }
        Do out.%Push({"key": (key), "n": (+rs.%Get("n"))})
    }
    Set total = ..Count(predicate, .capped)
    If total < 0 { Set total = 0 }
    Quit out
}

/// Normalized 0-1 entropy of a group-size list, with everything past the named
/// groups counted as one remainder bucket.
///
/// 1 when the groups are the same size, 0 when one holds everything or there is only
/// one of them. `sizes` is a %List of counts and `total` the whole population; the
/// difference becomes the remainder. Truncating a distribution understates evenness
/// rather than overstating it, which is the safe direction: it cannot make a useless
/// split look good.
ClassMethod Entropy(
	sizes As %List,
	total As %Integer) As %Numeric
{
    If total <= 0 { Quit 0 }
    Set h = 0, seen = 0, buckets = 0, ptr = 0
    While $ListNext(sizes, ptr, n) {
        Continue:+n'>0
        Set p = n / total
        If p > 0, p < 1 { Set h = h - (p * ..Log2(p)) }
        Set seen = seen + n, buckets = buckets + 1
    }
    Set rest = total - seen
    If rest > 0 {
        Set p = rest / total
        If p < 1 { Set h = h - (p * ..Log2(p)) }
        Set buckets = buckets + 1
    }
    If buckets < 2 { Quit 0 }
    Set norm = h / ..Log2(buckets)
    If norm < 0 { Set norm = 0 }
    If norm > 1 { Set norm = 1 }
    // Rounded, because a metric is compared for equality and printed in reports, and
    // an unrounded binary fraction differs between the two. `+` because $FNumber
    // returns a formatted string: "1.000" is not equal to 1, so an even split would
    // fail the very assertion the rounding exists to make possible.
    Quit +$FNumber(norm, "", 3)
}

ClassMethod Log2(v As %Numeric) As %Numeric [ Private ]
{
    Quit $ZLN(v) / $ZLN(2)
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

/// Rows inside `predicate` that `dimension` covers with no child, so that its
/// children do not sum to their parent.
///
/// A categorical dimension's children are enumerated from the data, so a row with a
/// value is always in one of them -- but a null-valued row is in none, and that is a
/// gap a report has to disclose. Same for a bucketed or derived dimension whose
/// underlying value is null.
Method NullCount(
	predicate As %String = "",
	dimension As %String = "") As %Integer
{
    If dimension = "" { Quit 0 }
    If ..Derived.IsDefined(dimension) {
        Set expr = ..Derived.GetAt(dimension)
    } ElseIf ..Dims.IsDefined(dimension) {
        Set expr = ..Column(..Dims.GetAt(dimension))
    } Else {
        Quit 0
    }
    Set where = ..Where(predicate, .args)
    Set where = where_$Select(where="":" WHERE ", 1:" AND ")_expr_" IS NULL"
    Set rs = ..Query("SELECT COUNT(*) AS n FROM "_..SQLTable()_where, .sc, args)
    If $$$ISERR(sc) { Quit 0 }
    If 'rs.%Next() { Quit 0 }
    Quit +rs.%Get("n")
}

/// SQL name of the extent, from the dictionary.
///
/// Not derived from the class name. Package-to-schema is not a string
/// transformation: `User` maps to schema `SQLUser`, and a derived `USER` is a
/// reserved word, so a derived name does not merely name the wrong table -- it fails
/// to parse, and every peek on any store in USER comes back as an error.
///
/// The derivation is the fallback for a class that is not compiled, where there is
/// no dictionary entry to read and the caller is about to get an error from SQL
/// either way: a guess names the table the caller probably meant, which makes the
/// error message the useful one.
Method SQLTable() As %String [ Private ]
{
    Set c = ##class(%Dictionary.CompiledClass).%OpenId(..ClassName, , .sc)
    If $IsObject($Get(c)), c.SqlSchemaName '= "", c.SqlTableName '= "" {
        Quit c.SqlSchemaName_"."_c.SqlTableName
    }
    Set schema = $Piece(..ClassName, ".", 1, $Length(..ClassName, ".") - 1)
    Quit $Translate(schema, ".", "_")_"."
        _$Piece(..ClassName, ".", $Length(..ClassName, "."))
}

/// SQL column name of a property, from the dictionary.
///
/// The one place a property name becomes a column name. Every query goes through it,
/// because a single path that skipped it would be a query that disagreed with the
/// others about which column a dimension names -- the same failure the shared
/// `Where` prevents one level up.
Method Column(property As %String) As %String [ Private ]
{
    If property = "" { Quit "" }
    Set p = ##class(%Dictionary.CompiledProperty).%OpenId(..ClassName_"||"_property, , .sc)
    If $IsObject($Get(p)), p.SqlFieldName '= "" { Quit p.SqlFieldName }
    Quit property
}

/// Run a query, returning a result set. Errors come back as a status rather than an
/// exception so a failed peek costs the run one call, not the report.
///
/// `args` is a %List of parameter values; %Execute needs them as a
/// count-subscripted array, so the conversion happens here rather than at every call
/// site.
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
