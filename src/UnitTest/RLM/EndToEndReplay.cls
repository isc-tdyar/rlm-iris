/// The feature gate for M3: record a run over an undocumented global, replay it
/// byte for byte, enumerate the arms it did not take, and score two policies
/// against each other -- all offline, with no provider and no network.
///
/// Every other class in this suite tests one seam. This one asserts what the
/// milestone claims: that a finished run is a replayable artifact and an evaluation
/// dataset, and that neither claim costs a model call.
///
/// Every assertion sits on one line: a macro's arguments cannot span source lines.
Class UnitTest.RLM.EndToEndReplay Extends %UnitTest.TestCase
{

Method OnBeforeOneTest(testname As %String) As %Status
{
    Kill ^RLM.Trace
    Do ##class(UnitTest.RLM.FixtureGlobal).Build()
    Quit $$$OK
}

Method OnAfterOneTest(testname As %String) As %Status
{
    Kill ^RLM.Trace
    Quit $$$OK
}

ClassMethod Source() As RLM.Source.Global
{
    Quit ##class(RLM.Source.Global).%New(##class(UnitTest.RLM.FixtureGlobal).#REF, "^||RLM*", .sc)
}

/// Identical replies on purpose: nothing here asserts on their content, and
/// identical replies keep the byte-identity assertion about the traversal rather
/// than about the script.
ClassMethod Scripted(n As %Integer = 32) As RLM.LLM.Null
{
    Set script = ""
    For i = 1:1:n { Set script = script_$ListBuild("mostly pointer nodes, one value per leaf") }
    Quit ##class(RLM.LLM.Null).%New(script)
}

/// The whole milestone in one test: record, replay, enumerate, score.
Method TestAFinishedRunIsReplayableAndScorable()
{
    // --- record ---
    Set llm = ..Scripted()
    Set engine = ##class(RLM.Engine).%New(..Source(), llm,
        ##class(RLM.Budget).%New(32), ##class(RLM.Policy.Greedy).%New())
    Set engine.DurableTrace = 1
    Set engine.MaxDepth = 2
    Set original = engine.Run("what is in this global?", .traceId)
    Do $$$AssertNotEquals(original, "", "a document came back")
    Do $$$AssertEquals($Find(original, "sub-call for"), 0, "and no sub-call failed")
    Do $$$AssertTrue(llm.Calls > 2, "the recorded run spent real calls: "_llm.Calls)
    Set recordedCalls = llm.Calls

    // --- replay ---
    Set replay = ##class(RLM.Replay).%New(..Source(), traceId)
    Do $$$AssertTrue(replay.Verify(.reason), "the run verifies against the store: "_reason)
    Do $$$AssertStatusOK(replay.Run(.replayed), "and it replays")
    Do $$$AssertEquals(replayed, original, "byte for byte")
    Do $$$AssertEquals(replay.Calls, 0, "with no model call")
    Do $$$AssertTrue(replay.Decisions > 1, "reproducing every decision: "_replay.Decisions)

    // --- enumerate the arms ---
    // A global offers exactly one dimension per subscript level -- there is no such
    // thing as "all the BOS-GEN nodes" without saying which date -- so a run over
    // one has no unchosen candidate anywhere. Zero arms and no error is the correct
    // answer here, and asserting it is what keeps "no alternatives" distinguishable
    // from "the enumeration broke".
    Set arms = ##class(RLM.Eval.Arms).Enumerate(..Source(), traceId)
    Do $$$AssertEquals(arms.error, "", "the arms enumerated")
    Do $$$AssertEquals(arms.arms.%Size(), 0, "a hierarchical store offers no alternative dimension")
    Do $$$AssertEquals(arms.calls, 0, "at no model cost")

    // So the scored-arm assertion needs a store with a real choice at the root.
    Set flat = ##class(UnitTest.RLM.FixtureSeparating).%New()
    Set fengine = ##class(RLM.Engine).%New(flat, ..Scripted(), ##class(RLM.Budget).%New(16), ##class(RLM.Policy.Greedy).%New())
    Set fengine.DurableTrace = 1
    Do fengine.Run("how does this store divide?", .ftrace)
    Set farms = ##class(RLM.Eval.Arms).Enumerate(flat, ftrace)
    Do $$$AssertEquals(farms.error, "", "the arms of a two-dimension store enumerated")
    Do $$$AssertTrue(farms.arms.%Size() > 0, "and there were alternatives: "_farms.arms.%Size())
    Do $$$AssertEquals(farms.calls, 0, "at no model cost either")
    Set scored = 0
    For i = 0:1:farms.arms.%Size() - 1 {
        If farms.arms.%Get(i).score '= "" { Set scored = scored + 1 }
    }
    Do $$$AssertTrue(scored > 0, "and at least one arm carries a score: "_scored)

    // --- score two policies ---
    Set card = ##class(RLM.Eval.Scorecard).Score(..Source(), "what is in this global?", $ListBuild("RLM.Policy.Greedy", "UnitTest.RLM.PolicyBad"), ..Scripted(), 2, 32)
    Do $$$AssertEquals(card.rows.%Size(), 2, "two rows")
    Set good = card.rows.%Get(0), bad = card.rows.%Get(1)
    Do $$$AssertEquals(good.error, "", "Greedy was scored")
    Do $$$AssertEquals(bad.error, "", "and so was the control")
    Do $$$AssertTrue(good.objective <= bad.objective, "and Greedy divides no worse: "_good.objective_" <= "_bad.objective)
    Set text = ##class(RLM.Eval.Scorecard).Render(card)
    Do $$$AssertTrue($Find(text, "RLM.Policy.Greedy") > 0, "the card names its policies")

    // Nothing above reached a provider except the recorded run and the two scored
    // runs, each of which used its own scripted LLM.
    Do $$$AssertEquals(llm.Calls, recordedCalls, "the recording LLM was not called again")
}

/// Constitution VI, checked rather than trusted. The evaluation classes are part
/// of the portable module, so they must compile on an IRIS with no AI Hub.
Method TestTheEvaluationClassesArePortable()
{
    Set classes = $ListBuild("RLM.Replay", "RLM.Eval.Arms", "RLM.Eval.Scorecard", "RLM.LLM.Recorded", "RLM.Policy.Recorded")
    Set ptr = 0
    While $ListNext(classes, ptr, cls) {
        Set text = ..SourceTextOf(cls)
        Do $$$AssertTrue($Length(text) > 200, cls_": the source was read at all")
        Do $$$AssertEquals(text [ "%AI.", 0, cls_": no AI Hub dependency")
        Do $$$AssertEquals(text [ "%Net.", 0, cls_": no network client")
        Do $$$AssertEquals(text [ "%SQL.Statement", 0, cls_": no SQL statement")
        Do $$$AssertEquals(text [ "&sql", 0, cls_": no embedded SQL")
    }
}

/// The feature *is* the determinism guarantee, so a clock or a random number read
/// inside it would make the guarantee circular -- and the failure would show up as
/// an intermittent inequality in a byte-identity test, which is the worst kind of
/// test failure to diagnose.
Method TestTheEvaluationClassesReadNoClockAndNoRandomness()
{
    Set classes = $ListBuild("RLM.Replay", "RLM.Eval.Arms", "RLM.Eval.Scorecard", "RLM.LLM.Recorded", "RLM.Policy.Recorded")
    Set ptr = 0
    While $ListNext(classes, ptr, cls) {
        Set text = $ZConvert(..SourceTextOf(cls), "U")
        Do $$$AssertEquals(text [ "$HOROLOG", 0, cls_": no $HOROLOG")
        Do $$$AssertEquals(text [ "$ZTIMESTAMP", 0, cls_": no $ZTIMESTAMP")
        Do $$$AssertEquals(text [ "$RANDOM", 0, cls_": no $RANDOM")
        Do $$$AssertEquals(text [ "$NOW", 0, cls_": no $NOW")
        Do $$$AssertEquals(text [ "$ZDATETIME", 0, cls_": no $ZDATETIME")
    }
}

/// Read-only. A replay or a scorecard that mutated the store it was characterizing
/// would be a catastrophe on a production global, and "we never wrote any code that
/// writes" is not the same as checking.
Method TestTheStoreIsUnchangedByAReplayAndAScorecard()
{
    Set before = ..Fingerprint(##class(UnitTest.RLM.FixtureGlobal).#REF)

    Set engine = ##class(RLM.Engine).%New(..Source(), ..Scripted(),
        ##class(RLM.Budget).%New(32), ##class(RLM.Policy.Greedy).%New())
    Set engine.DurableTrace = 1
    Set engine.MaxDepth = 2
    Do engine.Run("what is in this global?", .traceId)

    Set replay = ##class(RLM.Replay).%New(..Source(), traceId)
    Do $$$AssertStatusOK(replay.Run(.report), "the replay ran")
    Do ##class(RLM.Eval.Arms).Enumerate(..Source(), traceId)
    Do ##class(RLM.Eval.Scorecard).Score(..Source(), "q", $ListBuild("RLM.Policy.Greedy", "UnitTest.RLM.PolicyBad"), ..Scripted(), 2, 32)

    Set after = ..Fingerprint(##class(UnitTest.RLM.FixtureGlobal).#REF)
    Do $$$AssertEquals(after, before, "every node and value is as it was")
}

/// Every node's reference and value, concatenated. Compares contents rather than a
/// count: a run that overwrote one value while adding none would pass a count.
ClassMethod Fingerprint(ref As %String) As %String
{
    Set out = "", node = ref
    For  {
        Set node = $Query(@node)
        Quit:node=""
        // Parenthesized: a postconditional expression ends at the first space, so
        // the unparenthesized form makes `'= ref` a Quit argument.
        Quit:($Extract(node,1,$Length(ref))'=ref)
        Set val = @node
        Set out = out_node_"="_val_$Char(1)
    }
    Quit out
}

/// A class's method source text, for the portability and determinism assertions.
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
