/// A store over an interoperability message flow.
///
/// What a dedicated source gives that a configured `RLM.Source.Table` over
/// `Ens.MessageHeader` does not: the dimensions are the domain (a message has a
/// source, a target, a status and a time, and nothing else worth dividing by), the
/// metric is the domain (a slice is "mixed" when its messages take several routes,
/// which no generic metric knows), and the refusals are the domain (a namespace with
/// interop disabled is not a store with no rows -- it is a question that cannot be
/// asked here at all).
///
/// Constitution I is enforced by construction rather than by filtering: the peek is
/// built from counts and config names, and no method on this class reads
/// `MessageBodyClassName`, `MessageBodyId`, `Description` or any other field that
/// could carry content. The body is never fetched, so it cannot leak.
Class RLM.Source.Interop Extends RLM.Source.Extent
{

/// The status enumeration, as `code|meaning` pairs.
///
/// Read from the property's VALUELIST/DISPLAYLIST rather than hardcoded, so a code
/// added to Ensemble shows up here instead of being described as unknown. The
/// fallback list is the enumeration as of IRIS 2026.1, for the case where the
/// dictionary lookup fails -- a source that offered no status dimension because a
/// parameter lookup missed would be a silent loss of a dimension.
ClassMethod StatusPairs() As %List
{
    Set p = ##class(%Dictionary.CompiledProperty).%OpenId("Ens.MessageHeader||Status", , .sc)
    If $IsObject($Get(p)) {
        Set values = p.Parameters.GetAt("VALUELIST")
        Set display = p.Parameters.GetAt("DISPLAYLIST")
        If (values '= ""), (display '= "") {
            Set delim = $Extract(values), out = ""
            For i = 2:1:$Length(values, delim) {
                Set code = $Piece(values, delim, i)
                Continue:code=""
                Set out = out_$ListBuild(code_"|"_$Piece(display, delim, i))
            }
            If out '= "" { Quit out }
        }
    }
    Quit $ListBuild("1|Created", "2|Queued", "3|Delivered", "4|Discarded",
        "5|Suspended", "6|Deferred", "7|Aborted", "8|Error", "9|Completed")
}

/// The meaning of a status code.
///
/// An unrecognized code keeps its value and is marked unknown rather than dropped:
/// dropping it would give the model a menu whose children do not cover the slice, and
/// the missing rows would appear nowhere.
ClassMethod StatusLabel(code As %String) As %String
{
    Set ptr = 0
    While $ListNext(..StatusPairs(), ptr, pair) {
        If $Piece(pair, "|", 1) = code { Quit }
    }
    If $Get(pair) '= "", $Piece(pair, "|", 1) = code {
        Quit code_" "_$Piece(pair, "|", 2)
    }
    Quit code_" (unknown status)"
}

/// The status code that means a message failed, as the peek's `errors` counts it.
ClassMethod ErrorStatus() As %Integer
{
    Quit 8
}

Method %OnNew(className As %String = "Ens.MessageHeader") As %Status
{
    Set sc = ##super(className)
    If $$$ISERR(sc) { Quit sc }
    Do ..AddDimension("source", "SourceConfigName")
    Do ..AddDimension("target", "TargetConfigName")
    Do ..AddDimension("status", "Status")
    // Hour of day rather than an enumerated timestamp: a store spanning a week offers
    // the same 24 children as one spanning an hour, so the menu's size does not follow
    // the data. FR: the fanout a policy sees is bounded by the dimension, not by how
    // long the production has been running.
    Set children = ""
    For h = 0:1:23 {
        Set children = children_$ListBuild(h_"|"_$Extract("0"_h, *-1, *)_":00")
    }
    Do ..AddDerivedDimension("hour", "DATEPART('hour', TimeCreated)", children)
    Quit $$$OK
}

/// A status child is described by its meaning, not by its code.
Method ChildLabel(
	dimension As %String,
	value As %String) As %String
{
    If dimension = "status" { Quit ..StatusLabel(value) }
    Quit value
}

Method Label(dimension As %String) As %String
{
    If dimension = "source" { Quit "sending config" }
    If dimension = "target" { Quit "receiving config" }
    If dimension = "status" { Quit "message status" }
    If dimension = "hour" { Quit "hour of day" }
    Quit ##super(dimension)
}

/// Counts and config names. Never a body, never a description.
///
/// `routes` is the bounded source-target distribution the metric is computed from,
/// carried on the peek so the metric does not have to query again -- a metric that
/// re-queried could disagree with the peek it was handed.
Method Peek(predicate As %String = "") As %DynamicObject
{
    Set n = ..Count(predicate, .capped)
    If n < 0 { Quit {"n": 0, "error": "the extent could not be counted"} }
    Set routes = ..Distribution(predicate,
        $ListBuild(..Column("SourceConfigName"), ..Column("TargetConfigName")),
        ..TopN, .covered)
    Set targets = ..Distribution(predicate, $ListBuild(..Column("TargetConfigName")), ..TopN)
    Set sources = ..Distribution(predicate, $ListBuild(..Column("SourceConfigName")), ..TopN)
    Set peek = {}
    Set peek.n = n
    Set peek.capped = $Select(capped:1, 1:0)
    Set peek.errors = ..Count(..AndTerm(predicate, ..Column("Status"), "=", ..ErrorStatus()))
    Set peek.sources = sources.%Size()
    Set peek.targets = targets.%Size()
    // The busiest target by count, named because a policy dividing a flow wants to
    // know where the traffic goes. Distribution is already count-ordered.
    Set peek.busiest = $Select(targets.%Size() > 0:targets.%Get(0).key, 1:"")
    Set peek.routes = routes
    Set peek.covered = covered
    Quit peek
}

/// `predicate` with one more term appended, encoded the same way Predicate encodes
/// one so that Where decodes both identically.
Method AndTerm(
	predicate As %String,
	column As %String,
	op As %String,
	value As %String) As %String [ Private ]
{
    Quit predicate_..Term(predicate, column, op, value)
}

/// Count with the cap ignored for the caller: an error count is a component of an
/// already-disclosed total.
Method Count(
	predicate As %String = "",
	Output capped As %Boolean) As %Integer
{
    Quit ##super(predicate, .capped)
}

Method Describe(
	label As %String,
	peek As %DynamicObject) As %String
{
    If peek.%IsDefined("error") { Quit label_": "_peek.error }
    Set n = $Select(peek.capped:"at least "_peek.n, 1:peek.n)
    Set out = label_": "_n_" message(s)"
    If peek.n = 0 { Quit out }
    Set out = out_", "_peek.errors_" in error"
    Set out = out_", "_peek.sources_" sending and "_peek.targets_" receiving config(s)"
    If peek.busiest '= "" { Set out = out_", busiest receiver "_peek.busiest }
    Quit out
}

/// How mixed the slice's routing is: the normalized entropy of its source-target
/// pairs.
///
/// 0 when every message takes the same route -- there is nothing left to divide, and
/// a slice like that is where a decomposition should stop. Higher when the messages
/// take several routes, because that is a slice with structure still in it.
Method SplitMetric(peek As %DynamicObject) As %Numeric
{
    If 'peek.%IsDefined("routes") { Quit 0 }
    Set sizes = "", i = 0
    For i = 0:1:peek.routes.%Size() - 1 {
        Set sizes = sizes_$ListBuild(+peek.routes.%Get(i).n)
    }
    Quit ..Entropy(sizes, +peek.covered)
}

/// Refuse rather than report on a store that cannot answer.
///
/// Interop-enabled is checked before emptiness, because in a namespace without
/// interop the extent is not empty -- the table does not meaningfully exist, and
/// "no messages" would be a true statement that sent the reader looking in the
/// wrong place.
Method Ready(Output reason As %String) As %Boolean
{
    Set reason = ""
    If '..InteropEnabled() {
        Set reason = "namespace "_$Namespace_" is not interoperability-enabled, "
            _"so there is no message flow to decompose"
        Quit 0
    }
    Set n = ..Count("", .capped)
    If n < 0 {
        Set reason = ..ClassName_" could not be counted"
        Quit 0
    }
    If n = 0 {
        Set reason = ..ClassName_" holds no messages, so there is nothing to divide"
        Quit 0
    }
    Quit 1
}

/// Whether this namespace has interoperability enabled.
///
/// Overridable so a test can assert both sides of the refusal: disabling interop in
/// the container to test the refusal would leave every other interop test unable to
/// run.
Method InteropEnabled() As %Boolean
{
    Quit ##class(%EnsembleMgr).IsEnsembleNamespace($Namespace)
}

}
