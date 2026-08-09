/// Tests for the view seam.
///
/// What is being protected is a pair of claims that pull in opposite directions.
/// The statistics-only view must survive the widening exactly, because it is what
/// a governed store depends on and the guarantee it carries is absolute. And the
/// contents view must actually show records, because a decomposition whose leaves
/// are still summaries has not done the thing the recursion was for.
///
/// Between them sits the rule that keeps both true: contents are shown only when
/// the slice is small enough that showing them cannot break the context bound, and
/// every refusal to show them is disclosed rather than silently downgraded.
///
/// Every assertion sits on one line: a macro's arguments cannot span source lines,
/// so anything long is hoisted into a local first.
Class UnitTest.RLM.Lens Extends %UnitTest.TestCase
{

Property Source As RLM.Source;

Method OnBeforeOneTest(testname As %String) As %Status
{
	Set ..Source = ##class(UnitTest.RLM.FixtureContents).%New("contents store")
	Quit $$$OK
}

/// The default must be the old behaviour, not merely similar to it. A store under
/// a governance constraint gets aggregates because nobody chose otherwise.
Method TestEngineDefaultsToTheStatisticsLens()
{
	Set engine = ##class(RLM.Engine).%New(..Source, ##class(RLM.LLM.Null).%New(""))
	Do $$$AssertEquals(engine.Lens.Kind(), "stats", "aggregates unless asked otherwise")
}

/// The statistics view is Describe and nothing else. A lens that reworded the
/// aggregates would give the report and the trace two vocabularies for one figure.
Method TestStatsViewIsExactlyDescribe()
{
	Set lens = ##class(RLM.Lens.Stats).%New()
	Set peek = ..Source.Peek("batch:small")
	Set view = lens.View(..Source, "small", peek, "batch:small", .disclosed)
	Set want = ..Source.Describe("small", peek)

	Do $$$AssertEquals(view, want, "byte-for-byte Describe")
	Do $$$AssertEquals(disclosed, "", "a complete view discloses nothing")
}

/// The point of the whole exercise: a slice small enough to read is read.
Method TestContentsViewShowsTheRecords()
{
	Set lens = ##class(RLM.Lens.Contents).%New()
	Set peek = ..Source.Peek("batch:small")
	Set view = lens.View(..Source, "small", peek, "batch:small", .disclosed)

	Do $$$AssertNotEquals($Find(view, "id=1"), 0, "the first record is shown")
	Do $$$AssertNotEquals($Find(view, "id=3"), 0, "and the last")
	Do $$$AssertNotEquals($Find(view, "status=failed"), 0, "including the notable one")
	Do $$$AssertEquals(disclosed, "", "nothing withheld, so nothing disclosed")
}

/// A slice larger than the cap degrades to statistics rather than reading itself,
/// because reading it is what would break the context bound.
Method TestOversizedSliceFallsBackAndSaysSo()
{
	Set lens = ##class(RLM.Lens.Contents).%New(20)
	Set peek = ..Source.Peek("batch:big")
	Set view = lens.View(..Source, "big", peek, "batch:big", .disclosed)

	Do $$$AssertEquals($Find(view, "id="), 0, "no records reached the view")
	Do $$$AssertNotEquals($Find(view, "n=40"), 0, "the aggregate did")
	Do $$$AssertNotEquals(disclosed, "", "and the reader is told which view this is")
}

/// A capped count is a floor. Trusting it here is how a bounded walk becomes an
/// unbounded read, so `partial` must fall back despite its small number.
Method TestCappedSliceIsNeverReadEvenWhenItLooksSmall()
{
	Set lens = ##class(RLM.Lens.Contents).%New(20)
	Set peek = ..Source.Peek("batch:partial")
	Set fits = ..Source.Fits(peek, 20)
	Do $$$AssertNotTrue(fits, "5 records behind a cap is not 5 records")

	Set view = lens.View(..Source, "partial", peek, "batch:partial", .disclosed)
	Do $$$AssertEquals($Find(view, "id="), 0, "so it was not read")
	Do $$$AssertNotEquals(disclosed, "", "and the fallback is stated")
}

/// Truncation the peek did not predict is the one case where records are shown
/// *and* something is disclosed. Silence here would let the model read a partial
/// set as a complete one, which is Constitution II one level down from a count.
Method TestUnexpectedTruncationIsDisclosedWithTheRecords()
{
	Set lens = ##class(RLM.Lens.Contents).%New(2)
	Set peek = ..Source.Peek("batch:many")
	Set view = lens.View(..Source, "many", peek, "batch:many", .disclosed)

	Do $$$AssertNotEquals($Find(view, "id=10"), 0, "records are still shown")
	Do $$$AssertEquals($Find(view, "id=12"), 0, "but only up to the cap")
	Do $$$AssertNotEquals($Find(disclosed, "more records"), 0, "and the gap is named")
}

/// A source written before lenses existed must keep working. RLM.Source.Materialize
/// is concrete and returns nothing, so the contents lens degrades instead of failing.
Method TestSourceWithoutMaterializeDegradesToStatistics()
{
	Set old = ##class(UnitTest.RLM.Fixture).%New("pre-lens store")
	Set lens = ##class(RLM.Lens.Contents).%New(2000)
	Set peek = old.Peek("color:red")
	Set view = lens.View(old, "red", peek, "color:red", .disclosed)

	Do $$$AssertNotEquals($Find(view, "n=600"), 0, "the aggregates came back")
	Do $$$AssertNotEquals($Find(disclosed, "could not be read"), 0, "and the reason")
}

/// End to end: with the contents lens the sub-call prompt carries records. This is
/// the assertion that says the seam is wired into the engine rather than merely
/// present beside it.
Method TestEngineWithContentsLensPutsRecordsInTheSubcallPrompt()
{
	Set script = $ListBuild("batch", "one", "two", "three", "four", "synthesis")
	Set llm = ##class(RLM.LLM.Null).%New(script)
	Set engine = ##class(RLM.Engine).%New(..Source, llm, ##class(RLM.Budget).%New(12))
	Set engine.Lens = ##class(RLM.Lens.Contents).%New()
	Do engine.Run("which records failed?", .traceId)

	// Call 1 is the decision, so call 2 is the first sub-call. Children pop in
	// declaration order, and `small` is declared first.
	Set sub = llm.PromptAt(2)
	Do $$$AssertNotEquals($Find(sub, "status=failed"), 0, "the record reached the model")
}

/// The mirror of the above, and the one that protects the governed store: the
/// default lens must never let a record into a prompt.
Method TestDefaultLensKeepsRecordsOutOfEveryPrompt()
{
	Set script = $ListBuild("batch", "one", "two", "three", "four", "synthesis")
	Set llm = ##class(RLM.LLM.Null).%New(script)
	Set engine = ##class(RLM.Engine).%New(..Source, llm, ##class(RLM.Budget).%New(12))
	Do engine.Run("which records failed?", .traceId)

	For i = 1:1:llm.Calls {
		Set leak = $Find(llm.PromptAt(i), "id=")
		Do $$$AssertEquals(leak, 0, "no record reached prompt "_i)
	}
}

/// The instruction has to match the view. A model told to describe statistics
/// while holding records produces a summary of data it was meant to answer from,
/// and the output still reads like an analysis, so nothing downstream catches it.
Method TestInstructionsFollowTheLens()
{
	Set engine = ##class(RLM.Engine).%New(..Source, ##class(RLM.LLM.Null).%New(""))
	Set stats = $Find(engine.SubcallInstructions(), "statistics")
	Do $$$AssertNotEquals(stats, 0, "the default asks for a description of aggregates")

	Set engine.Lens = ##class(RLM.Lens.Contents).%New()
	Set records = $Find(engine.SubcallInstructions(), "records")
	Do $$$AssertNotEquals(records, 0, "the contents lens asks for an answer from records")
}

/// Fits is the stopping rule, and every one of its refusals is a case where
/// reading would have been wrong rather than merely expensive.
Method TestFitsRefusesErrorsCapsAndEmptySlices()
{
	Set missing = ..Source.Fits(..Source.Peek("no such slice"), 20)
	Do $$$AssertNotTrue(missing, "a slice the store does not have")

	Set capped = ..Source.Fits(..Source.Peek("batch:partial"), 20)
	Do $$$AssertNotTrue(capped, "a count that is a floor")

	Set large = ..Source.Fits(..Source.Peek("batch:big"), 20)
	Do $$$AssertNotTrue(large, "more records than the cap")

	Set small = ..Source.Fits(..Source.Peek("batch:small"), 20)
	Do $$$AssertTrue(small, "small and known")
}

}
