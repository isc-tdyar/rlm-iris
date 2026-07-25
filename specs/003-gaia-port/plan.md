# Implementation Plan: Port the gaia-iml prototype onto rlm-iris

**Branch**: `003-gaia-port` | **Date**: 2026-07-25 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/003-gaia-port/spec.md`

## Summary

The prototype gets three new classes and loses about 700 lines. `Gaia.Source`
extends `RLM.Source.Table` and declares six bucketed dimensions over the quality
table, overriding `Peek`, `Describe`, `SplitMetric`, `ShouldSplit` and `Ready`.
`Gaia.LLM.AIHub` wraps `%AI.Agent` behind the one-method `RLM.LLM` contract.
`Gaia.RLM` keeps `Audit()` and `Triage()` and becomes two engine constructions.
`Gaia/Slice.cls` is deleted and `Gaia.RLM2` resolves through `RLM.Slice`.

The library reaches the prototype as a git submodule at `lib/rlm-core`, loaded
before `src/` — IPM is unavailable in the AI-preview image the prototype builds
on, so a pinned submodule is the only route that both survives a fresh clone and
is not a copy.

Three defects surfaced before a line was written, and all three are recorded
rather than absorbed:

- **`Triage`'s scope is a union of three sibling buckets**, which the slice grammar
  cannot name and should not learn to. The fix is a sixth dimension, `detection`,
  splitting the same column at the boundary the challenge actually asks about.
- **The "21 slices" figure** carried in from the survey does not reconcile with
  the prototype's own `Dimensions()`, which declares 5 × 4 = 20. SC-001 is
  corrected and now prints a computed figure.
- **A caller cannot write the report to a file.** `Run` returns text and the
  `RLM.Report` it wrote is private to the run, so `RLM.Report.WriteToFile` is
  unreachable from outside the engine. Every consumer would re-implement it, and
  the first to forget `TranslateTable = "UTF8"` gets a file whose em dashes are
  question marks. This one is a library change in `rlm-iris` under FR-014, not a
  workaround in Gaia: a new `WriteTextToFile(text, path)` class method that the
  existing instance method delegates to.

## Technical Context

**Language/Version**: ObjectScript, IRIS 2026.3.0AI Build 126 (the prototype's
image; AI Hub only ships in the AI preview). The library's own floor is 2026.1
community and is unaffected.
**Primary Dependencies**: `rlm-core` (this repository, git submodule) and
`%AI.Agent` (the prototype's provider, reached only through `Gaia.LLM.AIHub`)
**Storage**: `SQLUser.GaiaQualityScored`, 74,998 rows, 15 columns, written by
`^RunScript`. Read-only for this feature.
**Testing**: `%UnitTest` classes under `gaia-iml/src/UnitTest/Gaia/`, run in
`gaia-iml-iris` with the `"ck"` load qualifier. The library's 136-test suite in
`rlm-iris` must stay green after every phase.
**Target Platform**: Linux container, `gaia-iml-iris` (32796 → 1972)
**Project Type**: ObjectScript library plus the application that consumes it,
across two repositories
**Performance Goals**: `Audit()` within the prototype's existing envelope — 18
model calls, depth 3. Not benchmarked; `^RunScript` is the timed path and this
feature does not touch it.
**Constraints**: The report is a bonus deliverable. Nothing in this feature may
change `^RunScript`, `result.csv`, or the contest timing. `Run` never throwing is
what guarantees that, and it is tested rather than assumed.
**Scale/Scope**: 1,525 lines of prototype today; three classes added, one
deleted, ~700 lines removed. Six dimensions, 22 children, 74,998 rows.

## Constitution Check

_GATE: must pass before Phase 0 research. Re-checked after Phase 1 design._

| Principle                              | Status | How this feature satisfies it                                                                                                                                                                                                                         |
| -------------------------------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| I. Model never receives store contents | PASS   | `Gaia.Source.Peek` is sixteen SQL aggregates; `Describe` renders eleven derived lines. No row reaches a prompt. Tested per the principle's own requirement: a `source_id` held by exactly one row must not appear in any prompt the run builds.       |
| II. Model never authors a predicate    | PASS   | Strengthened, not weakened. The prototype's `Triage` passed a raw `pct_change > 100` into its recursion; the port replaces it with a slice name resolved through the whitelist. Deleting `Gaia.Slice` removes the second grammar that could disagree. |
| III. Caps are reported, never hidden   | PASS   | `Ready()` refuses a partially-scored table rather than averaging over what is present. `NullCount()` is wired rather than assumed zero. Budget-dropped slices are named by the engine's existing caveat list.                                         |
| IV. Test-first, deterministically      | PASS   | Every phase writes its tests first. SC-003 asserts byte-identity across two `RLM.LLM.Null` runs, which the prototype could not claim. The one real-provider run is a smoke gate, not an assertion of text.                                            |
| V. A run is replayable                 | PASS   | No model-authored code, no wall-clock or random input to a decision. `SplitMetric`'s baseline is cached per source instance, i.e. per run, so a replayed run computes the same figure.                                                                |
| VI. Portable by default                | PASS   | This feature is the first real test of it. `%AI.*` appears only in `Gaia.LLM.AIHub`; SC-005 greps `RLM.Engine.cls` for `%AI.` and requires zero matches. Research decision 2 rejects `RLM.LLM.REST` precisely because it would not exercise this.     |

One constraint deserves calling out rather than ticking. The constitution says
store-specific concepts stay behind the `RLM.Source` contract, and `SplitMetric`
returns a normalized 0–1 scalar per store. The prototype's rule is a ratio
against a survey-wide baseline that can exceed 1, so the port clamps. Decision 7
records what the clamp costs: two slices both more spread than the survey are
indistinguishable to `RLM.Policy.Greedy`. The port runs `RLM.Policy.LLM`, as the
prototype did, so nothing regresses — but the clamp is a real limit of the
contract and is written down rather than discovered later.

**Cross-repository note.** Spec artifacts land in `rlm-iris`; code lands in
`gaia-iml`, for which write permission was given explicitly. FR-014 binds the
direction of fixes: a library defect is fixed here with a test, never worked
around there.

## Project Structure

### Documentation (this feature)

```text
specs/003-gaia-port/
├── plan.md              # This file
├── research.md          # Phase 0 — seven decisions, all measured
├── data-model.md        # Phase 1 — the six dimensions and the peek shape
├── quickstart.md        # Phase 1 — how to run the ported analysis
├── contracts/README.md  # Phase 1 — what Gaia must implement, obligation by obligation
├── checklists/
│   └── requirements.md  # Spec quality gate
└── tasks.md             # Phase 2 (/speckit.tasks — not created here)
```

### Source Code

`rlm-iris` (this repository) — spec artifacts, plus the one library change already
known:

```text
src/RLM/Report.cls               # EDITED — WriteTextToFile(text, path) class method
src/UnitTest/RLM/ReportStyle.cls # EDITED — its test, and the instance method unchanged
```

Any further defect the port exposes lands here too, under FR-014.

`gaia-iml` (the port's target):

```text
gaia-iml/
├── lib/
│   └── rlm-core/              # NEW — git submodule, pinned to a rlm-iris commit
├── src/
│   ├── Gaia/
│   │   ├── Source.cls         # NEW — six dimensions, peek, describe, metric, ready
│   │   ├── LLM/
│   │   │   └── AIHub.cls      # NEW — %AI.Agent behind RLM.LLM.Complete()
│   │   ├── RLM.cls            # SHRINKS — 513 lines to ~90; two engine constructions
│   │   ├── RLM2.cls           # EDITED — resolves through RLM.Slice
│   │   ├── Slice.cls          # DELETED
│   │   ├── Analyst.cls        # UNTOUCHED — the counterexample the README argues from
│   │   └── Tools/             # UNTOUCHED — RLM2's toolset, and RLM2 stays
│   └── UnitTest/Gaia/
│       ├── Source.cls         # NEW — US1
│       ├── LLM.cls            # NEW — US2
│       ├── Port.cls           # NEW — US3, US4 end-to-end
│       └── RLM2.cls           # EDITED — grammar tests point at RLM.Slice
├── iris.script                # EDITED — LoadDir over lib/rlm-core/src first
├── module.xml                 # EDITED — <Dependencies> names rlm-core
├── .gitmodules                # NEW
└── README.md                  # EDITED — names rlm-iris as the dependency
```

**Structure Decision**: the prototype keeps its existing layout; the library
arrives as a subdirectory rather than reshaping anything. `Gaia.LLM.AIHub` goes
under a `LLM/` subpackage because the library's own providers live under
`RLM/LLM/`, and matching that makes the correspondence obvious to a reader
comparing the two trees.

## Phasing

The spec's five stories map to five phases, and the dependency order is forced by
what compiles:

1. **Foundational** — submodule, `iris.script`, `module.xml`, plus
   `RLM.Report.WriteTextToFile` in `rlm-iris`. Until the library's classes compile
   inside `gaia-iml-iris`, nothing that extends them can exist; and until a caller
   can write a file, no entry point can be finished.
2. **US1 `Gaia.Source`** (P1) — testable with no engine, no policy, no model. The
   whole test of whether `RLM.Source` is the right contract.
3. **US2 `Gaia.LLM.AIHub`** (P1) — independent of US1, and the test of principle
   VI. Could run in parallel with US1; sequenced after because US3 needs both and
   US1 is where a library defect would surface first.
4. **US3 the entry points** (P2) — needs US1 and US2. Where the 700 lines leave.
5. **US4 delete `Gaia.Slice`** (P3) — needs US1 only (`RLM.Slice` resolves against
   a `Gaia.Source`). Independent of US3.
6. **US5 documentation** (P3) — last, because it describes what the other phases
   actually did rather than what they were planned to do.

Each phase ends on a gate: its own tests plus the existing `UnitTest.Gaia.RLM2`
suite plus the library's 136 tests in `rlm-iris`. A phase that breaks the library
suite is a phase that found a defect, and FR-014 says where the fix goes.

## Complexity Tracking

| Violation                                           | Why needed                                                                                                                                                                                                      | Simpler alternative rejected because                                                                                                                                                             |
| --------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Sixth dimension over an already-bucketed column     | `Triage` describes a population that no single slice names. Two dimensions over one column is legal and gives the challenge's binary question its own name, with `variability` still available to subdivide it. | Retargeting `Triage` at the largest single bucket changes which population the report describes, silently. Teaching the grammar to name sibling unions breaks every child-predicate computation. |
| Clamping `SplitMetric` to 1                         | The library documents the metric as 0–1 and `Greedy` size-weights it. The prototype's ratio is unbounded above.                                                                                                 | Widening the contract to allow unbounded metrics would make `Greedy`'s weighting meaningless for every store, to serve one.                                                                      |
| A new provider class when `RLM.LLM.REST` would work | Principle VI is only tested by a run whose provider is an `%AI.*` class.                                                                                                                                        | Using REST proves the engine works with the transport it was written against, which nobody doubted, and drops the model pinning the prototype's reports quote.                                   |
| Git submodule rather than IPM                       | `%ZPM.PackageManager` does not exist in the prototype's image — verified, not assumed.                                                                                                                          | A copy diverges silently. A compose mount of a sibling directory fails on the first clone anyone else makes.                                                                                     |
