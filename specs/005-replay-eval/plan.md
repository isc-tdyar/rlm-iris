# Implementation Plan: replay and offline evaluation

**Branch**: `005-replay-eval` | **Date**: 2026-07-25 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `specs/005-replay-eval/spec.md`

## Summary

Three new classes and one trace format change. `RLM.Replay` re-runs a recorded
decomposition from `^RLM.Trace` plus the store, with no model call, and refuses
when the store no longer matches the trace. `RLM.Eval.Arms` scores, at every
recorded decision, every candidate the run did not take. `RLM.Eval.Scorecard`
runs a set of policies over one store and one question and reports what each
spent against what each achieved, as separate figures.

The trace change is the plan's main risk and the reason FR-011 exists: today the
row stores prompt and output _lengths_, not text (research R1), so replay cannot
reproduce a report without a sidecar node — and a durable trace written before
that node existed must be refused rather than half-replayed.

## Technical Context

**Language/Version**: ObjectScript, IRIS 2026.1 community as the floor
**Primary Dependencies**: none beyond `%Library`. No `%AI.*`, no HTTP, no SQL —
Constitution VI
**Storage**: `^RLM.Trace` (durable, read and written); the fixture stores, read
only
**Testing**: `%UnitTest` classes under `src/UnitTest/RLM`, run in the `rlm-iris`
container. Every test class kills `^RLM.Trace` in `OnBeforeOneTest` (research R4)
**Target Platform**: any IRIS instance, no AI Hub, no provider configured
**Project Type**: single ObjectScript library
**Performance Goals**: a replay costs one peek per recorded slice and zero model
calls. Arm enumeration is bounded by an explicit peek budget and reports what it
spent
**Constraints**: no wall clock, no `$RANDOM`, no `$HOROLOG` anywhere in a replay
or a score — the whole feature is the determinism guarantee, so a single clock
read would make it circular
**Scale/Scope**: 3 new classes, 1 modified (`RLM.Trace`), 1 lightly modified
(`RLM.Engine`, to write the fingerprint and the sub-call text). 5 new test classes

## Constitution Check

_GATE: passed before Phase 0; re-checked after Phase 1 design._

| Principle                           | How this feature satisfies it                                                                                                             | Gate                                                                         |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| I. Model never receives contents    | Replay and scoring read peeks and traces. The fingerprint is a CRC over peek JSON, never over stored values (research R2)                 | Test asserts the planted secret value appears in no trace node and no report |
| II. Model never authors a predicate | Arms are enumerated from the candidate list the store offered, recorded at run time. An arm is a name the store already advertised        | Test asserts an arm naming a dimension the store never offered is refused    |
| III. Caps reported, never hidden    | Arm enumeration reports peeks spent and whether the budget stopped it. A mismatched store refuses rather than reporting different figures | US4 is a P2 story with its own gate, not a polish item                       |
| IV. Test-first, deterministic       | Every task writes its test first. `RLM.LLM.Null` drives every run, including the LLM policy's                                             | Phase gate per user story                                                    |
| V. Replayable                       | This feature _is_ Principle V. It also strengthens it: the format version makes an unreplayable trace say so                              | SC-001, SC-002, SC-003 are all direct tests                                  |
| VI. Portable by default             | No `%AI.*`, no HTTP, no SQL in any new class                                                                                              | Source-text grep assertion in the E2E test, as in 004                        |

**Result**: no violations. One trace format change; see Complexity Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/005-replay-eval/
├── plan.md              # this file
├── spec.md
├── research.md          # Phase 0, measured
├── data-model.md        # Phase 1
├── quickstart.md        # Phase 1
├── contracts/
│   └── replay-eval.md   # Phase 1: the trace v2 format, arm and scorecard shapes
└── tasks.md             # Phase 2, /speckit.tasks
```

### Source Code (repository root)

```text
src/RLM/
├── Trace.cls                   # MODIFIED: format version, fingerprint, text sidecar
├── Engine.cls                  # MODIFIED: write the fingerprint and sub-call text
├── Replay.cls                  # NEW: US1, US4
└── Eval/
    ├── Arms.cls                # NEW: US2
    └── Scorecard.cls           # NEW: US3

src/UnitTest/RLM/
├── FixtureSeparating.cls       # NEW: a table fixture with one separating dimension
├── PolicyBad.cls               # NEW: a policy that deliberately chooses badly
├── Replay.cls                  # NEW: US1
├── ReplayMismatch.cls          # NEW: US4
├── EvalArms.cls                # NEW: US2
├── EvalScorecard.cls           # NEW: US3
└── EndToEndReplay.cls          # NEW: feature gate, offline, US5
```

**Structure Decision**: `Eval` is a new package under `src/RLM/` because
`Scorecard` and `Arms` are tools _about_ a run rather than parts of one — putting
them beside `Engine` would suggest the engine depends on them, and it must not.
`Replay.cls` sits at the top level because it is the engine's counterpart: same
inputs, same outputs, no model.

## Phase 1 design notes

**Trace format v2.** `^RLM.Trace(runId, "v") = 2` plus
`^RLM.Trace(runId, "fp") = <crc>` and `^RLM.Trace(runId, seq, "t") = <text>`.
Nothing about the positional `$LIST` row changes, so every existing reader
(`Decisions`, `RowCount`, `Row`, `Count`, `Report.RenderTrace`) is untouched and
the 211 existing tests must pass unmodified. A trace with no `"v"` node is
version 1 and is refused by `Replay` with a reason.

**The fingerprint** is a CRC-32 chain over the peek JSON of the root and each
first-level slice — bounded, already computed, and exactly the input replay
depends on (research R2). Its documented limitation is that a mutation moving no
aggregate does not move it; the class comment says so rather than implying a hash
over the data.

**Replay produces a report, not a boolean.** The output is comparable to the
original run's, which is what SC-002 asserts. Sections derived from the store are
recomputed; sub-call prose comes from the `"t"` sidecar and is labelled
reproduced.

**The objective** is mean `SplitMetric` across the leaf slices a run examined,
lower being better — a decomposition whose leaves are still mixed did not divide
anything. It is store-derived, needs no model, and is comparable across policies
over one store only, which is the constitutional constraint on `SplitMetric`
surfacing as a scope rule on the scorecard.

**Scoring needs no engine change.** A policy is a function from (peek,
candidates) to a decision (research R6), so scoring one is an ordinary
`Engine.Run` with a durable trace, and the scorecard is computed from the trace
afterwards. A policy nobody has written yet scores the same way.

## Complexity Tracking

| Violation                                                              | Why Needed                                                                                                                                                                                                                                                                          | Simpler Alternative Rejected Because                                                                                                                                                                                                                                                                                                                                                     |
| ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Trace format gains a version, a fingerprint and a per-row text sidecar | Replay must reproduce a report to be testable, and the row records only `$Length(out)` (research R1). Without the version, a v1 trace replays with empty prose and produces a _different_ report that claims to be a reproduction — the same class of failure as an undisclosed cap | Reproducing nothing and calling the output decisions-only was considered and rejected: it makes SC-002 untestable, which is the milestone's headline claim. Widening the positional `$LIST` row was rejected because `$List(row, 11)` on an older row returns "" rather than failing — a silent wrong answer, and the same reasoning `AddDecision` already documents for its own sidecar |
| A new `RLM.Eval` package                                               | `Arms` and `Scorecard` are tools about a run. The engine must not depend on them, and a reader should be able to see that from the layout                                                                                                                                           | Putting them beside `Engine.cls` implies a dependency that does not exist and would invite one                                                                                                                                                                                                                                                                                           |

The trace change is the thing to watch. It is additive at the subscript level and
untouched at the row level, so the gate for the phase that lands it is the 211
existing tests passing with no assertion edited — the same gate 004's
`Dimensions(path)` change used, for the same reason.
