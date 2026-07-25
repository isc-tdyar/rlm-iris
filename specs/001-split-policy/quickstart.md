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
Set seq = ""
For {
    Set seq = $Order(^||RLM.Trace(traceId, seq))
    Quit:seq=""
    Continue:'$Data(^||RLM.Trace(traceId, seq, "d"))
    Set d = ^||RLM.Trace(traceId, seq, "d")
    Write !, "chose ", $List(d, 1), " because ", $List(d, 2)
    Write " (", $List(d, 3), " -> ", $List(d, 4), ", ", $List(d, 5), ")"
}
```

A row with no `"d"` subtree made no decision. That is every sub-call and every
synthesis, so the absence is information rather than a gap.

## Scoring the road not taken

The candidates are subscripted, so the arms enumerate without parsing:

```objectscript
Set n = ""
For {
    Set n = $Order(^||RLM.Trace(traceId, seq, "d", "cand", n))
    Quit:n=""
    Set c = ^||RLM.Trace(traceId, seq, "d", "cand", n)
    Write !, $List(c, 1), " scored ", $List(c, 2)
    If $List(c, 4) < $List(c, 3) {
        Write " (from ", $List(c, 4), " of ", $List(c, 3), " children)"
    }
    If $List(c, 5) '= "" { Write " unavailable: ", $List(c, 5) }
}
```

Every score here was computed without a model call, which is why a run can be
re-scored against its alternatives offline. To go further and actually examine an
unchosen arm, re-peek it — a peek is a pure function of the store and the
predicate, so the store answers the same way it did during the run:

```objectscript
Set pred = source.Predicate($ListBuild("size", "small"))
Set peek = source.Peek(pred)
```

## Declined splits

A store where nothing separates yields a decision with an empty `Dimension` and
a populated `Reason`, and the report says so under "Limits of this analysis":

```text
Limits of this analysis
-----------------------
  - Not decomposed: no dimension reduced the metric (best was size at 0.87
    against 0.90 for the whole store).
```

That is a case today's engine cannot express. A model handed a store nothing
separates still names slices, and the run reads as a decomposition that found
nothing rather than a store that does not decompose.

## Verifying the claim yourself

```bash
docker exec rlm-iris iris session IRIS -U USER
```

```objectscript
Set ^UnitTestRoot = "/home/irisowner/dev/src/UnitTest"
Do ##class(%UnitTest.Manager).RunTest("RLM", "/noload/nodelete/norecursive")
```

The gate is `UnitTest.RLM.EndToEnd`. Two of its tests measure the central claim
rather than asserting it: one multiplies the rows tenfold and compares prompt byte
lengths, and one picks a value held by exactly one row and proves it appears in
no prompt. The greedy variant adds a third: the same store decomposed with zero
`plan` rows in the trace.
