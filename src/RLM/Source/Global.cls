/// An IRIS global as a decomposition source.
///
/// This is the case the whole package exists for. A table has a schema you can
/// read; a global that has been written to since 2009 by a routine nobody owns
/// has none. The structure lives in the code that writes it, and that code is
/// usually the thing being retired. There is nothing to export -- 40 GB does not
/// fit in a context window -- and a sample is not a summary: the first 50,000
/// nodes tell you about the year the global was created and nothing about the
/// decade the archiving decision turns on.
///
/// So the model never sees a node. It receives counts, depth, fanout, node kind,
/// value-length moments and a subscript type mix, all from a bounded walk, and
/// picks a subscript from a list this class handed it. That description costs
/// roughly the same to produce whether the subtree holds 40 nodes or 400
/// million, because it is aggregates over a capped walk rather than a read.
///
/// Two properties are load-bearing rather than incidental:
///
/// 1. Caps are reported. A walk that stopped at the visit cap sets `capped`, and
///    Describe words the count as a floor. A model that reads a truncated count
///    as a total builds every later claim on it.
/// 2. Access is fail-closed. An empty allowlist reads nothing. The deny set is a
///    class parameter so an instance cannot widen it, and it is checked after
///    the allowlist so `^*` still cannot reach `^ROUTINE`.
Class RLM.Source.Global Extends RLM.Source
{

/// Globals this source may never read, whatever the allowlist says.
///
/// A parameter rather than a property, because an instance that could widen this
/// makes every allowlist in production advisory. Patterns are comma-separated and
/// `*` is a trailing wildcard.
Parameter DENY = "^%*,^ISC*,^rMAP*,^ROUTINE*,^odd*";

/// The global being decomposed, `^Name` with no subscripts.
Property GlobalRef As %String;

/// Comma-separated permit patterns, `*` a trailing wildcard. Empty permits
/// nothing: an operator who has not said which globals may be read has not
/// authorized any.
Property AllowList As %String;

/// Nodes one walk may visit before it stops and says it stopped.
Property VisitCap As %Integer [ InitialExpression = 50000 ];

/// Subscript levels below the walk's root it may descend.
Property DepthCap As %Integer [ InitialExpression = 8 ];

/// Entries in a peek's `topFanout`. Bounded so peek size does not grow with the
/// width of the level being described.
Property TopN As %Integer [ InitialExpression = 5 ];

/// Construct, or refuse with a reason.
///
/// The gate runs here rather than at peek time so a refused source does not
/// exist to be walked. `sc` carries the refusal; a caller that ignores it gets an
/// object whose GlobalRef is empty and whose every peek errors.
Method %OnNew(
	globalRef As %String,
	allowList As %String = "",
	Output sc As %Status) As %Status
{
    Set sc = ..Validate(globalRef, allowList)
    If $$$ISERR(sc) { Quit sc }
    Set ..GlobalRef = globalRef
    Set ..AllowList = allowList
    Set ..Name = globalRef
    Quit $$$OK
}

/// Whether `ref` may be read under `allowList`, and why not if it may not.
///
/// The order is deliberate: malformation is reported before denial, so an
/// operator told "not allowed" about `^Sales(1)` does not go and widen the
/// allowlist over a reference that was never a global name.
ClassMethod Validate(
	ref As %String,
	allowList As %String) As %Status
{
    If $Extract(ref, 1) '= "^" {
        Quit $$$ERROR($$$GeneralError, "'"_ref_"' is not a global reference: it must start with ^")
    }
    If ref [ "(" {
        Quit $$$ERROR($$$GeneralError, "'"_ref_"' carries subscripts; a subscript belongs in a slice name, not in the source")
    }
    // `^||Name` is process-private, which is local by definition rather than an
    // extended reference: it names storage this process owns and no other
    // process or namespace can see. `^|"NS"|Name` and `^["NS"]Name` do reach
    // another namespace and stay refused.
    Set name = $Select($Extract(ref, 1, 3) = "^||": $Extract(ref, 4, *), 1: $Extract(ref, 2, *))
    If name = "" {
        Quit $$$ERROR($$$GeneralError, "'"_ref_"' names no global")
    }
    If (name [ "|") || (name [ "[") || (name [ """") {
        Quit $$$ERROR($$$GeneralError, "'"_ref_"' is an extended reference; this source reads the current namespace only")
    }

    If '..Matches(ref, allowList) {
        Quit $$$ERROR($$$GeneralError, "'"_ref_"' is not in the allowlist; this source reads nothing it has not been permitted")
    }
    // Deny is matched against the bare name as well as the written reference, so
    // `^||%Foo` cannot slip past a `^%*` pattern by carrying a prefix.
    Set hit = ..FirstMatch(ref, ..#DENY)
    If hit = "" { Set hit = ..FirstMatch("^"_name, ..#DENY) }
    If hit '= "" {
        Quit $$$ERROR($$$GeneralError, "'"_ref_"' matches the denied pattern '"_hit_"'; the deny set is not overridable")
    }
    Quit $$$OK
}

/// The legal moves at `path`: one dimension per subscript level, whose children
/// are the subscripts that are actually there.
///
/// Only the *next* level is offered. Fixing level 2 without fixing level 1 does
/// not name a subtree in a hierarchy -- there is no such thing as "all the
/// BOS-GEN nodes" without saying which date -- so the dimension for level n only
/// exists once levels 1..n-1 are fixed. That also makes RLM.Slice's
/// one-dimension-per-path rule mean the right thing: each subscript level is
/// fixed at most once.
Method Dimensions(path As %String = "") As %DynamicObject
{
    Set out = {}
    If ..GlobalRef = "" { Quit out }

    Set level = ..PathDepth(path) + 1
    If level > ..DepthCap { Quit out }

    Set ref = ..Reference(..PredicateFor(path), .ok)
    If 'ok { Quit out }

    Set spec = {"label": ("subscript level "_level), "children": []}
    Set sub = ""
    For  {
        Set sub = $Order(@ref@(sub))
        Quit:sub=""
        Do spec.children.%Push({"token": (..Encode(sub)), "label": (sub)})
    }
    // A level with nothing under it is not a dimension. Advertising it would
    // offer the model a move that resolves to an empty slice.
    If spec.children.%Size() = 0 { Quit out }
    Do out.%Set("s"_level, spec)
    Quit out
}

/// The store's own representation of a slice: the raw subscripts, PATHSEP-joined
/// after decoding. Called only by RLM.Slice with components it has already
/// checked against Dimensions, so a token here is always one this class emitted.
///
/// Subscripts are carried as a $LIST rather than as text, because a subscript may
/// contain any character including the separators this class would otherwise use
/// to split them apart again.
Method Predicate(components As %List) As %String
{
    Set subs = "", ptr = 0
    While $ListNext(components, ptr, comp) {
        Set subs = subs_$ListBuild(..Decode($Piece(comp, ##class(RLM.Slice).#TOKENSEP, 2)))
    }
    Quit subs
}

/// Aggregate statistics for the subtree at `predicate`.
///
/// Everything here is a count, a moment or a type tally. No stored value leaves
/// this method, and no subscript except the immediate children's, which
/// Constitution I allows through only because Principle II needs the legal-move
/// list.
///
/// Bounded by VisitCap and DepthCap, and `capped` is set when either stopped the
/// walk. That flag is not a courtesy: a model that reads a truncated count as a
/// total inherits the error into every downstream claim.
Method Peek(predicate As %String = "") As %DynamicObject
{
    If ..GlobalRef = "" {
        Quit {"error": "this source was refused at construction and reads nothing"}
    }
    Set ref = ..Reference(predicate, .ok)
    If 'ok {
        Quit {"error": ("'"_..GlobalRef_"' cannot be addressed at that slice")}
    }

    Kill st
    Set st("visits") = 0, st("cap") = ..VisitCap, st("maxdepth") = ..DepthCap
    Set st("depth") = 0, st("data") = 0, st("ptr") = 0
    Set st("len") = 0, st("len2") = 0, st("capped") = 0
    Set st("num") = 0, st("str") = 0, st("list") = 0

    // The slice's own node counts, so a parent's n is its node plus its
    // children's closed subtrees and the arithmetic closes at every level.
    If $Data(@ref) {
        Set st("visits") = 1
        If $Data(@ref) # 10 {
            Set st("data") = 1
            Set len = $Length(@ref)
            Set st("len") = len, st("len2") = len * len
        } Else {
            Set st("ptr") = 1
        }
    }

    Do ..Walk(ref, 1, .st)

    Set children = 0, sub = ""
    For  {
        Set sub = $Order(@ref@(sub))
        Quit:sub=""
        Set children = children + 1
        Set fan(..ChildNodes($Name(@ref@(sub))), children) = sub
        If $ListValid(sub) {
            Set st("list") = st("list") + 1
        } ElseIf $IsValidNum(sub) {
            Set st("num") = st("num") + 1
        } Else {
            Set st("str") = st("str") + 1
        }
    }

    Set mean = 0, sd = 0
    If st("data") > 0 {
        Set mean = st("len") / st("data")
        // Population variance from the running sums. Clamped at 0 because
        // floating point can make a genuinely-zero variance very slightly
        // negative, and a negative under a square root is a <FUNCTION> error
        // rather than a wrong number.
        Set var = (st("len2") / st("data")) - (mean * mean)
        If var < 0 { Set var = 0 }
        Set sd = var ** 0.5
    }

    Set peek = {
        "n": (st("visits")),
        "capped": (st("capped")),
        "depth": (st("depth")),
        "children": (children),
        "dataNodes": (st("data")),
        "pointerNodes": (st("ptr")),
        "valueLenMean": (..Round(mean)),
        "valueLenSd": (..Round(sd)),
        "subNumeric": (st("num")),
        "subString": (st("str")),
        "subList": (st("list")),
        "topFanout": []
    }
    // Descending by subtree size, then by walk order within a tie, so two peeks
    // of a frozen store produce the same list.
    Set n = "", emitted = 0
    For  {
        Set n = $Order(fan(n), -1)
        Quit:n=""
        Set i = ""
        For  {
            Set i = $Order(fan(n, i))
            Quit:i=""
            Quit:emitted>=..TopN
            Set sub = fan(n, i)
            Do peek.topFanout.%Push({"token": (..Encode(sub)), "label": (sub), "n": (n)})
            Set emitted = emitted + 1
        }
        Quit:emitted>=..TopN
    }
    Quit peek
}

/// Visit the descendants of `ref`, accumulating into `st`.
///
/// Recursive $ORDER rather than $QUERY: $QUERY visits only nodes that hold a
/// value, so a global whose interior nodes are pure pointers -- the common shape
/// -- would report a node count far below its real one and a pointer count of 0.
Method Walk(
	ref As %String,
	depth As %Integer,
	ByRef st) [ Private ]
{
    If depth > st("maxdepth") {
        // Deeper nodes exist and were not counted, which is a cap like any
        // other and is disclosed like one.
        If $Data(@ref) \ 10 { Set st("capped") = 1 }
        Quit
    }
    Set sub = ""
    For  {
        Set sub = $Order(@ref@(sub))
        Quit:sub=""
        If st("visits") >= st("cap") {
            Set st("capped") = 1
            Quit
        }
        Set child = $Name(@ref@(sub))
        Set st("visits") = st("visits") + 1
        If st("depth") < depth { Set st("depth") = depth }

        Set d = $Data(@child)
        If d # 10 {
            Set st("data") = st("data") + 1
            Set len = $Length(@child)
            Set st("len") = st("len") + len
            Set st("len2") = st("len2") + (len * len)
        } Else {
            Set st("ptr") = st("ptr") + 1
        }
        If d \ 10 { Do ..Walk(child, depth + 1, .st) }
    }
}

/// Nodes in the closed subtree at `ref`, under the same caps as a peek. Used for
/// the fanout ranking, where the figure only has to order the children.
Method ChildNodes(ref As %String) As %Integer [ Private ]
{
    Kill st
    Set st("visits") = 0, st("cap") = ..VisitCap, st("maxdepth") = ..DepthCap
    Set st("depth") = 0, st("data") = 0, st("ptr") = 0
    Set st("len") = 0, st("len2") = 0, st("capped") = 0
    If $Data(@ref) { Set st("visits") = 1 }
    Do ..Walk(ref, 1, .st)
    Quit st("visits")
}

/// Self-labelling metric lines. A capped count is worded as a floor, so a model
/// quoting it cannot present it as a total.
Method Describe(
	label As %String,
	peek As %DynamicObject) As %String
{
    If peek.%Get("error") '= "" {
        Quit label_": could not be characterized -- "_peek.error
    }
    Set nl = $Char(10)
    Set out = label_nl
    Set out = out_"  nodes: "_peek.n
        _$Select(peek.capped:" (capped; the subtree is larger)", 1:"")_nl
    Set out = out_"  depth reached: "_peek.depth_nl
    Set out = out_"  immediate children: "_peek.children_nl
    If peek.topFanout.%Size() > 0 {
        Set busiest = "", it = peek.topFanout.%GetIterator()
        While it.%GetNext(, .child) {
            Set busiest = busiest_$Select(busiest="":"", 1:", ")
                _child.label_" ("_child.n_")"
        }
        Set out = out_"  busiest children: "_busiest_nl
    }
    If peek.n > 0 {
        Set out = out_"  node kind: "_..Pct(peek.dataNodes, peek.n)_"% data, "
            _..Pct(peek.pointerNodes, peek.n)_"% pointer"_nl
    }
    Set out = out_"  value length: mean "_peek.valueLenMean
        _", sd "_peek.valueLenSd_nl
    Set out = out_"  subscript types: "_peek.subNumeric_" numeric, "
        _peek.subString_" string, "_peek.subList_" list"
    Quit out
}

/// Normalized fanout entropy over the children's subtree sizes.
///
/// 1 when the children are the same size, 0 when one holds everything or there
/// is only one of them. It answers "does splitting here actually divide the
/// population", which is the only question a policy can ask of a store it knows
/// nothing else about.
Method SplitMetric(peek As %DynamicObject) As %Numeric
{
    If peek.%Get("error") '= "" { Quit 0 }
    Set k = peek.children
    If k < 2 { Quit 0 }
    If peek.topFanout.%Size() = 0 { Quit 0 }

    // topFanout is bounded at TopN, so for a wide level this is the entropy of
    // the largest children plus one bucket for the rest. That understates
    // evenness rather than overstating it, which is the safe direction: it
    // cannot make a useless split look good.
    Set total = peek.n - 1
    If total <= 0 { Quit 0 }
    Set h = 0, seen = 0, buckets = 0
    Set it = peek.topFanout.%GetIterator()
    While it.%GetNext(, .child) {
        Set p = child.n / total
        If p > 0, p < 1 { Set h = h - (p * ..Log2(p)) }
        Set seen = seen + child.n, buckets = buckets + 1
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
    Quit ..Round(norm)
}

/// Rows a dimension covers with no child. A subscript level enumerated by
/// walking has none by construction: every subscript found is a child.
Method NullCount(
	predicate As %String = "",
	dimension As %String = "") As %Integer
{
    Quit 0
}

/// A runtime-addressable reference for `predicate`, and whether it could be
/// built.
///
/// Assembled with $NAME under indirection rather than by concatenation, because
/// $NAME quotes and escapes the subscript itself. A subscript containing a
/// quote, a comma or a close paren defeats hand-written quoting, and the failure
/// is a read of a different node -- plausible figures about the wrong subtree,
/// which is worse than an error.
Method Reference(
	predicate As %String = "",
	Output ok As %Boolean) As %String [ Private ]
{
    Set ok = 0
    If ..GlobalRef = "" { Quit "" }
    Set g = ..GlobalRef
    Set ref = $Name(@g)
    Set ptr = 0
    While $ListNext(predicate, ptr, sub) {
        Set ref = $Name(@ref@(sub))
    }
    Set ok = 1
    Quit ref
}

/// The predicate a slice path resolves to, without going through RLM.Slice.
///
/// Dimensions needs this because it is called *with* a path and must walk to it,
/// and RLM.Slice calls Dimensions -- so routing back through Resolve would
/// recurse. The tokens here came from this class in the first place, and a token
/// that decodes to a subscript that is not there simply walks to a node with no
/// children, which yields an empty dimension rather than an error.
Method PredicateFor(path As %String = "") As %List [ Private ]
{
    Set subs = ""
    For i = 1:1:$Length(path, ##class(RLM.Slice).#PATHSEP) {
        Set comp = $Piece(path, ##class(RLM.Slice).#PATHSEP, i)
        Continue:comp=""
        Set subs = subs_$ListBuild(..Decode($Piece(comp, ##class(RLM.Slice).#TOKENSEP, 2)))
    }
    Quit subs
}

/// How many subscript levels `path` fixes.
ClassMethod PathDepth(path As %String = "") As %Integer
{
    Set n = 0
    For i = 1:1:$Length(path, ##class(RLM.Slice).#PATHSEP) {
        If $Piece(path, ##class(RLM.Slice).#PATHSEP, i) '= "" { Set n = n + 1 }
    }
    Quit n
}

/// A subscript as uppercase hex, two digits per character.
///
/// Hex rather than the raw subscript because a subscript is arbitrary text and
/// may contain `:` or `/`, which are the slice grammar's separators -- a raw
/// token carrying either would be read as extra structure. Hex rather than
/// Base64, which round-trips correctly but whose alphabet contains `/`.
///
/// The cost is that a token is unreadable, which is why every child also carries
/// its raw subscript as a `label`: the token is what the model names, the label
/// is what it reads.
/// UTF-8 first, so a subscript outside Latin-1 encodes as bytes rather than
/// silently truncating. Two hex digits per byte, uppercase, fixed width -- so an
/// odd-length token is detectably malformed rather than ambiguous.
ClassMethod Encode(sub As %String) As %String
{
    Set bytes = $ZConvert(sub, "O", "UTF8")
    Set out = ""
    For i = 1:1:$Length(bytes) {
        Set h = $ZHex($Ascii(bytes, i))
        Set out = out_$Select($Length(h)=1:"0"_h, 1:h)
    }
    Quit out
}

/// The inverse of Encode. Returns "" for anything that is not well-formed hex,
/// which RLM.Slice then fails to match against any enumerated child -- so a
/// malformed token is refused by the ordinary path rather than by a special case.
ClassMethod Decode(hex As %String) As %String
{
    If hex = "" { Quit "" }
    If $Length(hex) # 2 { Quit "" }
    If '..IsHex(hex) { Quit "" }
    Set bytes = ""
    For i = 1:2:$Length(hex) {
        Set bytes = bytes_$Char($ZHex($Extract(hex, i, i + 1)))
    }
    Quit $ZConvert(bytes, "I", "UTF8")
}

/// Whether every character of `s` is an uppercase hex digit.
///
/// Written as a keep-list $ZSTRIP rather than as stacked negations in the action
/// string: `$ZSTRIP(s,"*E'N'AU")` reads like it means this and is a <FUNCTION>
/// error at runtime.
ClassMethod IsHex(s As %String) As %Boolean
{
    Quit $ZStrip(s, "*E", "", "0123456789ABCDEF") = s
}

/// Two decimal places, as a number rather than a formatted string. Peek figures
/// are compared between runs, and a full floating-point expansion makes two
/// identical walks serialize differently.
ClassMethod Round(v As %Numeric) As %Numeric
{
    Quit +$FNumber(v, "", 2)
}

ClassMethod Pct(
	part As %Integer,
	whole As %Integer) As %Integer [ Private ]
{
    If whole = 0 { Quit 0 }
    Quit +$FNumber(part / whole * 100, "", 0)
}

ClassMethod Log2(v As %Numeric) As %Numeric [ Private ]
{
    Quit $ZLN(v) / $ZLN(2)
}

/// Whether `ref` matches any comma-separated pattern in `patterns`.
ClassMethod Matches(
	ref As %String,
	patterns As %String) As %Boolean
{
    Quit ..FirstMatch(ref, patterns) '= ""
}

/// The first pattern in `patterns` that `ref` matches, or "". Returning the
/// pattern rather than a flag is what lets a refusal name what matched.
ClassMethod FirstMatch(
	ref As %String,
	patterns As %String) As %String
{
    For i = 1:1:$Length(patterns, ",") {
        Set pat = $ZStrip($Piece(patterns, ",", i), "<>W")
        Continue:pat=""
        If $Extract(pat, $Length(pat)) = "*" {
            Set stem = $Extract(pat, 1, $Length(pat) - 1)
            If $Extract(ref, 1, $Length(stem)) = stem { Quit }
        } ElseIf ref = pat {
            Quit
        }
        Set pat = ""
    }
    Quit $Get(pat)
}

}
