/// The M0 phase gate: a whole decomposition over a real SQL table.
///
/// Everything below the engine is genuine -- IRIS computes the aggregates over
/// rows that are never copied out of the database. Only the language model is
/// scripted, because a real one would make the assertions probabilistic.
///
/// What this proves that the unit tests cannot: RLM.Engine, RLM.Slice,
/// RLM.Source.Table, RLM.Budget, RLM.Trace and RLM.Report compose, and the
/// composition holds the invariant that matters -- the model sees aggregates and
/// a menu, never rows.
Class UnitTest.RLM.EndToEnd Extends %UnitTest.TestCase
{

Property Source As RLM.Source;

/// Repopulated per test rather than once per suite: two tests here grow the table
/// deliberately, and a test that inherits the previous one's rows fails for a
/// reason that has nothing to do with what it asserts.
Method OnBeforeOneTest(testname As %String) As %Status
{
    Set sc = ##class(UnitTest.RLM.Widget).Populate()
    If $$$ISERR(sc) { Quit sc }
    Set ..Source = ##class(RLM.Source.Table).%New("UnitTest.RLM.Widget", "Price")
    Do ..Source.AddDimension("colour", "Colour")
    Do ..Source.AddDimension("size", "Size")
    Quit $$$OK
}

Method TestDecomposesARealTable()
{
    // The model now names a dimension rather than a list of slices; the engine
    // expands it into one slice per child, so every name it resolves is one the
    // store itself generated.
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild(
        "colour",
        "The six red widgets sit between 9 and 12.",
        "The four blue widgets sit between 96 and 104.",
        "Colour separates price: red 9-12, blue 96-104."))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Set report = engine.Run("what drives price?", .traceId)

    Do $$$AssertEquals(llm.Calls, 4, "decision + 2 sub-calls + synthesis")

    // Figures the model was given must be the database's, not the fixture's.
    Do $$$AssertNotEquals($Find(report, "n=10"), 0, "store-wide count is real")
    Do $$$AssertNotEquals($Find(report, "n=6"), 0, "red slice count is real")
    Do $$$AssertNotEquals($Find(report, "n=4"), 0, "blue slice count is real")
    Do $$$AssertNotEquals($Find(report, "Colour separates price"), 0, "answer present")
}

/// The invariant, checked against a real store rather than a fixture: not one
/// row value may appear in any prompt the model received.
Method TestNoRowEverReachesTheModel()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild(
        "colour", "red note", "blue note", "answer"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Do engine.Run("what drives price?", .traceId)

    // 104 is a Price value held by exactly one row and is not any aggregate of
    // the red slice, so finding it in the red sub-call prompt would mean row
    // data crossed the boundary.
    //
    // The prompt is located by content rather than by ordinal: the store's child
    // order comes from SELECT DISTINCT and is the database's business, so a test
    // that hard-codes which call was red asserts on collation order by accident.
    Set redPrompt = ""
    For i = 1:1:llm.Calls {
        If $Find(llm.PromptAt(i), "n=6") { Set redPrompt = llm.PromptAt(i)  Quit }
    }
    Do $$$AssertNotEquals(redPrompt, "", "the red slice was asked about")
    Set leak = $Find(redPrompt, "104")
    Do $$$AssertEquals(leak, 0, "no individual price reaches the sub-call")
    Do $$$AssertNotEquals($Find(redPrompt, "n=6"), 0, "only the aggregate does")
}

/// The prompt the model sees must not grow with the table. This is the claim
/// that distinguishes the package from loading a table into a REPL, so it is
/// measured rather than asserted rhetorically.
Method TestPromptSizeIsIndependentOfRowCount()
{
    Set small = ..PlanPromptLength()
    // Ten times the rows, same two colours and two sizes.
    For i = 1:1:9 { Do ..Duplicate() }
    Set large = ..PlanPromptLength()
    Do $$$AssertEquals(large, small, "100 rows produce the same plan prompt as 10")
}

Method PlanPromptLength() As %Integer
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("none", "answer"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Do engine.Run("q", .t)
    // The store-wide count is the one figure that legitimately changes with row
    // count; blank it so the comparison is about structure, not digits.
    Quit $Length($Replace(llm.PromptAt(1), "n="_..Source.Peek("").n, "n=N"))
}

Method Duplicate() As %Status
{
    Set rs = ##class(RLM.Source.Table).Query("SELECT Colour, Size, Price FROM UnitTest_RLM.Widget", .sc)
    Set rows = ""
    While rs.%Next() {
        Set rows = rows_$ListBuild(rs.%Get("Colour")_"|"_rs.%Get("Size")_"|"_rs.%Get("Price"))
    }
    Set ptr = 0
    While $ListNext(rows, ptr, row) {
        Set w = ##class(UnitTest.RLM.Widget).%New()
        Set w.Colour = $Piece(row, "|", 1)
        Set w.Size = $Piece(row, "|", 2)
        Set w.Price = $Piece(row, "|", 3)
        Do w.%Save()
    }
    Quit $$$OK
}

/// The trace must account for every model call, because offline evaluation reads
/// the trace and not the report.
Method TestTraceAccountsForEveryCall()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("colour", "red", "blue", "answer"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Do engine.Run("q", .traceId)

    Set roles = ..Roles(traceId)
    // A `decision` row now stands where `plan` did. There is no `refused` row
    // because the engine generates the slice names from the store's own children,
    // so a name the store will refuse can no longer be produced -- the failure
    // mode the old assertion guarded is gone rather than untested.
    Do $$$AssertEquals(roles, "decision,subcall,subcall,synthesis", "every step recorded")
}

/// US1 phase gate. The claim of the feature, measured: the same store decomposed
/// with no model call spent on navigation.
Method TestGreedyRunSpendsNoModelCallOnNavigation()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("red", "blue", "answer"))
    Set budget = ##class(RLM.Budget).%New(8)
    Set engine = ##class(RLM.Engine).%New(..Source, llm, budget,
        ##class(RLM.Policy.Greedy).%New())
    Set report = engine.Run("what drives price?", .traceId)

    Do $$$AssertEquals(llm.Calls, 3, "2 sub-calls + synthesis, and nothing else")
    Set roles = ..Roles(traceId)
    Do $$$AssertEquals(roles, "decision,subcall,subcall,synthesis", "decision recorded")
    Do $$$AssertTrue(budget.PeeksUsed > 0, "it paid in peeks instead")
    Do $$$AssertNotEquals($Find(report, "n=6"), 0, "and reached the same slices")
    Do $$$AssertNotEquals($Find(report, "n=4"), 0, "both of them")
}

/// SC-001, stated as a comparison rather than an absolute: the same store, the
/// same slices, one fewer model call.
Method TestGreedyCostsOneFewerModelCallThanTheModelPolicy()
{
    Set a = ##class(RLM.LLM.Null).%New($ListBuild("colour", "red", "blue", "answer"))
    Set ea = ##class(RLM.Engine).%New(..Source, a)
    Do ea.Run("what drives price?", .ta)

    Set b = ##class(RLM.LLM.Null).%New($ListBuild("red", "blue", "answer"))
    Set eb = ##class(RLM.Engine).%New(..Source, b, , ##class(RLM.Policy.Greedy).%New())
    Do eb.Run("what drives price?", .tb)

    Do $$$AssertEquals(b.Calls, a.Calls - 1, "one fewer model call for the same work")
}

/// A store nothing separates must produce an answer that says so, not a
/// decomposition that quietly examined nothing.
Method TestUndecomposableStoreSaysSoInTheReport()
{
    Set flat = ##class(UnitTest.RLM.FixtureFlat).%New()
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("nothing separates this store"))
    Set engine = ##class(RLM.Engine).%New(flat, llm, ,
        ##class(RLM.Policy.Greedy).%New())
    Set report = engine.Run("q", .traceId)

    Do $$$AssertEquals(llm.Calls, 1, "synthesis only")
    Do $$$AssertNotEquals($Find(report, "Not decomposed"), 0, "the reader is told")
    Set why = $Find(report, "no dimension reduced the metric")
    Do $$$AssertNotEquals(why, 0, "and told why")
}

/// US3 phase gate, and SC-003. After a real run over a real table, the arms the
/// policy did not take must be recoverable from the trace and the store alone.
///
/// The engine object is discarded before anything is read, because the reader
/// this exists for has a run id and a database, not a live engine. And the
/// unchosen arm is not merely listed but re-peeked: a name that cannot be turned
/// back into a predicate is a label, not evidence, and re-scoring needs evidence.
Method TestAlternativeArmsAreRecoverableFromTraceAlone()
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("red", "blue", "answer"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm, ,
        ##class(RLM.Policy.Greedy).%New())
    Do engine.Run("what drives price?", .traceId)
    Kill engine

    Set decisions = ##class(RLM.Trace).Decisions(traceId, 0, .seqs)
    Do $$$AssertEquals(decisions.Count(), 1, "the run's one decision is there")
    Set d = decisions.GetAt(1)
    Do $$$AssertEquals(d.Dimension, "colour", "which arm was taken")
    Do $$$AssertEquals(d.Candidates.Count(), 2, "and which were available")

    // Find the arm that was not chosen, whatever order the store offered them in.
    Set other = ""
    For i = 1:1:d.Candidates.Count() {
        Set cand = d.Candidates.GetAt(i)
        If cand.Dimension '= d.Dimension { Set other = cand }
    }
    Do $$$AssertTrue($IsObject(other), "the road not taken is on the record")
    Do $$$AssertNotEquals(other.Score, "", "already scored, without a model call")

    // Re-peek it from the store. A fresh Source, to prove the trace plus the
    // store is sufficient and the run's own objects are not needed.
    Set source = ##class(RLM.Source.Table).%New("UnitTest.RLM.Widget", "Price")
    Do source.AddDimension("colour", "Colour")
    Do source.AddDimension("size", "Size")
    Set token = $Piece($ListGet(other.ChildMetrics, 1), ":", 1)
    Set peek = source.Peek(source.Predicate($ListBuild(other.Dimension_":"_token)))
    Do $$$AssertEquals(peek.error, "", "the unchosen arm re-peeks cleanly")
    Set n = $Piece($ListGet(other.ChildMetrics, 1), ":", 2)
    Do $$$AssertEquals(+peek.n, +n, "and returns what the trace said it would")
    Do $$$AssertEquals(llm.Calls, 3, "and none of this cost a model call")
}

/// FR-009. A run that decomposed nothing must still record why, or the trace of a
/// declined split is indistinguishable from a trace that failed to write.
Method TestDeclinedSplitIsStillATracedDecision()
{
    Set flat = ##class(UnitTest.RLM.FixtureFlat).%New()
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("answer"))
    Set engine = ##class(RLM.Engine).%New(flat, llm, ,
        ##class(RLM.Policy.Greedy).%New())
    Do engine.Run("q", .traceId)

    Set decisions = ##class(RLM.Trace).Decisions(traceId)
    Do $$$AssertEquals(decisions.Count(), 1, "the decision not to split is recorded")
    Set d = decisions.GetAt(1)
    Do $$$AssertNotTrue(d.Chose(), "as a decline")
    Do $$$AssertNotEquals(d.Reason, "", "with its reason")
    Do $$$AssertEquals(d.Candidates.Count(), 2, "and the arms it rejected")
}

/// US2 phase gate, and SC-004. The report the LLM policy produces from a given
/// set of scripted replies must be the one the pre-feature engine produced from
/// the same replies -- byte for byte, not "equivalent".
///
/// The expected text below was captured from the engine before RLM.Policy
/// existed. Asserting on the whole document rather than on parts of it is
/// deliberate: a caveat that quietly appears or a heading that quietly changes
/// width is exactly the kind of drift a spot-check misses, and the report is what
/// a reader is given.
Method TestLLMPolicyReportIsUnchanged()
{
    Set fixture = ##class(UnitTest.RLM.Fixture).%New("fixture store")
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild(
        "color", "red is tight", "blue is tight",
        "colour separates the population"))
    Set engine = ##class(RLM.Engine).%New(fixture, llm)
    Set report = engine.Run("what separates this store?", .traceId)

    Do $$$AssertEquals(report, ..Baseline(), "byte-identical to the pre-feature run")
}

/// US3 phase gate, and SC-004. The same run, rendered twice: every figure and
/// every caveat in one is in the other.
///
/// Compared as sets of extracted numbers and caveat lines rather than as text,
/// because the two documents are supposed to differ in punctuation -- comparing
/// them literally would either fail always or require encoding the formatting
/// rules into the test, which asserts the implementation against itself.
Method TestBothStylesCarryTheSameFacts()
{
    Set plain = ..RunStyled("plain", .pt)
    Set md = ..RunStyled("markdown", .mt)

    Do $$$AssertEquals(..Numbers(md), ..Numbers(plain), "every figure survives")
    Do $$$AssertEquals(..CaveatLines(md), ..CaveatLines(plain), "and every caveat")
    Do $$$AssertNotEquals($Find(md, "## "), 0, "markdown really is markdown")
    Do $$$AssertEquals($Find(plain, "## "), 0, "and plain really is not")
}

/// One run at a given style. Scripted replies are identical between calls, so the
/// only difference between the two documents is the rendering.
Method RunStyled(
	style As %String,
	Output traceId As %Integer) As %String
{
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild(
        "colour", "red note", "blue note", "answer"))
    Set engine = ##class(RLM.Engine).%New(..Source, llm)
    Set engine.ReportStyle = style
    Quit engine.Run("what drives price?", .traceId)
}

/// Every run of digits in a document, comma-joined in order of appearance. A
/// figure that changed, moved or vanished between styles changes this string.
ClassMethod Numbers(text As %String) As %String
{
    Set out = "", n = ""
    For i = 1:1:$Length(text) {
        Set c = $Extract(text, i)
        If (c ? 1N) || ((c = ".") && (n '= "")) { Set n = n_c  Continue }
        If n '= "" { Set out = out_$Select(out="":"", 1:",")_n, n = "" }
    }
    Quit out_$Select(n="":"", 1:$Select(out="":"", 1:",")_n)
}

/// The caveat lines of a document, stripped of bullet punctuation so the two
/// styles are comparable.
ClassMethod CaveatLines(text As %String) As %String
{
    Set out = "", inCaveats = 0
    For i = 1:1:$Length(text, $Char(10)) {
        Set line = $Piece(text, $Char(10), i)
        If $Find(line, "Limits of this analysis") { Set inCaveats = 1  Continue }
        Continue:'inCaveats
        Set stripped = $ZStrip(line, "<>W")
        Continue:stripped=""
        // Plain style underlines its heading with a rule of dashes and Markdown
        // does not. That is the formatting difference this comparison is supposed
        // to be blind to.
        Continue:$Translate(stripped, "-")=""
        // Both styles bullet with "- ", but strip it anyway: what is being compared
        // is the sentence, not the marker.
        If $Extract(stripped, 1, 2) = "- " { Set stripped = $Extract(stripped, 3, *) }
        Set out = out_$Select(out="":"", 1:$Char(10))_stripped
    }
    Quit out
}

/// US2 phase gate, and SC-003. A bucketed dimension over a continuous column at
/// scale: the declared number of children, every one of them reached, and the
/// rows no bucket covers disclosed rather than absorbed.
///
/// Ten thousand rows rather than ten, because bucketing is the feature whose cost
/// could plausibly scale with the data -- one range query per child is the claim,
/// and a per-row loop would pass every smaller test.
Method TestBucketedDimensionAtScale()
{
    Do ..Inflate(10000)
    Set source = ##class(RLM.Source.Table).%New("UnitTest.RLM.Widget", "Price")
    Do source.AddDimension("colour", "Colour")
    Do source.AddBucketedDimension("rating", "Rating", $ListBuild(3, 7))

    Set llm = ##class(RLM.LLM.Null).%New($ListBuild(
        "rating", "low band", "mid band", "high band", "answer"))
    Set engine = ##class(RLM.Engine).%New(source, llm, ##class(RLM.Budget).%New(12))
    Set report = engine.Run("what does rating separate?", .traceId)

    Do $$$AssertEquals(llm.Calls, 5, "decision + three buckets + synthesis")
    Do $$$AssertNotEquals($Find(report, "Rating < 3"), 0, "the low bucket is named")
    Do $$$AssertNotEquals($Find(report, "Rating [3,7)"), 0, "and the middle one")
    Do $$$AssertNotEquals($Find(report, "Rating >= 7"), 0, "and the high one")
    Set gap = $Find(report, "no bucket")
    Do $$$AssertNotEquals(gap, 0, "and the rows in no bucket are disclosed")

    // SC-003 as figures rather than as an existence claim. Rows, children and calls
    // together are the measurement: three children over ten thousand rows for five
    // model calls is the claim, and a per-row implementation would show the same
    // three children while the peek count told a different story.
    Set rows = source.Peek("").n
    Set nulls = source.NullCount("", "rating")
    // Hoisted for the one-line-macro rule, same as every $$$Assert* here.
    Set msg = "SC-003: "_rows_" rows bucketed into 3 children with "_llm.Calls
        _" model calls; "_nulls_" rows in no bucket, disclosed"
    Do $$$LogMessage(msg)
    Do $$$AssertTrue(rows >= 10000, "measured over ten thousand rows, not ten")
}

/// Grow the table to `target` rows, cycling Rating through every bucket and
/// through null. Written as one INSERT per row deliberately: the shape of the
/// data matters to the assertions above and a bulk copy would not give the null
/// rows a predictable share.
Method Inflate(target As %Integer) As %Status
{
    Set ratings = $ListBuild(1, 3, 5, 7, 9, "")
    For i = 1:1:target {
        Set w = ##class(UnitTest.RLM.Widget).%New()
        Set w.Colour = $Select(i # 2:"red", 1:"blue")
        Set w.Size = $Select(i # 3:"small", 1:"large")
        Set w.Price = 10 + (i # 90)
        Set w.Rating = $ListGet(ratings, (i # 6) + 1)
        Set sc = w.%Save()
        If $$$ISERR(sc) { Quit }
    }
    Quit $Get(sc, $$$OK)
}

/// US5 phase gate, and SC-006. A store that says it is unfit costs nothing.
///
/// Zero model calls is the assertion that matters and it is asserted on the
/// provider's own counter rather than on the report: a run that produced the right
/// refusal text after paying for a synthesis call has still spent a slot, and at
/// scale that is the difference between a cheap refusal and an expensive one.
///
/// The scripted LLM is given an empty script deliberately. Any call at all becomes
/// an unscripted-call error, so a regression that reintroduces a call fails loudly
/// rather than producing a plausible document.
Method TestNotReadyStoreCostsNothingAndSaysWhy()
{
    Set stale = ##class(UnitTest.RLM.FixtureNotReady).%New("nightly load")
    Set llm = ##class(RLM.LLM.Null).%New("")
    Set engine = ##class(RLM.Engine).%New(stale, llm)
    Set report = engine.Run("what drives price?", .traceId)

    Do $$$AssertEquals(llm.Calls, 0, "not one model call was spent")
    Set why = $Find(report, "3 of 12 partitions are absent")
    Do $$$AssertNotEquals(why, 0, "the store's own reason reaches the reader")
    Do $$$AssertNotEquals($Find(report, "what drives price?"), 0, "and the question")
    // No figures: a refusal that still reports a count invites the reader to use it.
    Do $$$AssertEquals($Find(report, "n="), 0, "and no statistic is presented")
}

/// The pre-feature report, held as data so the comparison above is a comparison
/// and not a re-derivation.
ClassMethod Baseline() As %String
{
    Set nl = $Char(10)
    Quit "Question"_nl_"--------"_nl
        _"what separates this store?"_nl_nl
        _"Store"_nl_"-----"_nl
        _"fixture store: n=1000, metric=0.90"_nl_nl
        _"Slices examined"_nl_"---------------"_nl
        _"- red [red: n=600, metric=0.20] red is tight"_nl
        _"- blue [blue: n=400, metric=0.25] blue is tight"_nl_nl
        _"Answer"_nl_"------"_nl
        _"colour separates the population"_nl_nl
        _"Limits of this analysis"_nl_"-----------------------"_nl
        // No trailing newline: RLM.Report joins its lines and does not terminate
        // the last one.
        _"- Spent 4/8 model calls."
}

Method Roles(traceId As %Integer) As %String
{
    Set roles = "", seq = ""
    For  {
        Set seq = $Order(^||RLM.Trace(traceId, seq), 1, row)
        Quit:seq=""
        Set roles = roles_$Select(roles="":"", 1:",")_$List(row, 1)
    }
    Quit roles
}

}
