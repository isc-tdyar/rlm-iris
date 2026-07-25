# Quickstart: Split-choice policy

## Swapping a policy

A run with today's behaviour needs no change — the engine defaults to
`RLM.Policy.LLM`:

```objectscript
Set engine = ##class(RLM.Engine).%New(source, llm)
Set report = engine.Run("Characterize this store", .traceId)
```

A run that spends no model call on navigation is three lines:

```objectscript
Set engine = ##class(RLM.Engine).%New(source, llm)
Set engine.Policy = ##class(RLM.Policy.Greedy).%New()
Set report = engine.Run("Characterize this store", .traceId)
```

The difference in cost on a two-dimension store: one fewer model call, because
the plan call disappears and the budget it would have spent goes to sub-calls.

## Reading a decision out of a trace

The decision is a `decision` row with a `"d"` subtree:

```objectscript
Set seq = "", dseq = ""
For {
    Set seq = $Order(^||RLM.Trace(traceId, seq))
    Quit:seq=""
    Continue:'$Data(^||RLM.Trace(traceId, seq, "d"))
    Set dseq = seq
    Set d = ^||RLM.Trace(traceId, seq, "d")
    Write !, "chose ", $List(d, 1), " because ", $List(d, 2)
    Write " (", $List(d, 3), " -> ", $List(d, 4), ", ", $List(d, 5), ")"
}
```

A row with no `"d"` subtree made no decision. That is every sub-call and every
synthesis, so the absence is information rather than a gap.

`dseq` is kept because the loop above leaves `seq` empty on exit, and the
candidate walk below needs the row the decision was on.

## Scoring the road not taken

The candidates are subscripted, so the arms enumerate without parsing:

```objectscript
Set n = ""
For {
    Set n = $Order(^||RLM.Trace(traceId, dseq, "d", "cand", n))
    Quit:n=""
    Set c = ^||RLM.Trace(traceId, dseq, "d", "cand", n)
    Write !, $List(c, 1), " scored ", $List(c, 2)
    If $List(c, 4) < $List(c, 3) {
        Write " (from ", $List(c, 4), " of ", $List(c, 3), " children)"
    }
    If $List(c, 5) '= "" { Write " unavailable: ", $List(c, 5) }
}
```

Or use `RLM.Trace.Decisions(traceId)`, which does the same walk and hands back
`RLM.Decision` objects:

```objectscript
Set decisions = ##class(RLM.Trace).Decisions(traceId)
Set d = decisions.GetAt(1)
Write !, d.Dimension, " won on ", d.Candidates.Count(), " candidate(s)"
```

Every score here was computed without a model call, which is why a run can be
re-scored against its alternatives offline. To go further and actually examine an
unchosen arm, re-peek it — a peek is a pure function of the store and the
predicate, so the store answers the same way it did during the run:

```objectscript
Set pred = source.Predicate($ListBuild("size:small"))
Set peek = source.Peek(pred)
```

Each component is one `dimension:token` pair — the same grammar `RLM.Slice`
resolves — so a path of two components nests two slices.

## Declined splits

A store where nothing separates yields a decision with an empty `Dimension` and
a populated `Reason`, and the report says so under "Limits of this analysis":

```text
Limits of this analysis
-----------------------
- Not decomposed: no dimension reduced the metric by the required 5% (best was
  color at 0.905 against 0.900 for the whole slice).
- Spent 1/8 model calls and 4 peeks.
```

That is a case the pre-policy engine could not express. A model handed a store
nothing separates still names slices, and the run reads as a decomposition that
found nothing rather than a store that does not decompose. Note the second line:
the peeks the decision cost are reported even though it declined, because a
decision that spent evidence and found nothing is not free.

## Verifying the claim yourself

```bash
docker exec rlm-iris iris session IRIS -U USER
```

```objectscript
Set ^UnitTestRoot = "/home/irisowner/dev/src/UnitTest"
Do ##class(%UnitTest.Manager).RunTest("RLM", "/noload/nodelete/norecursive")
```

The gate is `UnitTest.RLM.EndToEnd`. Four of its tests measure a claim rather
than asserting it:

| Test                                                 | What it measures                                     |
| ---------------------------------------------------- | ---------------------------------------------------- |
| `TestPromptSizeIsIndependentOfRowCount`              | Tenfold the rows, compare prompt byte lengths        |
| `TestNoRowEverReachesTheModel`                       | A price held by exactly one row appears in no prompt |
| `TestGreedyCostsOneFewerModelCallThanTheModelPolicy` | Both policies over one store, model calls compared   |
| `TestAlternativeArmsAreRecoverableFromTraceAlone`    | The unchosen arm re-peeked through a fresh `Source`  |
