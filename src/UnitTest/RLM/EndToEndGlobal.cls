/// The feature gate: a whole decomposition of a global with no schema.
///
/// Every other class in this suite tests one seam. This one asserts the thing the
/// milestone actually claims -- that you can point the engine at a global nobody
/// documented and get back a document whose figures reconcile, whose limits are
/// stated, and which is reproducible byte for byte.
///
/// It runs under RLM.LLM.Null, so nothing here depends on a provider, a network,
/// or a model's mood.
Class UnitTest.RLM.EndToEndGlobal Extends %UnitTest.TestCase
{

Method OnBeforeOneTest(testname As %String) As %Status
{
    Do ##class(UnitTest.RLM.FixtureGlobal).Build()
    Quit $$$OK
}

ClassMethod Source(ref As %String = "") As RLM.Source.Global
{
    Set r = $Select(ref = "": ##class(UnitTest.RLM.FixtureGlobal).#REF, 1: ref)
    Quit ##class(RLM.Source.Global).%New(r, "^||RLM*", .sc)
}

/// An engine over the fixture, choosing splits from the store's own statistics.
ClassMethod Engine(
	src As RLM.Source.Global,
	llm As RLM.LLM,
	calls As %Integer = 32) As RLM.Engine
{
    Set greedy = ##class(RLM.Policy.Greedy).%New()
    // A budget wide enough that nothing here is testing the budget. The default
    // of 8 is smaller than this fixture's slice count, so a run on the default
    // drops slices and every assertion below reads as a pass on a partial run.
    Set budget = ##class(RLM.Budget).%New(calls)
    Quit ##class(RLM.Engine).%New(src, llm, budget, greedy)
}

/// A Null model with enough scripted replies for a whole decomposition.
///
/// An unscripted RLM.LLM.Null errors on every call, and a run where every
/// sub-call failed still produces a report with all the right headings -- so a
/// test that only checks structure passes on a decomposition that did nothing.
/// The replies are identical to each other on purpose: nothing here asserts on
/// their content, and identical replies keep the byte-identity test honest.
ClassMethod Scripted(replies As %Integer = 24) As RLM.LLM.Null
{
    Set script = ""
    For i = 1:1:replies { Set script = script_$ListBuild("mostly pointer nodes, one value per leaf") }
    Quit ##class(RLM.LLM.Null).%New(script)
}

/// The whole run. The report names the slices it examined, states its limits, and
/// carries an answer -- the three things a reader came for.
Method TestAFullDecompositionOfAnUndocumentedGlobal()
{
    Set llm = ..Scripted()
    Set engine = ..Engine(..Source(), llm)
    Set report = engine.Run("what is in this global", .traceId)

    Do $$$AssertNotEquals(report, "", "a document came back")
    // First, that the run actually ran. Every heading below is present on a run
    // whose every sub-call failed, so this assertion comes before them.
    Do $$$AssertEquals($Find(report, "sub-call for"), 0, "no sub-call failed")
    // Exactly one call per child of the root plus one synthesis. The root itself
    // is never sub-called -- its statistics are already under "Store" -- and
    // Greedy decides without calling, so this number is fully determined by the
    // fixture's fanout and any other value means a call went somewhere unplanned.
    Set want = ##class(UnitTest.RLM.FixtureGlobal).RootChildren() + 1
    Do $$$AssertEquals(llm.Calls, want, "one call per child plus a synthesis")
    Do $$$AssertNotEquals($Find(report, "Slices examined"), 0, "with the slices it looked at")
    Do $$$AssertNotEquals($Find(report, "Answer"), 0, "and an answer")
    Do $$$AssertNotEquals($Find(report, "Limits of this analysis"), 0, "and its limits")

    // Every child of the root is named, by its raw subscript rather than by its
    // hex token -- a report naming four of five slices is a report whose figures
    // cannot be reconciled against the store.
    Set kids = ##class(UnitTest.RLM.FixtureGlobal).Children(), ptr = 0
    While $ListNext(kids, ptr, kid) {
        Set label = $Piece(kid, "|", 1)
        Do $$$AssertNotEquals($Find(report, label), 0, "the report names '"_label_"'")
    }
}

/// A decision per level the run descended, on the record. Without this the report
/// is an assertion and the trace is decoration.
Method TestTheTraceRecordsADecisionPerLevel()
{
    Set llm = ..Scripted()
    Set engine = ..Engine(..Source(), llm)
    Set engine.MaxDepth = 2
    Do engine.Run("what is in this global", .traceId)

    Set seq = "", decisions = 0, depths = ""
    For  {
        Set seq = $Order(^||RLM.Trace(traceId, seq))
        Quit:seq=""
        Set row = $Get(^||RLM.Trace(traceId, seq))
        If $ListGet(row, 1) = "decision" {
            Set decisions = decisions + 1
            Set depths = depths_$ListBuild($ListGet(row, 2))
        }
    }
    Do $$$AssertTrue(decisions > 1, "more than the root was decided")
    Do $$$AssertNotEquals($ListFind(depths, 0), 0, "the root decided")
    Do $$$AssertNotEquals($ListFind(depths, 1), 0, "and so did a depth-1 slice")
}

/// Constitution V. The same store, the same question, the same document. Any
/// clock, any hash iteration order, any unrounded float would break this.
Method TestTheRunIsByteIdenticalOnASecondExecution()
{
    Set first = ..Engine(..Source(), ..Scripted()).Run("what is here", .t1)
    Set second = ..Engine(..Source(), ..Scripted()).Run("what is here", .t2)
    Do $$$AssertEquals($Find(first, "sub-call for"), 0, "and both runs were complete")
    Do $$$AssertNotEquals(t1, t2, "two distinct runs")
    Do $$$AssertEquals(first, second, "producing identical documents")
}

/// A refused source costs nothing. The report states the refusal and the model is
/// never called -- so an operator who points this at ^ROUTINE by mistake has not
/// spent a token or read a byte.
Method TestARefusedSourceProducesAReportAndNoModelCall()
{
    Set src = ##class(RLM.Source.Global).%New("^ROUTINE", "^*", .sc)
    Do $$$AssertStatusNotOK(sc, "refused at construction")

    // %New discarded the object, so there is nothing to run. The refusal is the
    // caller's to report, and it carries the reason.
    Do $$$AssertNotTrue($IsObject(src), "and nothing was handed back")
    Set why = $System.Status.GetErrorText(sc)
    Do $$$AssertNotEquals($Find(why, "^ROUTINE"), 0, "the reason names the global")

    // The engine's own refusal path: a source that is ready but whose scope
    // cannot be resolved makes no call either.
    Set llm = ##class(RLM.LLM.Null).%New()
    Set engine = ..Engine(..Source(), llm)
    Set report = engine.Run("what is here", .traceId, "s1:NOTAHEXTOKEN")
    Do $$$AssertNotEquals($Find(report, "was not run"), 0, "the report states the refusal")
    Do $$$AssertEquals(llm.Calls, 0, "and no model call was made")
}

/// Constitution VI, checked rather than trusted. The portable module must compile
/// on an IRIS with no AI Hub, so the source of this class may not name %AI, may
/// not open a socket, and may not contain SQL.
Method TestTheGlobalSourceIsPortable()
{
    Set text = ..SourceTextOf("RLM.Source.Global")
    Do $$$AssertTrue($Length(text) > 1000, "the source was read at all")
    Do $$$AssertEquals(text [ "%AI.", 0, "no AI Hub dependency")
    Do $$$AssertEquals(text [ "%Net.", 0, "no network client")
    Do $$$AssertEquals(text [ "%SQL.Statement", 0, "no SQL statement")
    Do $$$AssertEquals(text [ "&sql", 0, "and no embedded SQL")
}

/// Read-only. A decomposition that mutated the store it was characterizing would
/// be a catastrophe on a production global, and "we never wrote any code that
/// writes" is not the same as checking.
Method TestTheStoreIsUnchangedByAFullRun()
{
    Set before = ..Fingerprint(##class(UnitTest.RLM.FixtureGlobal).#REF)
    Set engine = ..Engine(..Source(), ..Scripted())
    Set engine.MaxDepth = 3
    Do engine.Run("characterize everything", .traceId)
    Set after = ..Fingerprint(##class(UnitTest.RLM.FixtureGlobal).#REF)
    Do $$$AssertEquals(after, before, "every node and value is as it was")
}

/// Every node's reference and value, concatenated. Compares contents rather than
/// a count: a run that overwrote one value while adding none would pass a count.
ClassMethod Fingerprint(ref As %String) As %String
{
    Set out = "", node = ref
    For  {
        Set node = $Query(@node)
        Quit:node=""
        // Parenthesized: a postconditional expression ends at the first space, so
        // the unparenthesized form makes `'= ref` a Quit argument and a syntax error.
        Quit:($Extract(node,1,$Length(ref))'=ref)
        // The value is hoisted into its own Set: `@node_$Char(1)` reads as
        // indirection on the concatenation, not on `node`, and is a syntax error.
        Set val = @node
        Set out = out_node_"="_val_$Char(1)
    }
    Quit out
}

/// A class's source text, for the portability assertion.
ClassMethod SourceTextOf(class As %String) As %String
{
    Set def = ##class(%Dictionary.ClassDefinition).%OpenId(class)
    If '$IsObject(def) { Quit "" }
    Set out = ""
    For i = 1:1:def.Methods.Count() {
        Set m = def.Methods.GetAt(i)
        Set out = out_m.Implementation.Read(3000000)
        Do m.Implementation.Rewind()
    }
    Quit out
}

}
