/// Tests for trace format v2: the version, the store fingerprint, the question
/// and the per-row model text.
///
/// All four are new *subscripts*. The positional $LIST row is untouched, which is
/// the whole reason the change is safe -- but "additive" is a claim about the
/// readers, not about the writer, and every existing reader walks
/// `$Order(^RLM.Trace(runId, seq))` over all subscripts of the run. A string
/// subscript collates after every numeric one, so a metadata node under the run
/// is visited by those loops unless they are told not to. That is what the second
/// half of this class tests, and it is the reason the readers gained a numeric
/// guard alongside the writer.
Class UnitTest.RLM.TraceFormat Extends %UnitTest.TestCase
{

/// Durable traces are shared namespace state. Left behind, run ids drift between
/// suite runs and any assertion on a run id becomes a flake.
Method OnBeforeOneTest(testname As %String) As %Status
{
    Kill ^RLM.Trace
    Quit $$$OK
}

Method OnAfterOneTest(testname As %String) As %Status
{
    Kill ^RLM.Trace
    Quit $$$OK
}

ClassMethod Source() As UnitTest.RLM.Fixture
{
    Quit ##class(UnitTest.RLM.Fixture).%New("widgets")
}

/// A durable run records what it takes to replay it: which format wrote it, what
/// the store looked like, and what was asked.
Method TestADurableTraceRecordsVersionFingerprintAndQuestion()
{
    Set trace = ##class(RLM.Trace).%New(1)
    Do trace.Begin("how do sales split?", ##class(RLM.Trace).StoreFingerprint(..Source()))
    Set runId = trace.RunId

    Do $$$AssertEquals(##class(RLM.Trace).Version(runId, 1), 2, "version 2 recorded")
    Do $$$AssertEquals(##class(RLM.Trace).Question(runId, 1), "how do sales split?", "question recorded verbatim")
    Do $$$AssertNotEquals(##class(RLM.Trace).Fingerprint(runId, 1), "", "a fingerprint was recorded")
}

/// A process-private trace cannot be replayed in another session, so the
/// fingerprint it would pay a peek per slice for buys nothing. Asserted rather
/// than assumed, because the cheap path is the one a later change silently
/// widens.
Method TestAProcessPrivateTraceRecordsNoMetadata()
{
    Set trace = ##class(RLM.Trace).%New(0)
    Do trace.Begin("q", "fp-that-should-not-be-written")
    Do $$$AssertEquals(##class(RLM.Trace).Version(trace.RunId, 0), 1, "no version node: reads as version 1")
    Do $$$AssertEquals(##class(RLM.Trace).Fingerprint(trace.RunId, 0), "", "no fingerprint written")
    Do $$$AssertEquals(##class(RLM.Trace).Question(trace.RunId, 0), "", "no question written")
}

/// A trace written before this feature has no "v" node at all. It must read as
/// version 1 rather than as version "" -- a replay comparing "" against 2 would
/// refuse for the right reason by accident and report the wrong version.
Method TestATraceWithNoVersionNodeReadsAsVersionOne()
{
    Set trace = ##class(RLM.Trace).%New(1)
    Do trace.Add("subcall", 1, "color:red", "UnitTest.RLM.Fixture")
    Do $$$AssertEquals(##class(RLM.Trace).Version(trace.RunId, 1), 1, "a trace with no metadata is version 1")
}

/// The fingerprint is a function of the store, so two computations over an
/// unchanged store agree. Without this the mismatch check in US4 could pass by
/// always disagreeing.
Method TestTheFingerprintIsStableOverAnUnchangedStore()
{
    Set a = ##class(RLM.Trace).StoreFingerprint(..Source())
    Set b = ##class(RLM.Trace).StoreFingerprint(..Source())
    Do $$$AssertEquals(a, b, "same store, same fingerprint")
    Do $$$AssertNotEquals(a, "", "and it is not the empty string")
}

/// A store whose figures moved must produce a different fingerprint, or the
/// mismatch refusal is decoration.
Method TestADifferentStoreProducesADifferentFingerprint()
{
    Set a = ##class(RLM.Trace).StoreFingerprint(..Source())
    Set b = ##class(RLM.Trace).StoreFingerprint(##class(UnitTest.RLM.FixtureFlat).%New())
    Do $$$AssertNotEquals(a, b, "two stores, two fingerprints")
}

/// Constitution I. The fingerprint travels into a durable global, so the one
/// thing it must not be is a copy of anything the store holds.
Method TestTheFingerprintIsANumberAndNotStoreContents()
{
    Set fp = ##class(RLM.Trace).StoreFingerprint(..Source())
    Do $$$AssertTrue(fp?1.N, "the fingerprint is numeric: "_fp)
}

/// The model's own output, kept so a replay can reproduce a report instead of
/// approximating one. The row keeps its lengths; the text is a sidecar.
Method TestModelTextIsStoredAndReadBackVerbatim()
{
    Set trace = ##class(RLM.Trace).%New(1)
    Set seq = trace.Add("subcall", 1, "color:red", "UnitTest.RLM.Fixture", 0.2, 40, 12, "null")
    Do trace.SetText(seq, "red is 600 rows at metric 0.20")
    Do $$$AssertEquals(##class(RLM.Trace).TextAt(trace.RunId, seq, 1), "red is 600 rows at metric 0.20", "text read back verbatim")
    Do $$$AssertEquals($List(trace.Row(seq), 8), 12, "the row still carries the output length")
}

/// A row with nothing to store writes no node. An empty node and a missing node
/// are indistinguishable to `$Get`, and the difference matters to a reader
/// deciding whether a v2 trace is complete.
Method TestARowWithNoModelOutputWritesNoTextNode()
{
    Set trace = ##class(RLM.Trace).%New(1)
    Set seq = trace.Add("capped", 1, "color:red", "UnitTest.RLM.Fixture")
    Do trace.SetText(seq, "")
    Do $$$AssertEquals($Data(^RLM.Trace(trace.RunId, seq, "t")), 0, "no text node for a row with no output")
}

/// Process-private traces get no text either, for the same reason they get no
/// fingerprint: nothing will ever replay them.
Method TestAProcessPrivateTraceStoresNoModelText()
{
    Set trace = ##class(RLM.Trace).%New(0)
    Set seq = trace.Add("subcall", 1, "color:red", "UnitTest.RLM.Fixture")
    Do trace.SetText(seq, "something")
    Do $$$AssertEquals(##class(RLM.Trace).TextAt(trace.RunId, seq, 0), "", "no text stored on a private trace")
}

// ---- the additivity assertions: existing readers must not see metadata ----

/// `RowCount` counts rows. The metadata subscripts are not rows, and they sort
/// after every numeric one, so a loop that walks all subscripts of a run counts
/// three extra "rows" the moment a run becomes durable.
Method TestRowCountIgnoresMetadataSubscripts()
{
    Set trace = ##class(RLM.Trace).%New(1)
    Do trace.Begin("q", "12345")
    Do trace.Add("subcall", 1, "a", "S")
    Do trace.Add("subcall", 1, "b", "S")
    Do trace.Add("synthesis", 0, "", "S")
    Do $$$AssertEquals(##class(RLM.Trace).RowCount(trace.RunId, 1), 3, "three rows, not six")
}

/// Same loop, same hazard: `Count` walks by $Increment and stops at the first
/// missing ordinal, so it is safe by construction -- asserted so it stays that
/// way.
Method TestCountIgnoresMetadataSubscripts()
{
    Set trace = ##class(RLM.Trace).%New(1)
    Do trace.Begin("q", "12345")
    Do trace.Add("subcall", 1, "a", "S")
    Do trace.Add("synthesis", 0, "", "S")
    Do $$$AssertEquals(trace.Count(), 2, "two rows in total")
    Do $$$AssertEquals(trace.Count("subcall"), 1, "one of them a subcall")
}

/// `Decisions` walks the same subscripts looking for a "d" sidecar. A metadata
/// node has no "d" child so it would be skipped -- but `seqs` would then be keyed
/// off a walk that visited non-rows, and the ordinals a caller maps back through
/// would silently shift if metadata ever grew a subtree.
Method TestDecisionsIgnoresMetadataSubscripts()
{
    Set trace = ##class(RLM.Trace).%New(1)
    Do trace.Begin("q", "12345")
    Set d = ##class(RLM.Decision).%New("UnitTest.RLM.PolicyStub", 0.9)
    Do d.AddCandidate("color", 0.22, 2, 2)
    Do d.Choose("color", 0.22, "because")
    Do trace.AddDecision(d, 0, "S", "")
    Set decisions = ##class(RLM.Trace).Decisions(trace.RunId, 1, .seqs)
    Do $$$AssertEquals(decisions.Count(), 1, "one decision")
    Do $$$AssertEquals(decisions.GetAt(1).Dimension, "color", "and it round-tripped")
    Do $$$AssertEquals(seqs(1), 1, "mapped back to row 1")
}

/// A rendered trace of a durable run must have one line per row. The metadata
/// nodes hold plain strings, so `$List(row, 1)` over one of them returns
/// something arbitrary rather than failing -- a junk line, not an error.
Method TestRenderTraceIgnoresMetadataSubscripts()
{
    Set trace = ##class(RLM.Trace).%New(1)
    Do trace.Begin("how do sales split?", "12345")
    Do trace.Add("subcall", 1, "color:red", "S")
    Do trace.Add("synthesis", 0, "", "S")
    Set lines = ##class(RLM.Report).RenderTrace(trace.RunId, 1)
    Do $$$AssertEquals($ListLength(lines), 2, "two lines for two rows")
    Set joined = $ListToString(lines, "|")
    Do $$$AssertEquals($Find(joined, "how do sales split?"), 0, "the question is not rendered as a row")
}

/// The text sidecar sits at `(seq, "t")`, one level below where the decision
/// sidecar sits. Nothing that reads a decision may mistake it for one.
Method TestATextSidecarIsNotReadAsADecision()
{
    Set trace = ##class(RLM.Trace).%New(1)
    Do trace.Begin("q", "12345")
    Set seq = trace.Add("subcall", 1, "color:red", "S")
    Do trace.SetText(seq, "some prose")
    Do $$$AssertEquals(##class(RLM.Trace).Decisions(trace.RunId, 1).Count(), 0, "a subcall with text is not a decision")
}

}
