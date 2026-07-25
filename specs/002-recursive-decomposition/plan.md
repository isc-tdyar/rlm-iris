# Implementation Plan: Recursive decomposition

**Branch**: `002-recursive-decomposition` | **Date**: 2026-07-25 | **Spec**:
[spec.md](spec.md)
**Input**: Feature specification from
`/specs/002-recursive-decomposition/spec.md`

## Summary

Five capabilities the library lacks, each blocking the `gaia-iml` port and each
general beyond it: a recursive engine, bucketed dimensions over continuous
columns, a Markdown report with a rendered trace, root scoping, and a
store-readiness precondition.

The approach is deliberately small. Recursion becomes an explicit stack inside
`Run`, and root scoping then falls out of it for free — a scope is a non-empty
starting path, and the recursion already threads paths, resolves them through
`RLM.Slice`, and excludes their dimensions from candidates. Buckets widen a
predicate encoding that is private to one class. Report style is a property
consulted by three primitives. Readiness is a concrete method with a default, so
no existing source is edited.

Two defaults keep every existing caller byte-identical: `MaxDepth` = 1 and
`Style` = `"plain"`.

## Technical Context

**Language/Version**: InterSystems ObjectScript, IRIS 2026.1 community floor
**Primary Dependencies**: none beyond `%Library` / `%Dictionary` / `%SQL`. The
portable module's rule (Principle VI) forbids `%AI.*`, HTTP and SQL in
`RLM.Engine`, `RLM.Report`, `RLM.Policy` and `RLM.Trace`; SQL is confined to
`RLM.Source.Table`.
**Storage**: `^||RLM.Trace` process-private by default, `^RLM.Trace` when durable.
No new global, no new persistent class.
**Testing**: `%UnitTest` under `src/UnitTest/RLM`, run in the project's own
`rlm-iris` container (32805 → 1972). 93 tests green at the start of this feature.
**Target Platform**: any IRIS 2026.1+ instance, no AI Hub required
**Project Type**: ObjectScript library (IPM module `rlm-core`)
**Performance Goals**: prompt size independent of row count (already measured);
one bounded model round-trip per decision; peeks per decision bounded by
`MaxPeeksPerDecision` = 12 regardless of depth
**Constraints**: `RLM.Slice.MAXDEPTH` = 3 is the grammar ceiling and bounds
`MaxDepth` plus the scope's own length; the reserved synthesis slot is unreachable
from either budget pool
**Scale/Scope**: 6 source classes touched, 1 new source method, ~5 new report
methods, 5 new test classes. Acceptance is the prototype's 5 dimensions and 21
slices, verified in the port rather than here.

## Constitution Check

_GATE: must pass before Phase 0. Re-checked after Phase 1 — see below._

**I. The model never receives store contents.** Depth adds sub-calls, not row
access. Every new peek returns aggregates; the bucketed source's `SELECT` is
`COUNT`/`MIN`/`MAX`/`AVG` as before.

**II. The model never authors a predicate.** Bucket edges are declared by the
developer and bound as parameters (FR-008). A root scope is a caller-supplied
slice path resolved through `RLM.Slice`, not a `WHERE` string — which is why
research decision 4 rejects `RootWhere`.

**III. Caps are reported, never hidden.** Four new disclosures: slices not
reached for budget (FR-005), the bucket/parent sum gap from nulls, a not-ready
store's reason, and a rendered trace that finally shows a human the caps that
were only ever recorded (FR-011).

**IV. Test-first, deterministically.** Five phases, each ending on an E2E gate.
Traversal order is declaration order; nothing samples randomly.

**V. A run is replayable.** Depth is written to an existing trace field. A peek
stays a pure function of the store and the predicate, buckets included.

**VI. Portable by default.** `RLM.Engine` and `RLM.Report` gain no dependency.
Buckets are confined to `RLM.Source.Table`; `RenderTrace` reads `RLM.Trace`,
which is already inside the portable set.

**Result**: pass, no violations, Complexity Tracking not required.

**Re-check after Phase 1**: pass. The one design decision that could have breached
Principle II — how a caller scopes a run — was resolved toward the grammar
(research decision 4) precisely because the alternative put raw SQL past
`RLM.Slice`. Principle III gained obligations rather than losing any.

## Project Structure

### Documentation (this feature)

```text
specs/002-recursive-decomposition/
├── plan.md              # This file
├── spec.md              # Five user stories, FR-001..FR-017, SC-001..SC-007
├── research.md          # 7 decisions with rejected alternatives
├── data-model.md        # Frontier, bucket declaration, term encoding, trace depth
├── contracts/README.md  # Method signatures as contracts, with obligations
├── quickstart.md        # Runnable snippets per story
└── tasks.md             # /speckit.tasks output
```

### Source code

```text
src/RLM/
├── Engine.cls           # MODIFIED  recursion, rootPath, readiness gate, never-throw
├── Report.cls           # MODIFIED  Style, Bullet, Fenced, RenderTrace
├── Source.cls           # MODIFIED  Ready() concrete default
├── Source/Table.cls     # MODIFIED  AddBucketedDimension, term operators, NullCount
├── Slice.cls            # unchanged  (the scope resolves through it as-is)
├── Policy.cls           # unchanged  (called per slice; cannot tell)
├── Policy/Greedy.cls    # unchanged
├── Policy/LLM.cls       # unchanged
├── Trace.cls            # unchanged  (depth field already exists)
├── Decision.cls         # unchanged
└── Budget.cls           # unchanged  (CanSpend already answers FR-004)

src/UnitTest/RLM/
├── Engine.cls           # MODIFIED  depth-1 behaviour preserved
├── EndToEnd.cls         # MODIFIED  + phase-gate tests per story
├── FixtureNested.cls    # NEW  two-level store: colour at root, size within red
├── FixtureNotReady.cls  # NEW  reports itself unfit
├── SourceBucketed.cls   # NEW  bucket declaration, edges, sums, nulls
├── ReportStyle.cls      # NEW  plain byte-identity, markdown, indent, fenced
├── EngineRecursion.cls  # NEW  traversal order, depth threading, budget stop
└── Widget.cls           # MODIFIED  a nullable numeric column, for the null case
```

**Structure Decision**: the existing layout, unchanged. One class per concern
under `src/RLM`, tests mirroring it under `src/UnitTest/RLM`, loaded with
`$system.OBJ.LoadDir(...,"ck",,1)` — the `ck` qualifier is mandatory, since
without it classes import without compiling and `%UnitTest` skips them while
still reporting "All PASSED".

## Phase plan

Each phase is one user story, ends on an E2E gate, and leaves the suite green.

| Phase | Story | Gate                                                        |
| ----- | ----- | ----------------------------------------------------------- |
| 3     | US1   | Depth 2 over `FixtureNested`; depth 1 still byte-identical  |
| 4     | US2   | Buckets over `Widget.Price`; counts sum; nulls disclosed    |
| 5     | US3   | Markdown vs plain: same figures, `##`, nested bullets       |
| 6     | US4   | Scoped run confined and stated; bad scope refused call-free |
| 7     | US5   | Not-ready store costs zero calls; a throw returns a report  |

US1 must land first: US3's nesting, US4's scope-as-path and US5's abort-before-call
all sit on the traversal it builds. US2 is independent of US1 and could run in
parallel, but is sequenced second because the depth-2 fixture is more convincing
over a bucketed column, and because the prototype needs both.

## Risks

- **SC-002 byte-identity is the load-bearing assertion.** Every phase re-runs it.
  If the recursion changes the depth-1 document at all — a caveat's wording, a
  bullet's indent — the refactor is wrong, not the baseline.
- **`MAXDEPTH` = 3 minus the scope's length is a small budget.** A scoped run at
  `MaxDepth` = 2 from a one-component scope is exactly at the ceiling. The engine
  must refuse to push past it rather than let `RLM.Slice` refuse the path later,
  because the later refusal reads as a store problem.
- **Null rows in a bucketed dimension.** The temptation is an "unknown" bucket.
  It would have to be nameable in the grammar and would then be splittable, which
  is a larger change than disclosing a number.
