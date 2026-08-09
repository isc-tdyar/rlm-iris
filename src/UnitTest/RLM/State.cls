/// Tests for the run scratchpad.
///
/// The claim being protected is that a decomposition leaves an artifact rather
/// than only a paragraph. A report has to be re-read to be used again; a scratchpad
/// keyed by slice can be queried, resumed against, and read by a later slice of the
/// same run -- which is the whole of what a REPL-based RLM cannot do, because a
/// Python local has nowhere to put a finding that outlives the call that made it.
///
/// Every assertion sits on one line: a macro's arguments cannot span source lines,
/// so anything long is hoisted into a local first.
///
/// Each test clears up after itself, and the durable one asserts that Clear reaches
/// the persistent global -- a suite that left ^RLM.State behind would make the next
/// run's Count() depend on how many times the tests had been run.
Class UnitTest.RLM.State Extends %UnitTest.TestCase
{

/// A finding written against a slice comes back under that slice.
Method TestPutAndGetRoundTrip()
{
	Set state = ##class(RLM.State).%New(1)
	Do state.Put("color:red", "finding", "600 rows, tightly grouped")

	Set got = state.Get("color:red", "finding")
	Do $$$AssertEquals(got, "600 rows, tightly grouped", "the finding survives")

	Set missing = state.Get("color:blue", "finding", "none")
	Do $$$AssertEquals(missing, "none", "an unwritten slice returns the default")
	Do state.Clear()
}

/// "Recorded nothing" and "never ran" are different answers, and a resumed run
/// deciding whether to redo work is exactly the caller that must tell them apart.
Method TestHasDistinguishesEmptyFromAbsent()
{
	Set state = ##class(RLM.State).%New(2)
	Do state.Put("color:red", "finding", "")

	Do $$$AssertTrue(state.Has("color:red", "finding"), "an empty finding was recorded")
	Do $$$AssertNotTrue(state.Has("color:blue", "finding"), "this one never ran")
	Do state.Clear()
}

/// The root writes under the empty path, which $ORDER does not reach on its own.
/// A Paths() that quietly omitted it would lose the run's own answer.
Method TestPathsIncludesTheRoot()
{
	Set state = ##class(RLM.State).%New(3)
	Do state.Put("", "answer", "the store splits on colour")
	Do state.Put("color:red", "finding", "tight")
	Set paths = state.Paths()

	Do $$$AssertEquals($ListLength(paths), 2, "both slices are enumerated")
	Do $$$AssertEquals($ListGet(paths, 1), "", "and the root comes first")
	Do state.Clear()
}

/// Findings() is what a synthesis prompt and a resumption check both read, so it
/// must return only the slices that recorded the key it was asked for.
Method TestFindingsSelectsByKey()
{
	Set state = ##class(RLM.State).%New(4)
	Do state.Put("color:red", "finding", "tight")
	Do state.Put("color:red", "label", "red")
	Do state.Put("color:blue", "label", "blue")
	Set found = state.Findings("finding")

	Do $$$AssertEquals($ListLength(found), 1, "only the slice with a finding")
	Do $$$AssertEquals($ListGet(found, 1), "color:red|tight", "as path and value")

	Set labels = state.Findings("label")
	Do $$$AssertEquals($ListLength(labels), 2, "and labels are counted separately")
	Do state.Clear()
}

/// Last write wins, because a deeper pass over a slice has learned more than the
/// shallower one it replaces.
Method TestRewriteReplacesRatherThanAccumulates()
{
	Set state = ##class(RLM.State).%New(5)
	Do state.Put("color:red", "finding", "first pass")
	Do state.Put("color:red", "finding", "second pass")

	Set got = state.Get("color:red", "finding")
	Do $$$AssertEquals(got, "second pass", "the current finding wins")
	Do $$$AssertEquals(state.Count(), 1, "and there is still one finding")
	Do state.Clear()
}

/// Clear must remove the run's own subtree and only that, or a durable scratchpad
/// shared by two runs loses the wrong one.
Method TestClearRemovesOnlyThisRun()
{
	Set mine = ##class(RLM.State).%New(6)
	Set theirs = ##class(RLM.State).%New(7)
	Do mine.Put("a", "finding", "mine")
	Do theirs.Put("a", "finding", "theirs")
	Do mine.Clear()

	Do $$$AssertEquals(mine.Count(), 0, "mine is gone")
	Do $$$AssertEquals(theirs.Get("a", "finding"), "theirs", "and theirs is not")
	Do theirs.Clear()
}

/// A durable run's findings must outlive the process-private global, or resuming
/// a durable trace lands on a scratchpad that is already gone.
Method TestDurableStateWritesToThePersistentGlobal()
{
	Set state = ##class(RLM.State).%New(8, 1)
	Do state.Put("color:red", "finding", "durable")

	Set durable = $Data(^RLM.State(8, "color:red", "finding"))
	Do $$$AssertTrue(durable, "written to ^RLM.State")

	Set private = $Data(^||RLM.State(8))
	Do $$$AssertNotTrue(private, "and not to the process-private one")

	Do state.Clear()
	Set gone = $Data(^RLM.State(8))
	Do $$$AssertNotTrue(gone, "and Clear reaches the durable global")
}

/// The engine populates the scratchpad as it runs, so a caller gets the
/// decomposition as data without having asked for anything extra.
Method TestEngineRecordsEverySliceItExamined()
{
	Set source = ##class(UnitTest.RLM.Fixture).%New("fixture store")
	Set script = $ListBuild("color", "red note", "blue note", "synth")
	Set llm = ##class(RLM.LLM.Null).%New(script)
	Set engine = ##class(RLM.Engine).%New(source, llm)
	Do engine.Run("what separates this store?", .traceId)

	Set red = engine.State.Get("color:red", "finding")
	Do $$$AssertEquals(red, "red note", "each slice recorded what was said about it")

	Set blue = engine.State.Get("color:blue", "finding")
	Do $$$AssertEquals(blue, "blue note", "both of them")

	Set answer = engine.State.Get("", "answer")
	Do $$$AssertEquals(answer, "synth", "and the run recorded its answer")

	Set findings = engine.State.Findings("finding")
	Do $$$AssertEquals($ListLength(findings), 2, "two slices were examined")
	Do engine.State.Clear()
}

/// The scratchpad shares the trace's run id, so a finding can be read back beside
/// the calls that produced it. Two independent identifiers would make that a join
/// nobody holds the key for.
Method TestStateSharesTheTraceRunId()
{
	Set source = ##class(UnitTest.RLM.Fixture).%New("fixture store")
	Set script = $ListBuild("color", "a", "b", "synth")
	Set llm = ##class(RLM.LLM.Null).%New(script)
	Set engine = ##class(RLM.Engine).%New(source, llm)
	Do engine.Run("q", .traceId)

	Do $$$AssertEquals(engine.State.RunId, traceId, "one run, one identifier")
	Do engine.State.Clear()
}

/// A slice whose sub-call failed is still recorded, or a resumed run cannot tell
/// it from a slice the budget never reached.
Method TestFailedSubcallIsStillRecorded()
{
	Set source = ##class(UnitTest.RLM.Fixture).%New("fixture store")
	Set script = $ListBuild("color", "red note", "blue note", "synth")
	Set llm = ##class(RLM.LLM.Null).%New(script)
	Set llm.FailAtCall = 2
	Set engine = ##class(RLM.Engine).%New(source, llm)
	Do engine.Run("q", .traceId)

	Set recorded = engine.State.Has("color:red", "finding")
	Do $$$AssertTrue(recorded, "the failed slice is still on the record")

	Set said = $Find(engine.State.Get("color:red", "finding"), "failed")
	Do $$$AssertNotEquals(said, 0, "and says what happened")
	Do engine.State.Clear()
}

/// A run that never started still leaves a usable scratchpad rather than an unset
/// property, so a caller can read State unconditionally.
Method TestRefusedRunStillHasState()
{
	Set stale = ##class(UnitTest.RLM.FixtureNotReady).%New("nightly load")
	Set llm = ##class(RLM.LLM.Null).%New("")
	Set engine = ##class(RLM.Engine).%New(stale, llm)
	Do engine.Run("q", .traceId)

	Do $$$AssertTrue($IsObject(engine.State), "State exists after a refusal")
	Do $$$AssertEquals(engine.State.Count(), 0, "and holds nothing")
}

}
