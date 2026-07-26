/// A store over an audit log.
///
/// What a dedicated source gives that a configured `RLM.Source.Table` over
/// `%SYS.Audit` does not: the dimensions are the domain (who, what, where, which
/// subsystem), the metric is the domain (a slice is mixed when it holds several kinds
/// of event, which is what makes it worth dividing further), and the refusals are the
/// domain (a log that is empty because auditing is switched off is a different fact
/// from a log that is empty because nothing happened, and only one of them is worth
/// telling the reader to go fix).
///
/// Constitution I matters more here than anywhere else in this project: an audit
/// row's `EventData`, `Description` and `UserInfo` carry the detail of what a user
/// actually did. No method on this class reads any of the three. The peek is counts
/// and identifiers, and the columns that carry content are never selected, so there
/// is nothing to filter out later.
Class RLM.Source.Audit Extends RLM.Source.Extent
{

Method %OnNew(className As %String = "%SYS.Audit") As %Status
{
    Set sc = ##super(className)
    If $$$ISERR(sc) { Quit sc }
    // Declared rather than refused when absent: over the real %SYS.Audit all four
    // exist, and over a fixture with the same column shape they exist too. A missing
    // one is a genuinely broken extent, and AddDimension says so.
    Do ..AddDimension("eventsource", "EventSource")
    Do ..AddDimension("eventtype", "EventType")
    Do ..AddDimension("user", "Username")
    Do ..AddDimension("namespace", "Namespace")
    Quit $$$OK
}

Method Label(dimension As %String) As %String
{
    If dimension = "eventsource" { Quit "audit facility" }
    If dimension = "eventtype" { Quit "event type" }
    If dimension = "user" { Quit "user" }
    If dimension = "namespace" { Quit "namespace" }
    Quit ##super(dimension)
}

/// Counts and identifiers. Never EventData, Description or UserInfo.
///
/// `types` is the bounded event-type distribution the metric is computed from, carried
/// on the peek so the metric cannot disagree with the peek it was handed.
Method Peek(predicate As %String = "") As %DynamicObject
{
    Set n = ..Count(predicate, .capped)
    If n < 0 { Quit {"n": 0, "error": "the audit extent could not be counted"} }
    Set users = ..Distribution(predicate, $ListBuild(..Column("Username")), ..TopN)
    Set spaces = ..Distribution(predicate, $ListBuild(..Column("Namespace")), ..TopN)
    Set types = ..Distribution(predicate, $ListBuild(..Column("EventType")), ..TopN, .covered)
    Set peek = {}
    Set peek.n = n
    Set peek.capped = $Select(capped:1, 1:0)
    Set peek.users = users.%Size()
    Set peek.namespaces = spaces.%Size()
    Set peek.dominant = $Select(users.%Size() > 0:users.%Get(0).key, 1:"")
    Set peek.dominantn = $Select(users.%Size() > 0:+users.%Get(0).n, 1:0)
    Set peek.types = types
    Set peek.covered = covered
    Quit peek
}

Method Describe(
	label As %String,
	peek As %DynamicObject) As %String
{
    If peek.%IsDefined("error") { Quit label_": "_peek.error }
    Set n = $Select(peek.capped:"at least "_peek.n, 1:peek.n)
    Set out = label_": "_n_" audit event(s)"
    If peek.n = 0 { Quit out }
    Set out = out_", "_peek.users_" user(s) in "_peek.namespaces_" namespace(s)"
    If peek.dominant '= "" {
        Set out = out_", most from "_peek.dominant_" ("_peek.dominantn_")"
    }
    Quit out
}

/// How mixed the slice's event types are: 0 when every row is the same kind of event,
/// 1 when the kinds are evenly represented.
Method SplitMetric(peek As %DynamicObject) As %Numeric
{
    If 'peek.%IsDefined("types") { Quit 0 }
    Set sizes = ""
    For i = 0:1:peek.types.%Size() - 1 {
        Set sizes = sizes_$ListBuild(+peek.types.%Get(i).n)
    }
    Quit ..Entropy(sizes, +peek.covered)
}

/// Refuse rather than report on a log that cannot answer.
///
/// The auditing check runs only over the real audit extent. A fixture with the same
/// column shape is not the audit log, and refusing it because the system's auditing
/// flag is off would make this source untestable on a machine with auditing off --
/// while over the real extent that flag is exactly the difference between "nothing
/// happened" and "nothing was recorded".
Method Ready(Output reason As %String) As %Boolean
{
    Set reason = ""
    If ..IsSystemAudit(), '..AuditingEnabled() {
        Set reason = "auditing is disabled on this instance, so the audit log records "
            _"nothing and an empty result would not mean nothing happened"
        Quit 0
    }
    Set n = ..Count("", .capped)
    If n < 0 {
        Set reason = ..ClassName_" could not be counted"
        Quit 0
    }
    If n = 0 {
        Set reason = ..ClassName_" holds no events, so there is nothing to divide"
        Quit 0
    }
    Quit 1
}

/// Whether this source is pointed at the instance's real audit log.
Method IsSystemAudit() As %Boolean
{
    Quit ..ClassName = "%SYS.Audit"
}

/// Whether auditing is switched on for this instance.
///
/// Read through Security.System in %SYS and restored with `New $Namespace`, because
/// the flag is not namespace-local and a source must not leave the caller somewhere
/// else. Failure to read it is reported as enabled: refusing a readable log because a
/// configuration lookup failed would hide a store that works.
ClassMethod AuditingEnabled() As %Boolean
{
    Set enabled = 1
    Try {
        New $Namespace
        Set $Namespace = "%SYS"
        Set sc = ##class(Security.System).Get(, .props)
        If $$$ISOK(sc), $Data(props("AuditEnabled")) {
            Set enabled = ''props("AuditEnabled")
        }
    } Catch e {
        Set enabled = 1
    }
    Quit enabled
}

}
