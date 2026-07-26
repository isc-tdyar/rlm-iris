# Contract: RLM.Replay, RLM.Eval.Arms, RLM.Eval.Scorecard

## RLM.Replay

```objectscript
Method %OnNew(source As RLM.Source, runId As %Integer) As %Status
Method Verify(Output reason As %String) As %Boolean
Method Run(Output report As %String) As %Status
Property Calls As %Integer          ; model calls made. Always 0
Property Decisions As %Integer      ; decisions reproduced
Parameter FORMAT = 2                ; the trace version this code replays
```

`%OnNew` does not read the store. It records the source and the run id and
returns an error only if the trace does not exist at all — a replay of a
non-existent run is a caller bug, not a mismatch.

`Verify` is the gate and is idempotent. It returns 0 with a reason when:

- the trace has no `"v"` node, or a `"v"` other than `#FORMAT` — the reason names
  the version found and the version supported
- the trace's `sourceClass` is not this source's class — refused before any peek,
  because the fingerprints of two different source classes are not comparable and
  a comparison that happens to match would be worse than one that fails
- the fingerprint recomputed from the store differs from the recorded one — the
  reason states that the store no longer matches the trace

`Run` calls `Verify` first and returns its error unchanged. On success it walks
the trace rows in `seq` order, recomputing every peek and reproducing every
decision, and writes a report to `report`.

`Calls` is 0 on every path. It exists so a test can assert it rather than infer
it from a Null LLM's silence.

## RLM.Eval.Arms

```objectscript
ClassMethod Enumerate(source As RLM.Source, runId As %Integer,
                      peekBudget As %Integer = 64) As %DynamicObject
```

Returns `{arms: [...], peeks: n, capped: 0|1, calls: 0}` per data-model.md. Never
throws: a failure to score one arm is that arm's `error`, and a failure to read
the trace is an `error` on the result object.

Arms come from `RLM.Trace.Decisions()`, which already rebuilds each decision with
its candidate list. For each candidate whose `Dimension` is not the chosen one,
`Enumerate` resolves the child slices through `RLM.Policy.Children` and peeks them
— the same path the engine would have taken, which is what makes the score
comparable to the one the run recorded.

Stops when `peekBudget` is exhausted, sets `capped`, and reports the peeks it
spent. It does not silently truncate: an enumeration that stopped early is
indistinguishable from a complete one without that flag.

## RLM.Eval.Scorecard

```objectscript
ClassMethod Score(source As RLM.Source, question As %String,
                  policies As %List, llm As RLM.LLM,
                  maxDepth As %Integer = 1) As %DynamicObject
ClassMethod Objective(source As RLM.Source, runId As %Integer) As %Numeric
ClassMethod Render(card As %DynamicObject) As %String
```

`policies` is a `$LIST` of class names, instantiated per row. `RLM.Policy.LLM`
takes the `llm` argument; `RLM.Policy.Greedy` ignores it. Each row is an ordinary
`RLM.Engine.Run` with `DurableTrace` set, so the run being scored is the same run
a caller would get in production — no evaluation-only code path, which is how a
scorecard stays honest.

`Objective` is the mean `SplitMetric` over the leaf slices a run examined, read
from the trace's `subcall` rows. Lower is better. It reads the store and never the
model.

A row whose run failed carries `error` and no `objective`. A row is never scored
from a partial run (FR-010).

`Render` produces a fixed-width table. Deterministic byte for byte, because SC-003
compares two renderings.

## What none of these do

- No model call, on any path, in any of the three. `RLM.Eval.Scorecard` calls a
  model only through the engine, on behalf of the policy being scored.
- No write to any store other than `^RLM.Trace`.
- No wall clock, no `$RANDOM`, no `$HOROLOG`. The whole feature is the determinism
  guarantee; a clock read inside it would make the guarantee circular.
- No SQL, no `%Net.`, no `%AI.` — asserted by source-text grep in the E2E test.
