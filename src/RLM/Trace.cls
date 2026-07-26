/// A structured record of one decomposition, one row per model call.
///
/// This is a record, not a log. An earlier prototype traced decompositions as
/// display strings, which made it impossible to tell a root decision from a
/// sub-agent's own peek -- a six-slice plan printed eight lines and read as a
/// budget violation. So `role` is the first field of every row.
///
/// Because a peek is a pure function of a frozen store, a trace plus the store
/// is enough to replay a run with no model call at all. That is what makes
/// offline evaluation -- and later, learning a policy -- possible, and it is why
/// the model is never allowed to author code: model-authored code is not a
/// function of the store, so it does not replay.
///
/// Rows live in a process-private global by default so a run leaves nothing
/// behind. Set Durable to write to ^RLM.Trace instead.
///
/// ## Format
///
/// ```text
/// ^RLM.Trace(runId)              next seq counter
/// ^RLM.Trace(runId, "v")         format version -- absent means 1
/// ^RLM.Trace(runId, "fp")        store fingerprint, see StoreFingerprint
/// ^RLM.Trace(runId, "q")         the question, so a replay needs only a run id
/// ^RLM.Trace(runId, seq)         the positional row, unchanged since v1
/// ^RLM.Trace(runId, seq, "t")    the model's own output for that row
/// ^RLM.Trace(runId, seq, "d"...) the decision sidecar, unchanged since v1
/// ```
///
/// The three metadata nodes and the text sidecar are additive: no field of the
/// positional row moved, so every v1 reader still reads a v2 row correctly. They
/// are not, however, free -- a string subscript collates after every numeric one,
/// so `$Order(^RLM.Trace(runId, seq))` reaches `"fp"`, `"q"` and `"v"` after the
/// last row and hands the caller a plain string where it expected a $LIST. Every
/// reader below therefore stops at the first non-numeric subscript, and
/// UnitTest.RLM.TraceFormat asserts that each one does.
///
/// Metadata and text are written only when the trace is durable. A process-private
/// trace vanishes with the process, so nothing will ever replay it, and the
/// fingerprint costs a peek per first-level slice to compute.
Class RLM.Trace Extends %RegisteredObject
{

/// The trace format this code writes. A replay refuses anything else rather than
/// interpreting it: a v1 trace has no text sidecars, and a replay that read a
/// missing sidecar as an empty answer would produce a *different* report while
/// claiming to reproduce one.
Parameter FORMAT = 2;

/// Identifier of this run, unique within the process.
Property RunId As %Integer;

/// Next row ordinal.
Property Seq As %Integer [ InitialExpression = 0 ];

/// Write to ^RLM.Trace rather than the process-private ^||RLM.Trace.
Property Durable As %Boolean [ InitialExpression = 0 ];

Method %OnNew(durable As %Boolean = 0) As %Status
{
    Set ..Durable = durable
    // $Select cannot choose between two global references -- `^||` is parsed as
    // an extended reference, not as a value -- so the branch is explicit.
    If durable {
        Set ..RunId = $Increment(^RLM.Trace)
    } Else {
        Set ..RunId = $Increment(^||RLM.Trace)
    }
    Quit $$$OK
}

/// Record what it takes to replay this run: the format, the store's fingerprint
/// and the question.
///
/// Called once, at the start of a run, before any row. Durable traces only.
///
/// The question is stored so a replay needs nothing but a run id and a source. A
/// caller made to supply the question again could supply a different one, and the
/// replayed report would then disagree with the original in a way no check here
/// could catch.
/// `config` is the run's own settings, as
/// `$LB(callTotal, reserved, peekTotal, maxDepth, rootPath, reportStyle)`. A
/// replay is only a replay if it runs under the same limits: a run that dropped
/// three slices because its budget ran out must drop the same three, and a replay
/// under a wider budget would produce a *better* report than the one it claims to
/// reproduce.
Method Begin(
	question As %String = "",
	fingerprint As %String = "",
	config As %List = "")
{
    Quit:'..Durable
    Set ^RLM.Trace(..RunId, "v") = ..#FORMAT
    Set ^RLM.Trace(..RunId, "q") = question
    If fingerprint '= "" { Set ^RLM.Trace(..RunId, "fp") = fingerprint }
    If config '= "" { Set ^RLM.Trace(..RunId, "c") = config }
}

/// The settings a run ran under, or "" if none were recorded.
ClassMethod Config(
	runId As %Integer,
	durable As %Boolean = 0) As %List
{
    If durable { Quit $Get(^RLM.Trace(runId, "c")) }
    Quit $Get(^||RLM.Trace(runId, "c"))
}

/// Attach the model's own output to a row.
///
/// The row keeps `$Length(out)`; this keeps `out`. Both, because the length is
/// what a cost reader wants and the text is what a replay needs, and deriving
/// either from the other is impossible.
///
/// Storing model output is not a Constitution I question. Principle I forbids
/// *store contents* reaching the model. This is the model's own words travelling
/// back into a report they were already in.
///
/// An empty output writes no node: `$Get` cannot tell an empty node from a missing
/// one, and "this row had no model output" is a different fact from "this row's
/// output was not recorded".
Method SetText(
	seq As %Integer,
	text As %String = "")
{
    Quit:'..Durable
    Quit:text=""
    Set ^RLM.Trace(..RunId, seq, "t") = text
}

/// The format version of a recorded run. A trace with no version node was written
/// before versions existed, so it is version 1 -- not "", which would make a
/// version check pass by accident and report the wrong number.
ClassMethod Version(
	runId As %Integer,
	durable As %Boolean = 0) As %Integer
{
    If durable { Quit +$Get(^RLM.Trace(runId, "v"), 1) }
    Quit +$Get(^||RLM.Trace(runId, "v"), 1)
}

/// The store fingerprint recorded for a run, or "" if none was.
ClassMethod Fingerprint(
	runId As %Integer,
	durable As %Boolean = 0) As %String
{
    If durable { Quit $Get(^RLM.Trace(runId, "fp")) }
    Quit $Get(^||RLM.Trace(runId, "fp"))
}

/// The question a run was given.
ClassMethod Question(
	runId As %Integer,
	durable As %Boolean = 0) As %String
{
    If durable { Quit $Get(^RLM.Trace(runId, "q")) }
    Quit $Get(^||RLM.Trace(runId, "q"))
}

/// The model output recorded for one row, or "" if none was.
ClassMethod TextAt(
	runId As %Integer,
	seq As %Integer,
	durable As %Boolean = 0) As %String
{
    If durable { Quit $Get(^RLM.Trace(runId, seq, "t")) }
    Quit $Get(^||RLM.Trace(runId, seq, "t"))
}

/// A cheap, store-derived figure that changes when the store changes.
///
/// A CRC-32 chain over the peek JSON of the root and of each first-level slice,
/// in the store's own declaration order. Chained rather than summed, so order
/// matters and two slices swapping figures does not cancel out.
///
/// It fingerprints the *peeks*, not the data, and the difference is the honest
/// limitation of the whole replay guarantee: a mutation that leaves every
/// aggregate identical -- swapping two equal-length values between slices -- does
/// not move this number. That is also exactly the granularity the claim needs. A
/// decision is a function of the peeks, so if no peek figure moved, no decision
/// could have moved, and the replay is sound.
///
/// The alternative, hashing the store itself, is an uncapped walk -- the one
/// thing this package exists not to do.
ClassMethod StoreFingerprint(source As RLM.Source) As %String
{
    Set crc = 0
    Try {
        Set crc = $ZCRC(crc_$ZCRC(..PeekJson(source, ""), 7), 7)
        Set dims = source.Dimensions("")
        If $IsObject(dims) {
            Set it = dims.%GetIterator()
            While it.%GetNext(.dim, .spec) {
                Continue:'$IsObject(spec)
                Continue:'$IsObject(spec.children)
                Set kids = spec.children.%GetIterator()
                While kids.%GetNext(.ki, .child) {
                    Continue:'$IsObject(child)
                    Set pred = source.Predicate($ListBuild(dim_":"_child.token))
                    Set crc = $ZCRC(crc_$ZCRC(..PeekJson(source, pred), 7), 7)
                }
            }
        }
    } Catch e {
        // A store that cannot be fingerprinted is not a run that cannot proceed.
        // The run records no fingerprint and a later replay refuses for the
        // honest reason -- it has nothing to compare against -- rather than the
        // run failing here over a figure nobody has asked for yet.
        //
        // Assigned rather than returned: `Quit <value>` is #1043 inside a Catch.
        Set crc = ""
    }
    Quit crc
}

/// One slice's peek as a JSON string, or its error text.
///
/// %DynamicObject preserves insertion order in %ToJSON(), and every source builds
/// its peek from a literal code path, so the serialization is stable enough to
/// hash. UnitTest.RLM.SourceGlobal's TestPeekingTwiceIsIdentical is the assertion
/// that keeps it that way.
ClassMethod PeekJson(
	source As RLM.Source,
	predicate As %String) As %String [ Private ]
{
    Set peek = source.Peek(predicate)
    If '$IsObject(peek) { Quit "(no peek)" }
    Quit peek.%ToJSON()
}

/// Append a row.
///
/// `role` is one of plan / subcall / synthesis / refused / capped. `metrics` is
/// an optional %DynamicObject of per-source figures, kept out of the $LIST row
/// because what a store measures is the store's business, not the trace's.
Method Add(
	role As %String,
	depth As %Integer = 0,
	sliceKey As %String = "",
	sourceClass As %String = "",
	splitMetric As %Numeric = "",
	tokensIn As %Integer = "",
	tokensOut As %Integer = "",
	model As %String = "",
	capped As %Boolean = 0,
	note As %String = "") As %Integer
{
    // $Increment cannot take an object property.
    Set seq = ..Seq + 1
    Set ..Seq = seq
    Set row = $ListBuild(role, depth, sourceClass, sliceKey, splitMetric,
        capped, tokensIn, tokensOut, model, note)
    If ..Durable {
        Set ^RLM.Trace(..RunId, seq) = row
    } Else {
        Set ^||RLM.Trace(..RunId, seq) = row
    }
    Quit seq
}

/// Append a split decision: a `decision` row plus a subtree holding the detail.
///
/// The detail is a sidecar rather than an eleventh field of the $LIST row. A
/// candidate list is variable-length and a $LIST row is positional, and
/// `$List(row, 11)` on a row written before this feature returns "" rather than
/// failing -- a silent wrong answer. Subscripts also make enumerating the
/// alternative arms a plain $Order walk, which is the operation offline
/// re-scoring is built on.
Method AddDecision(
	decision As RLM.Decision,
	depth As %Integer = 0,
	sourceClass As %String = "",
	sliceKey As %String = "") As %Integer
{
    Set note = $Select(decision.Chose():"split on "_decision.Dimension,
        1:"not decomposed")
    Set seq = ..Add("decision", depth, sliceKey, sourceClass,
        decision.MetricBefore, , , , decision.Capped, note)
    Set side = $ListBuild(decision.Dimension, decision.Reason,
        decision.MetricBefore, decision.MetricAfter, decision.PolicyClass,
        decision.PeeksSpent, decision.Capped)
    Do ..SetNode($ListBuild(seq, "d"), side)
    For i = 1:1:decision.Candidates.Count() {
        Set c = decision.Candidates.GetAt(i)
        Set row = $ListBuild(c.Dimension, c.Score, c.Children, c.Sampled, c.Error)
        Do ..SetNode($ListBuild(seq, "d", "cand", i), row)
        If c.ChildMetrics '= "" {
            Do ..SetNode($ListBuild(seq, "d", "cand", i, "m"), c.ChildMetrics)
        }
    }
    Quit seq
}

/// Record what a decision actually cost the budget, as measured rather than as
/// self-reported.
///
/// `RLM.Decision.PeeksSpent` is the policy's own account of its peeks and carries
/// no calls at all, so it cannot tell a replay how much budget to spend to arrive
/// at the same report. The figures here are budget deltas measured around the
/// policy call, which is the only account that matches the "Spent ..." line a
/// report ends with.
///
/// A sidecar subscript, not an eighth field of the decision's $LIST: `$List(side,
/// 8)` on a decision written before this feature returns "" rather than failing,
/// and a replay reading "" as zero cost would silently produce a report with
/// different figures.
Method SetDecisionCost(
	seq As %Integer,
	calls As %Integer,
	peeks As %Integer)
{
    Quit:'..Durable
    Do ..SetNode($ListBuild(seq, "d", "b"), $ListBuild(calls, peeks))
}

/// What a recorded decision cost, as `$LB(calls, peeks)`, or "" if unrecorded.
ClassMethod DecisionCost(
	runId As %Integer,
	seq As %Integer,
	durable As %Boolean = 0) As %List
{
    If durable { Quit $Get(^RLM.Trace(runId, seq, "d", "b")) }
    Quit $Get(^||RLM.Trace(runId, seq, "d", "b"))
}

/// Write one sidecar node at the given subscript path.
///
/// The path is a %List rather than positional arguments because the tree is four
/// and five levels deep in places, and because $Select cannot choose between two
/// global references -- `^||` parses as an extended reference, not a value -- so
/// every write would otherwise need its own If/Else at its own depth.
Method SetNode(path As %List, value As %String) [ Private ]
{
    Set ref = $Select(..Durable:"^RLM.Trace(", 1:"^||RLM.Trace(")_..RunId
    Set ptr = 0
    While $ListNext(path, ptr, sub) {
        Set ref = ref_","_$Select(sub'?1.N:""""_sub_"""", 1:sub)
    }
    Set @(ref_")") = value
}

/// Rebuild the decisions of a run as RLM.Decision objects.
///
/// This is the reader User Story 3 exists for: a finished run can be re-scored
/// against the dimensions it did not choose without anyone hand-parsing a $LIST
/// row. Output `seqs` maps ordinal -> trace seq, so a caller can get back to the
/// row a decision came from.
ClassMethod Decisions(
	runId As %Integer,
	durable As %Boolean = 0,
	Output seqs) As %ListOfObjects
{
    Kill seqs
    Set out = ##class(%ListOfObjects).%New()
    Set seq = ""
    For  {
        If durable { Set seq = $Order(^RLM.Trace(runId, seq)) }
        Else { Set seq = $Order(^||RLM.Trace(runId, seq)) }
        Quit:seq=""
        // Rows are numeric subscripts; "fp", "q" and "v" are not rows and collate
        // after every row. See the format note in the class comment.
        Quit:seq'?1.N
        If durable { Set has = $Data(^RLM.Trace(runId, seq, "d")) }
        Else { Set has = $Data(^||RLM.Trace(runId, seq, "d")) }
        Continue:'has
        If durable { Set side = ^RLM.Trace(runId, seq, "d") }
        Else { Set side = ^||RLM.Trace(runId, seq, "d") }
        Set d = ##class(RLM.Decision).%New($List(side, 5), $List(side, 3))
        If $List(side, 1) = "" {
            Do d.Decline($List(side, 2))
        } Else {
            Do d.Choose($List(side, 1), $List(side, 4), $List(side, 2))
        }
        Set d.PeeksSpent = $List(side, 6)
        Set d.Capped = $List(side, 7)
        Set n = ""
        For  {
            If durable { Set n = $Order(^RLM.Trace(runId, seq, "d", "cand", n)) }
            Else { Set n = $Order(^||RLM.Trace(runId, seq, "d", "cand", n)) }
            Quit:n=""
            If durable { Set row = ^RLM.Trace(runId, seq, "d", "cand", n) }
            Else { Set row = ^||RLM.Trace(runId, seq, "d", "cand", n) }
            Set c = d.AddCandidate($List(row, 1), $List(row, 2), $List(row, 3),
                $List(row, 4))
            Set c.Error = $List(row, 5)
            If durable { Set m = $Get(^RLM.Trace(runId, seq, "d", "cand", n, "m")) }
            Else { Set m = $Get(^||RLM.Trace(runId, seq, "d", "cand", n, "m")) }
            Set c.ChildMetrics = m
        }
        Do out.Insert(d)
        Set seqs(out.Count()) = seq
    }
    Quit out
}

/// How many rows a finished run wrote.
///
/// A class method over a run id, like Decisions and RLM.Report.RenderTrace: the
/// caller that wants to know whether a rendering dropped a row has the id and the
/// global, not the engine that made them.
ClassMethod RowCount(
	runId As %Integer,
	durable As %Boolean = 0) As %Integer
{
    Set n = 0, seq = ""
    For  {
        If durable { Set seq = $Order(^RLM.Trace(runId, seq)) }
        Else { Set seq = $Order(^||RLM.Trace(runId, seq)) }
        Quit:seq=""
        // The metadata subscripts are not rows. Counting them would make a run
        // report three more rows than it wrote the moment it became durable.
        Quit:seq'?1.N
        Set n = n + 1
    }
    Quit n
}

/// Read one row back, for assertions and for replay.
Method Row(seq As %Integer) As %List
{
    If ..Durable { Quit $Get(^RLM.Trace(..RunId, seq)) }
    Quit $Get(^||RLM.Trace(..RunId, seq))
}

/// How many model calls this run recorded in a given role, or in total.
Method Count(role As %String = "") As %Integer
{
    Set n = 0, seq = ""
    For  {
        Set row = ..Row($Increment(seq))
        Quit:row=""
        If (role = "") || ($List(row, 1) = role) { Set n = n + 1 }
    }
    Quit n
}

}
