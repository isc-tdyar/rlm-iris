/// The feature gate for M4: an engine run over a live message flow and over an audit
/// log, each replayed byte for byte, each scored on the same card as Greedy, and
/// neither leaking a single byte of the content its extent holds.
///
/// Every other class in this suite tests one seam. This one asserts what the milestone
/// claims: that two real IRIS stores decompose the same way a fixture does, that the
/// resulting run is still a replayable artifact, and that the guarantees the earlier
/// milestones established did not quietly stop holding when the store became real.
///
/// Every assertion sits on one line: a macro's arguments cannot span source lines.
Class UnitTest.RLM.EndToEndInteropAudit Extends %UnitTest.TestCase
{

/// Ids of the message headers this test planted.
Property Planted As %List;

ClassMethod Marker() As %String
{
    Quit "SECRET-E2E-2ab4"
}

Method OnBeforeOneTest(testname As %String) As %Status
{
    Kill ^RLM.Trace
    Do ##class(UnitTest.RLM.FixtureAudit).Build()
    Set ..Planted = ""
    Set rows = $ListBuild("E2ESRCA|E2ETGTX|9", "E2ESRCA|E2ETGTX|9", "E2ESRCA|E2ETGTY|8",
        "E2ESRCB|E2ETGTX|9", "E2ESRCB|E2ETGTY|3", "E2ESRCC|E2ETGTY|9")
    Set ptr = 0
    While $ListNext(rows, ptr, row) {
        Set h = ##class(Ens.MessageHeader).%New()
        Set h.SourceConfigName = $Piece(row, "|", 1)
        Set h.TargetConfigName = $Piece(row, "|", 2)
        Set h.Status = $Piece(row, "|", 3)
        Set h.Type = 1
        Set h.Priority = 2
        Set h.Description = ..Marker()
        Set h.TimeCreated = "2026-07-20 04:15:00"
        Set sc = h.%Save()
        If $$$ISERR(sc) { Quit }
        Set ..Planted = ..Planted_$ListBuild(h.%Id())
    }
    Quit $Get(sc, $$$OK)
}

Method OnAfterOneTest(testname As %String) As %Status
{
    Set ptr = 0
    While $ListNext(..Planted, ptr, id) { Do ##class(Ens.MessageHeader).%DeleteId(id) }
    Set ..Planted = ""
    Do ##class(UnitTest.RLM.FixtureAudit).Wipe()
    Kill ^RLM.Trace
    Quit $$$OK
}

ClassMethod Interop() As RLM.Source.Interop
{
    Quit ##class(RLM.Source.Interop).%New()
}

ClassMethod Audit() As RLM.Source.Audit
{
    Quit ##class(RLM.Source.Audit).%New("UnitTest.RLM.FixtureAudit")
}

/// Identical replies on purpose: nothing here asserts on their content, and identical
/// replies keep the byte-identity assertion about the traversal rather than about the
/// script.
ClassMethod Scripted(n As %Integer = 32) As RLM.LLM.Null
{
    Set script = ""
    For i = 1:1:n { Set script = script_$ListBuild("divide by the sending config") }
    Quit ##class(RLM.LLM.Null).%New(script)
}

/// The whole milestone, for each source: run, replay, score.
Method TestBothSourcesRunReplayAndScore()
{
    Set sources = $ListBuild("interop", "audit")
    Set ptr = 0
    While $ListNext(sources, ptr, which) {
        Set store = $Select(which="interop":..Interop(), 1:..Audit())
        Set question = "how does this store divide?"

        // --- run ---
        Set llm = ..Scripted()
        Set engine = ##class(RLM.Engine).%New(store, llm,
            ##class(RLM.Budget).%New(32), ##class(RLM.Policy.Greedy).%New())
        Set engine.DurableTrace = 1
        Set engine.MaxDepth = 2
        Set original = engine.Run(question, .traceId)
        Do $$$AssertNotEquals(original, "", which_": a document came back")
        Do $$$AssertEquals($Find(original, "sub-call for"), 0, which_": and no sub-call failed")

        // --- replay ---
        Set store2 = $Select(which="interop":..Interop(), 1:..Audit())
        Set replay = ##class(RLM.Replay).%New(store2, traceId)
        Do $$$AssertTrue(replay.Verify(.reason), which_": the run verifies: "_reason)
        Do $$$AssertStatusOK(replay.Run(.replayed), which_": and it replays")
        Do $$$AssertEquals(replayed, original, which_": byte for byte")
        Do $$$AssertEquals(replay.Calls, 0, which_": with no model call")

        // --- score ---
        Set store3 = $Select(which="interop":..Interop(), 1:..Audit())
        Set card = ##class(RLM.Eval.Scorecard).Score(store3, question, $ListBuild("RLM.Policy.Greedy", "RLM.Policy.LLM"), ..Scripted(), 2, 32)
        Do $$$AssertEquals(card.rows.%Size(), 2, which_": two rows were scored")
        Do $$$AssertEquals(card.rows.%Get(0).error, "", which_": Greedy was scored")
        Set text = ##class(RLM.Eval.Scorecard).Render(card)
        Do $$$AssertTrue($Find(text, "RLM.Policy.Greedy") > 0, which_": the card names its policies")
    }
}

/// Constitution I, at the level that actually matters: a finished trace is walked
/// node by node and no marker planted in the extent's content columns appears anywhere
/// in it. The trace is the durable artifact -- a leak into it outlives the run.
Method TestNoMarkerReachesAnyPartOfEitherTrace()
{
    Set sources = $ListBuild("interop", "audit")
    Set ptr = 0
    While $ListNext(sources, ptr, which) {
        Kill ^RLM.Trace
        Set store = $Select(which="interop":..Interop(), 1:..Audit())
        Set engine = ##class(RLM.Engine).%New(store, ..Scripted(),
            ##class(RLM.Budget).%New(32), ##class(RLM.Policy.Greedy).%New())
        Set engine.DurableTrace = 1
        Set engine.MaxDepth = 2
        Set doc = engine.Run("how does this store divide?", .traceId)
        Set marker = $Select(which="interop":..Marker(), 1:##class(UnitTest.RLM.FixtureAudit).Marker())
        Do $$$AssertEquals($Find(doc, marker), 0, which_": the document carries no marker")
        // $QUERY rather than a keyed read: a leak into a subscript this test did not
        // think to look at is exactly the leak worth finding.
        Set found = "", node = "^RLM.Trace", n = 0
        For {
            Set node = $Query(@node)
            Quit:node=""
            Quit:$Extract(node, 1, 10)'="^RLM.Trace"
            Set n = n + 1
            If $Find(node_" "_@node, marker) > 0 { Set found = node Quit }
        }
        Do $$$AssertTrue(n > 0, which_": the walk saw trace nodes at all: "_n)
        Do $$$AssertEquals(found, "", which_": and no node holds the marker: "_found)
    }
}

/// Constitution VI. Both sources are part of the portable module, so they must compile
/// on an IRIS with no AI Hub and reach no provider.
Method TestBothSourcesArePortable()
{
    Set classes = $ListBuild("RLM.Source.Extent", "RLM.Source.Interop", "RLM.Source.Audit")
    Set ptr = 0
    While $ListNext(classes, ptr, cls) {
        Set text = ##class(UnitTest.RLM.EndToEndReplay).SourceTextOf(cls)
        Do $$$AssertTrue($Length(text) > 200, cls_": the source was read at all")
        Do $$$AssertEquals(text [ "%AI.", 0, cls_": no AI Hub dependency")
        Do $$$AssertEquals(text [ "%Net.", 0, cls_": no network client")
    }
}

/// Read-only, fingerprinted rather than assumed. A run that mutated the message flow
/// it was characterizing would be a catastrophe on a production, and "we never wrote
/// any code that writes" is not a guarantee -- a checksum over the columns the source
/// reads is.
Method TestNeitherExtentIsChangedByARunAReplayOrAScorecard()
{
    Set before = ..Fingerprint()
    Set store = ..Interop()
    Set engine = ##class(RLM.Engine).%New(store, ..Scripted(),
        ##class(RLM.Budget).%New(32), ##class(RLM.Policy.Greedy).%New())
    Set engine.DurableTrace = 1
    Set engine.MaxDepth = 2
    Do engine.Run("how does this store divide?", .traceId)
    Do ##class(RLM.Replay).%New(..Interop(), traceId).Run(.replayed)
    Do ##class(RLM.Eval.Scorecard).Score(..Audit(), "how does this store divide?", $ListBuild("RLM.Policy.Greedy"), ..Scripted(), 2, 32)
    Do $$$AssertEquals(..Fingerprint(), before, "neither extent changed")
}

/// Row counts plus a checksum over the columns either source reads, for both extents
/// at once.
ClassMethod Fingerprint() As %String
{
    Set out = ""
    Set sql = $ListBuild(
        "SELECT COUNT(*) AS n, SUM($LENGTH(SourceConfigName)+$LENGTH(TargetConfigName)+Status) AS c FROM Ens.MessageHeader",
        "SELECT COUNT(*) AS n, SUM($LENGTH(EventSource)+$LENGTH(EventType)+$LENGTH(Username)+$LENGTH(Namespace)) AS c FROM UnitTest_RLM.FixtureAudit")
    Set ptr = 0
    While $ListNext(sql, ptr, q) {
        Set rs = ##class(RLM.Source.Extent).Query(q, .sc)
        If $$$ISERR(sc) { Set out = out_"?|" Continue }
        If 'rs.%Next() { Set out = out_"?|" Continue }
        Set out = out_rs.%Get("n")_":"_rs.%Get("c")_"|"
    }
    Quit out
}

}
