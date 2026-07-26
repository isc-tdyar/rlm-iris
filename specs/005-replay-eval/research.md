# Research: replay and offline evaluation

Everything below was measured in the `rlm-iris` container, not inferred from
documentation.

## R1. The trace records prompt and output _lengths_, not text

`RLM.Engine.Ask` at `src/RLM/Engine.cls:436` writes
`$Length(prompt)` and `$Length(out)` into the row. The prose the model produced
is not in the trace at all.

**Consequence for FR-013**: replay cannot reproduce sub-call text from the
current format. Two options were considered:

- **Reproduce nothing, and label the report as decisions-only.** Cheapest, and
  the decisions are what an evaluation scores. But it makes "the replayed report
  is comparable to the original" untestable, which is SC-002's whole point.
- **Store the text in a sidecar node under the row.** Chosen. `AddDecision`
  already writes sidecar subscripts under `(runId, seq, "d", …)`, so the
  mechanism exists and costs nothing new. The text goes under
  `(runId, seq, "t")`, written only when the trace is durable.

The second is a trace format change, which is why FR-011's version field lands in
the same feature: a durable trace written before this change has no `"t"` node,
and a replay that treats a missing node as an empty answer silently produces a
different report. Version 1 traces are refused with a reason rather than
half-replayed.

Storing model text is not a Constitution I violation. Principle I forbids _store
contents_ reaching the model; this is the model's own output travelling back into
a report it was already in.

## R2. `$ZCRC(s, 7)` is CRC-32, stable within a process and across processes

Measured: `$ZCRC("hello",7)` = 907060870 on repeated calls, 3138956147 for
`"hellp"` — one character changes the whole value. A 100,000-character argument
returns in the same call with no length error.

**Decision**: the store fingerprint is a CRC-32 chain over the peek JSON of the
root and of every first-level slice, accumulated as
`crc = $ZCRC(crc_$ZCRC(sliceJson, 7), 7)`.

Why over peek JSON rather than over the store: a fingerprint that read the store
directly would be a walk with no cap, which is the thing this package refuses to
do. Peek JSON is bounded, already computed, and is exactly the input replay
depends on — if the peeks match, the replay is sound, and if a change to the
store did not move any peek figure then it could not have moved any decision.

The honest limitation, and it goes in the class comment: a mutation that leaves
every aggregate identical (swapping two values of equal length between slices)
does not move the fingerprint. That is a fingerprint over the peeks and it is
described as such rather than as a fingerprint over the data.

## R3. `%DynamicObject` preserves insertion order in `%ToJSON()`

Measured: setting `z`, `a`, `m` in that order serializes as `{"z":1,"a":2,"m":3}`.

**Consequence**: peek JSON is stable enough to hash, provided every source builds
its peek in a fixed order — which both existing sources do, since the properties
are set by literal code paths, and which the existing
`TestPeekingTwiceIsIdentical` already guards for `Global`. An equivalent
assertion is added for `Table` in this feature rather than assumed.

## R4. `^RLM.Trace` was empty in the dev container

`$Increment(^RLM.Trace)` returned 1 on first call: no durable trace has ever been
written by the suite, because every test uses the process-private default.

**Consequence**: durable traces need cleaning up between tests, or run ids drift
across suite runs and any assertion on a run id is a flake. Each test class in
this feature kills `^RLM.Trace` in `OnBeforeOneTest`. That is a global the project
owns entirely and nothing else in the suite writes it.

## R5. `RLM.Trace.Decisions()` already rebuilds decisions with their candidates

`src/RLM/Trace.cls:126`. It returns `%ListOfObjects` of `RLM.Decision`, each
carrying `Candidates` with `Dimension`, `Score`, `Children`, `Sampled`, `Error`
and `ChildMetrics`, and it outputs `seqs(ordinal) = seq`.

**Consequence**: US2 (arm enumeration) needs no new trace reader. It reads
`Decisions()`, and for each candidate the run did not choose, resolves the slice
and peeks it. The candidate list is already on the record, which is what makes
"the model never authors a predicate" pay off here: every arm is a name the store
offered, so every arm is replayable.

## R6. `Policy.ChooseSplit` takes the peek, not the store

Confirmed from `src/RLM/Policy.cls:59` and both implementations. A policy is a
function from (peek, candidates) to a decision.

**Consequence for US3**: scoring a policy does not need a special harness. It is
an ordinary `RLM.Engine.Run` with that policy and a durable trace, and the
scorecard is computed from the trace afterwards. No engine change, no new seam,
and a policy nobody has written yet scores the same way.

## R7. Multi-line piped ObjectScript still fails with `<SYNTAX>`

Unchanged from 004's R6, and hit again this feature: probes go in a class file
copied in with `docker cp` and loaded with `LoadDir(..., "ck")`. A `.mac` file
loaded through `$system.OBJ.Load` is reported as "Unknown file type" — it must be
`ImportDir` on a directory, or simpler, just use a class.

## R8. `RLM.LLM.Null` with an empty script errors on every call

Found while gating 004, and it belongs here because this feature's tests are all
about whether a run actually ran. An unscripted Null returns
`unscripted call N` for every call, the engine records a failed sub-call and
carries on, and the report keeps every heading. A test asserting only on
structure passes on a decomposition that produced nothing.

**Consequence**: every test in this feature that runs a decomposition asserts
zero sub-call failures before asserting anything else, and the default budget of
8 is raised explicitly whenever the fixture has more slices than that.
