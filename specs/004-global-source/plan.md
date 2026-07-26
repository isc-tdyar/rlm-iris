# Implementation Plan: RLM.Source.Global

**Branch**: `004-global-source` | **Date**: 2026-07-25 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `specs/004-global-source/spec.md`

## Summary

Add `RLM.Source.Global`, a source that characterizes an undocumented IRIS global
by bounded `$ORDER`/`$QUERY` walk. Dimensions come from the immediate subscript
level; the peek reports counts, depth, fanout, node kind, value-length moments and
subscript type mix, with any cap disclosed; the split metric is normalized fanout
entropy. Access is read-only behind a fail-closed allowlist enforced at
construction.

One engine-level change is required and is the plan's main risk: `Dimensions()`
is path-blind, which is correct for `Table` and wrong for a global.

## Technical Context

**Language/Version**: ObjectScript, IRIS 2026.1 community as the floor
**Primary Dependencies**: none beyond `%Library`. No `%AI.*`, no HTTP, no SQL —
Constitution VI
**Storage**: the target global itself, read-only; `^RLM.Trace` for traces
**Testing**: `%UnitTest` classes under `src/UnitTest/RLM`, run in the `rlm-iris`
container. Fixtures build process-private globals (`^||`) so no test can collide
with another or leave state behind
**Target Platform**: any IRIS instance, no AI Hub
**Project Type**: single ObjectScript library
**Performance Goals**: a peek is bounded by the visit cap (default 50,000 nodes),
not by subtree size. Peek output under 2,000 characters regardless of node count
**Constraints**: no writes to the target global on any path; no wall-clock or
random dependence anywhere in a peek, because Constitution V requires replay
**Scale/Scope**: one new source class, one fixture family, roughly 6 new test
classes. No change to `Engine`, `Slice`, `Budget`, `Trace` or `Report` except the
one documented below

## Constitution Check

_GATE: passed before Phase 0; re-checked after Phase 1 design._

| Principle                           | How this feature satisfies it                                                                                                                     | Gate                                                                        |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| I. Model never receives contents    | Peek returns counts, moments and type mixes. Node values never enter it. Subscript tokens do, because Principle II requires the legal-move list   | Test asserts a value held by exactly one node appears in no prompt (SC-006) |
| II. Model never authors a predicate | `Dimensions()` enumerates subscripts found by walking; `Predicate()` turns whitelisted tokens into a subscript prefix; hex tokens round-trip (R3) | Test asserts a fabricated token is refused                                  |
| III. Caps reported, never hidden    | Visit cap and depth cap both set `capped`; `Describe` words a capped count as a floor                                                             | Cap tests are P1, not polish (US2)                                          |
| IV. Test-first, deterministic       | Every task below writes its test first. `RLM.LLM.Null` plus a fixture global makes a whole decomposition deterministic                            | Phase gate per user story; no live model in any test                        |
| V. Replayable                       | A peek reads only the store and the predicate. No `$HOROLOG`, no `$RANDOM`                                                                        | Test peeks the same fixture twice and compares (US4 #4)                     |
| VI. Portable by default             | No `%AI.*`, no HTTP, no SQL in the new class                                                                                                      | Grep assertion in the E2E test                                              |

**Result**: no violations. One design change is needed but it strengthens
Principle II rather than weakening it — see Complexity Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/004-global-source/
├── plan.md              # this file
├── spec.md
├── research.md          # Phase 0, measured
├── data-model.md        # Phase 1
├── quickstart.md        # Phase 1
├── contracts/
│   └── source-global.md # Phase 1: the peek object's shape
└── tasks.md             # Phase 2, /speckit.tasks
```

### Source Code (repository root)

```text
src/RLM/
├── Source.cls                  # MODIFIED: Dimensions() gains an optional path
├── Source/
│   ├── Table.cls               # MODIFIED: signature only, behavior unchanged
│   └── Global.cls              # NEW: the whole feature
├── Engine.cls                  # MODIFIED: pass path at 1 call site
├── Slice.cls                   # MODIFIED: pass path at 2 call sites
└── Policy.cls                  # MODIFIED: pass path at 1 call site

src/UnitTest/RLM/
├── FixtureGlobal.cls           # NEW: builds ^||RLMTest with known structure
├── SourceGlobal.cls            # NEW: US1 dimensions, peek arithmetic
├── SourceGlobalCaps.cls        # NEW: US2 visit and depth caps
├── SourceGlobalAllow.cls       # NEW: US3 allowlist, one test per deny pattern
├── SourceGlobalMetric.cls      # NEW: US4 fanout entropy
├── SourceGlobalShape.cls       # NEW: US5 type mix, value moments, peek size
└── EndToEndGlobal.cls          # NEW: phase gate, full run under RLM.LLM.Null
```

**Structure Decision**: matches the existing layout exactly — sources under
`src/RLM/Source/`, one test class per user story under `src/UnitTest/RLM/`, named
after the story rather than the method. No new directories.

## Phase 1 design notes

**The peek object** is specified in `contracts/source-global.md`. It is a
`%DynamicObject` with `n`, `capped`, `depth`, `children` (count), `topFanout`
(array of at most 5 `{token, label, n}`), `dataNodes`, `pointerNodes`,
`valueLenMean`, `valueLenSd`, `subNumeric`, `subString`, `subList`. `n` and
`capped` are required by the `RLM.Source` contract; the rest is this store's
metric bag.

**Dimensions are computed at a path.** A global's level-2 subscripts differ per
level-1 slice, so `Dimensions()` must know where it is. See Complexity Tracking.

**One dimension per level**, named `s1`, `s2`, ... for the subscript position.
This keeps `RLM.Slice`'s "each dimension at most once per path" rule meaningful:
splitting twice on the same subscript position is exactly the no-op that rule
exists to forbid.

## Complexity Tracking

| Violation                                                                                                    | Why Needed                                                                                                                                                                                                                                                                                                                                                                                        | Simpler Alternative Rejected Because                                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `Dimensions()` gains an optional `path` argument, touching `Source`, `Table`, `Slice`, `Engine` and `Policy` | A global's children are path-dependent: the level-2 subscripts under `^G("2019-11-04")` are not those under `^G("2020-03-11")`. All four call sites currently call `Dimensions()` with no path, so a global could only ever advertise the root's children — and `RLM.Slice` would then refuse every legitimate level-2 slice, or resolve one to the wrong subtree. That is a Principle II failure | Caching the root's dimensions and hoping is wrong, not simpler. Having `Global` return a union of all subscripts seen at each level advertises moves that do not exist under a given parent, which violates the `Menu` rule that whatever is advertised must resolve. The argument defaults to `""`, so `Table` is unaffected and its behavior is unchanged — asserted by the existing 148 tests continuing to pass unmodified |

This is the finding the spec's last assumption anticipated: the seams held for
`Table` because a table's columns are the same everywhere, and the first genuinely
hierarchical store is what exposes the gap. Recording it here rather than working
around it inside `Global`.
