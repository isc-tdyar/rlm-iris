/// The traversal: what order slices are visited in, what depth reaches the trace,
/// and what the engine refuses to spend.
///
/// Every test here runs over an in-memory fixture with a scripted model, so the
/// assertions are exact. The traversal is the one part of the engine where an
/// off-by-one is invisible in the report -- a missing depth-2 slice reads as a
/// store with nothing deeper in it -- so it is asserted against the trace rather
/// than against the document.
///
/// The assertion macros are called on one source line throughout, because
/// $$$macro(...) cannot span lines in ObjectScript: a wrapped call compiles into
/// a syntax error and %UnitTest then skips the whole class while still reporting
/// "All PASSED".
Class UnitTest.RLM.EngineRecursion Extends %UnitTest.TestCase
{

Property Source As RLM.Source;

Method OnBeforeOneTest(testname As %String) As %Status
{
    Set ..Source = ##class(UnitTest.RLM.FixtureNested).%New()
    Quit $$$OK
}

/// The shape of a depth-2 run, in one assertion: pre-order, one decision per
/// decided slice, sub-calls only at the leaves.
Method TestDepthTwoVisitsPreOrder()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild(
        "red small", "red large", "blue", "answer"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm, ##class(RLM.Budget).%New(16),
        ##class(RLM.Policy.Greedy).%New())
    Set engine.MaxDepth = 2
    Do engine.Run("what separates this store?", .traceId)

    Set want = "decision:0:,decision:1:color:red,subcall:2:color:red/size:small,"
        _"subcall:2:color:red/size:large,decision:1:color:blue,"
        _"subcall:1:color:blue,synthesis:0:"
    Do $$$AssertEquals(..Shape(traceId), want, "red's subtree in full, then blue")
}

/// Depth is field 2 of a trace row and has always been. It carried 0 or 1 only
/// because there was never a second level; a reader of field 2 must now get the
/// real depth without the field having moved.
Method TestDepthInTraceFieldTwo()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("a", "b", "c", "answer"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm, ##class(RLM.Budget).%New(16),
        ##class(RLM.Policy.Greedy).%New())
    Set engine.MaxDepth = 2
    Do engine.Run("q", .traceId)

    Do $$$AssertEquals(..Deepest(traceId), 2, "a depth-2 row exists and says 2")
}

/// FR-002. A dimension an ancestor already split on must not be offered again --
/// splitting twice on one dimension narrows nothing and the second decision is
/// paid for.
Method TestAncestorDimensionExcluded()
{
    Set c = ##class(RLM.Engine).%New(..Source, ##class(RLM.LLM.Null).%New(""))
    Set root = $ListToString(c.Candidates(""))
    Set inRed = $ListToString(c.Candidates("color:red"))
    Set below = $ListToString(c.Candidates("color:red/size:small"))
    Do $$$AssertEquals(root, "color,size", "both dimensions at the root")
    Do $$$AssertEquals(inRed, "size", "not colour again inside red")
    Do $$$AssertEquals(below, "", "and nothing left below that")
}

/// FR-003. A slice the store says is one population already must cost nothing to
/// leave alone. Asserted in peeks, because the cheap failure mode here is a
/// decision that declines *after* paying to find out.
Method TestUnsplitSliceCostsNoPeeks()
{
    Set budget = ##class(RLM.Budget).%New(16)
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("a", "b", "c", "answer"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm, budget,
        ##class(RLM.Policy.Greedy).%New())
    Set engine.MaxDepth = 2
    Do engine.Run("q", .traceId)

    // 4 to decide the root (two dimensions, two children each) + 2 to decide
    // within red (size only). Blue is clean at 0.10 and costs nothing.
    Do $$$AssertEquals(budget.PeeksUsed, 6, "no peek spent on the clean slice")
}

/// The decline still has to be on the record. A slice left alone and a slice the
/// traversal never reached look identical in a report, and only one of them is
/// something a reader should shrug at.
Method TestUnsplitSliceIsStillTraced()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("a", "b", "c", "answer"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm, ##class(RLM.Budget).%New(16),
        ##class(RLM.Policy.Greedy).%New())
    Set engine.MaxDepth = 2
    Do engine.Run("q", .traceId)

    Set decisions = ##class(RLM.Trace).Decisions(traceId, 0, .seqs)
    Do $$$AssertEquals(decisions.Count(), 3, "root, red, and blue's decline")
    Set blue = decisions.GetAt(3)
    Do $$$AssertNotTrue(blue.Chose(), "blue was not split")
    Do $$$AssertEquals(blue.Candidates.Count(), 0, "nothing was scored to say so")
    Do $$$AssertNotEquals(blue.Reason, "", "with a reason on the record")
}

/// FR-004 and FR-005. A budget that cannot fund the children of a split must stop
/// the traversal, and the slices it stopped short of must be named.
Method TestBudgetExhaustionDiscloses()
{
    // 3 total, 1 reserved: two exploration calls for three leaves.
    Set budget = ##class(RLM.Budget).%New(3)
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("a", "b", "answer"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm, budget,
        ##class(RLM.Policy.Greedy).%New())
    Set engine.MaxDepth = 2
    Set report = engine.Run("q", .traceId)

    Set told = $Find(report, "the call budget ran out")
    Set traced = $Find(..Shape(traceId), "capped")
    Do $$$AssertEquals(llm.Calls, 3, "two sub-calls and the reserved synthesis")
    Do $$$AssertNotEquals(told, 0, "the reader is told slices were dropped")
    Do $$$AssertNotEquals(traced, 0, "and the trace says which")
}

/// The grammar ceiling is the engine's to enforce. Letting RLM.Slice refuse the
/// path later works, but the refusal then reads as a store that does not offer a
/// slice it does offer.
///
/// The fixture declares two dimensions, so depth 3 is unreachable by exhaustion
/// rather than by the ceiling; asking for 9 proves the loop terminates on the
/// store's own structure and not on the limit.
Method TestGrammarCeilingRefused()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("a", "b", "c", "d", "answer"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm, ##class(RLM.Budget).%New(32),
        ##class(RLM.Policy.Greedy).%New())
    Set engine.MaxDepth = 9
    Do engine.Run("q", .traceId)

    Set refusals = $Find(..Shape(traceId), "refused")
    Do $$$AssertEquals(..Deepest(traceId), 2, "two dimensions cannot nest 3 deep")
    Do $$$AssertEquals(refusals, 0, "and nothing was refused getting there")
}

/// SC-002 at the unit level: MaxDepth = 1 must reproduce the pre-recursion
/// traversal exactly, on the same fixture the recursion tests use.
Method TestDefaultDepthUnchanged()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("red", "blue", "answer"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm, ,
        ##class(RLM.Policy.Greedy).%New())
    Do engine.Run("q", .traceId)

    Set want = "decision:0:,subcall:1:color:red,subcall:1:color:blue,synthesis:0:"
    Do $$$AssertEquals(..Shape(traceId), want, "one decision, flat children")
}

/// SC-001, as a measurement rather than as an existence claim.
///
/// "Recursion produces a tighter decomposition" is only meaningful as a number: a
/// depth-2 run that reached a second level but left its children no less mixed than
/// their parent has spent budget to produce more rows. So the two decisions'
/// after-metrics are compared, and both are logged -- a run that passes this by a
/// hair and a run that passes it by an order of magnitude are different results, and
/// the assertion alone cannot tell them apart.
Method TestDepthTwoTightensTheSliceAndReportsByHowMuch()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("a", "b", "c", "answer"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm, ##class(RLM.Budget).%New(16),
        ##class(RLM.Policy.Greedy).%New())
    Set engine.MaxDepth = 2
    Do engine.Run("q", .traceId)

    Set decisions = ##class(RLM.Trace).Decisions(traceId)
    Set root = "", child = ""
    For i = 1:1:decisions.Count() {
        Set d = decisions.GetAt(i)
        Continue:'d.Chose()
        If root = "" { Set root = d  Continue }
        If child = "" { Set child = d }
    }
    Do $$$AssertTrue($IsObject(root), "the root decided")
    Do $$$AssertTrue($IsObject(child), "and so did a slice below it")

    // Hoisted: a $$$macro(...) call cannot span source lines, and $$$LogMessage is
    // no exception -- a wrapped one compiles to #1026 and the whole class is skipped.
    Set msg = "SC-001: root split on '"_root.Dimension_"' left metric "
        _$FNumber(root.MetricAfter, "", 3)_"; '"_child.Dimension_"' below it left "
        _$FNumber(child.MetricAfter, "", 3)
    Do $$$LogMessage(msg)
    Do $$$AssertTrue(child.MetricAfter < root.MetricAfter, "the deeper split is tighter")
}

/// US4. Every peek in a scoped run is confined to the scope. This is a claim about
/// what the engine asked for rather than about what came back, so it is checked at
/// the store -- the only place that sees the questions.
Method TestScopedRunStaysInScope()
{
    Set src = ##class(UnitTest.RLM.FixtureRecording).%New()
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("a", "b", "answer"))
    Set engine = ##class(RLM.Engine).%New(src, llm, ##class(RLM.Budget).%New(16),
        ##class(RLM.Policy.Greedy).%New())
    Set engine.MaxDepth = 2
    Do engine.Run("q", .traceId, "color:red")

    Set ptr = 0, outside = ""
    While $ListNext(src.Peeked, ptr, p) {
        If $Extract(p, 1, 9) '= "color:red" { Set outside = outside_" "_p }
    }
    Do $$$AssertTrue($ListLength(src.Peeked) > 1, "the run peeked")
    Do $$$AssertEquals(outside, "", "and no peek left the scope")
}

/// FR-014. The report must say which subset it describes: red's figures presented
/// as the store's lead a reader to the wrong conclusion.
Method TestScopedRunNamesItsSubset()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("a", "b", "answer"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm, ##class(RLM.Budget).%New(16),
        ##class(RLM.Policy.Greedy).%New())
    Set engine.MaxDepth = 2
    Set report = engine.Run("q", .traceId, "color:red")

    Set named = $Find(report, "red")
    Set scoped = $Find(report, "n=600")
    Set whole = $Find(report, "n=1000")
    Do $$$AssertNotEquals(named, 0, "the scope is named in the report")
    Do $$$AssertNotEquals(scoped, 0, "and the figures are the scope's")
    Do $$$AssertEquals(whole, 0, "not the whole store's")
}

/// A scope the store does not offer is refused by the same code that refuses any
/// other bad slice name, and before any model call -- a refusal that costs a call
/// is a refusal that can exhaust a budget.
Method TestBadScopeCostsNoCall()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("never used"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm, ,
        ##class(RLM.Policy.Greedy).%New())
    Set report = engine.Run("q", .traceId, "shape:round")

    Set said = $Find(report, "was not run")
    Set which = $Find(report, "shape:round")
    Do $$$AssertEquals(llm.Calls, 0, "not one call was made")
    Do $$$AssertNotEquals(said, 0, "the report says it did not run")
    Do $$$AssertNotEquals(which, 0, "and names what it refused")
}

/// Roles, depths and slice keys of a run, as one comparable string. Reading three
/// fields at once is deliberate: role alone cannot distinguish a correct traversal
/// from one that visits the right slices at the wrong depths.
ClassMethod Shape(traceId As %Integer) As %String
{
    Set out = "", seq = ""
    For  {
        Set seq = $Order(^||RLM.Trace(traceId, seq), 1, row)
        Quit:seq=""
        Set out = out_$Select(out="":"", 1:",")
            _$List(row, 1)_":"_$List(row, 2)_":"_$List(row, 4)
    }
    Quit out
}

/// The greatest depth any row of a run recorded.
ClassMethod Deepest(traceId As %Integer) As %Integer
{
    Set deepest = 0, seq = ""
    For  {
        Set seq = $Order(^||RLM.Trace(traceId, seq), 1, row)
        Quit:seq=""
        If $List(row, 2) > deepest { Set deepest = $List(row, 2) }
    }
    Quit deepest
}

}
