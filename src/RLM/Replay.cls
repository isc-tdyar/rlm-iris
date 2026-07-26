/// Re-run a recorded decomposition from its trace plus the store, with no model
/// call.
///
/// This is Constitution V, executable. A peek is a pure function of a frozen
/// store and the model never authors an input, so a trace plus the store is
/// everything a run was: the decisions are on the record, the model's words are on
/// the record, and the traversal between them is code.
///
/// ## How
///
/// The engine does the work. `RLM.Policy.Recorded` returns the decisions the run
/// made, `RLM.LLM.Recorded` returns the words the model said, and
/// `RLM.Engine.Run` traverses exactly as it did the first time. Nothing here
/// renders a report, because a second renderer is a second implementation of the
/// report and the two would drift.
///
/// What that buys is the strong form of the claim: the replayed document is
/// character-for-character the recorded one, which is a testable assertion rather
/// than a resemblance.
///
/// ## What it refuses
///
/// - a trace of a version this code does not replay, named in the reason
/// - a trace from a different source class
/// - a store whose fingerprint no longer matches the trace's
/// - a trace with no metadata at all, which includes every process-private trace
///
/// A refusal is the honest outcome, not a failure mode: a replay that ran anyway
/// would produce a report that differs from the original while claiming to
/// reproduce it, which is the undisclosed-cap failure one level up.
Class RLM.Replay Extends %RegisteredObject
{

/// The trace format this class replays. A trace written under any other version
/// is refused rather than interpreted.
Parameter FORMAT = 2;

Property Source As RLM.Source;

Property RunId As %Integer;

/// Model calls made. 0 on every path -- carried so a test can assert it rather
/// than infer it from a silent provider.
Property Calls As %Integer [ InitialExpression = 0 ];

/// Decisions reproduced.
Property Decisions As %Integer [ InitialExpression = 0 ];

/// The reproduced decisions, for a caller comparing them against the record.
Property ReplayedDecisions As %ListOfObjects;

/// Constructing a replay reads nothing. It records the source and the run id;
/// everything that could refuse happens in Verify, so a caller can ask "would this
/// replay?" without running one.
Method %OnNew(
	source As RLM.Source,
	runId As %Integer) As %Status
{
    Set ..Source = source
    Set ..RunId = runId
    Set ..ReplayedDecisions = ##class(%ListOfObjects).%New()
    Quit $$$OK
}

/// Whether this trace can be replayed against this store, and why not.
///
/// Idempotent and side-effect free apart from the peeks the fingerprint costs. It
/// is called by Run, and separately by callers that want the answer without the
/// report.
Method Verify(Output reason As %String) As %Boolean
{
    Set reason = ""
    If '$Data(^RLM.Trace(..RunId)) {
        Set reason = "no durable trace exists for run "_..RunId
        Quit 0
    }

    Set version = ##class(RLM.Trace).Version(..RunId, 1)
    If version '= ..#FORMAT {
        Set reason = "the trace is format version "_version_"; this replays "
            _"version "_..#FORMAT_" only"
        Quit 0
    }

    // The source class first, before the fingerprint. Two source classes produce
    // fingerprints that are not comparable, and a comparison that happened to
    // match would be worse than one that failed.
    Set recordedClass = ..RecordedSourceClass()
    If recordedClass '= "", recordedClass '= $ClassName(..Source) {
        Set reason = "the trace was recorded against "_recordedClass
            _" and this store is "_$ClassName(..Source)
        Quit 0
    }

    Set recorded = ##class(RLM.Trace).Fingerprint(..RunId, 1)
    If recorded = "" {
        Set reason = "the trace recorded no store fingerprint, so it cannot be "
            _"checked against this store"
        Quit 0
    }
    Set now = ##class(RLM.Trace).StoreFingerprint(..Source)
    If now '= recorded {
        Set reason = "the store no longer matches the trace: it was "_recorded
            _" when the run was recorded and is "_now_" now"
        Quit 0
    }
    Quit 1
}

/// The source class the run recorded, from its first row, or "" if it wrote none.
Method RecordedSourceClass() As %String [ Private ]
{
    Set seq = ""
    For  {
        Set seq = $Order(^RLM.Trace(..RunId, seq), 1, row)
        Quit:seq=""
        Quit:seq'?1.N
        If $List(row, 3) '= "" { Quit }
    }
    Quit $Select(seq="":"", 1:$List(row, 3))
}

/// Replay the run and write the report to `report`.
///
/// Returns Verify's error unchanged on refusal, with `report` set to the reason so
/// a caller that only prints the output still says something true.
Method Run(Output report As %String) As %Status
{
    Set report = ""
    If '..Verify(.reason) {
        Set report = "The replay was not run: "_reason_"."
        Quit $$$ERROR($$$GeneralError, reason)
    }

    Set config = ##class(RLM.Trace).Config(..RunId, 1)
    Set llm = ##class(RLM.LLM.Recorded).%New(..RunId, 1)
    Set policy = ##class(RLM.Policy.Recorded).%New(..RunId, 1)
    // The original's own limits. A replay under a wider budget would drop fewer
    // slices and produce a better report than the one it claims to reproduce.
    Set budget = ##class(RLM.Budget).%New(+$ListGet(config, 1),
        +$ListGet(config, 2), +$ListGet(config, 3))
    Set engine = ##class(RLM.Engine).%New(..Source, llm, budget, policy)
    Set engine.MaxDepth = +$ListGet(config, 4)
    Set engine.ReportStyle = $ListGet(config, 6)
    // Never durable. A replay that wrote a trace would leave a second record of
    // one run, and a later replay could not tell which one it was reproducing.
    Set engine.DurableTrace = 0

    Set report = engine.Run(##class(RLM.Trace).Question(..RunId, 1), .replayTraceId,
        $ListGet(config, 5))

    // Calls stays 0: RLM.LLM.Recorded answers from the record and reaches no
    // provider. The count that matters is the record's, and it is reported
    // separately so a caller can see the replay was not empty.
    Set ..Calls = 0
    Set ..Decisions = policy.Served
    Set ..ReplayedDecisions = policy.Recorded

    // A macro's arguments cannot span lines -- MPP5612 -- so each message is
    // assembled first and the macro takes one token.
    If policy.Overruns > 0 {
        Set msg = "the replayed traversal reached "_policy.Overruns
            _" slice(s) the recorded run did not"
        Quit $$$ERROR($$$GeneralError, msg)
    }
    If llm.Overruns > 0 {
        Set msg = "the replayed traversal asked for "_llm.Overruns
            _" model call(s) the recorded run did not make"
        Quit $$$ERROR($$$GeneralError, msg)
    }
    Quit $$$OK
}

}
