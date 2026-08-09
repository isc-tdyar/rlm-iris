# Feature Specification: lenses and run state

**Feature Branch**: `008-lenses-and-state`
**Created**: 2026-08-09
**Status**: Draft
**Input**: M6, generalizing the leaf view and giving a run a scratchpad

## Why this milestone exists

The package has been building one instantiation of RLM and calling it the whole
thing. Everything M0–M5 shipped assumes a slice is characterized by aggregate
statistics, and that assumption is baked into the source contract as a
prohibition: "A Source never returns rows, nodes or values -- only statistics."

Statistics are what you compute when a slice is too large to read. That is the
pathological case, not the design centre, and treating it as the design centre
excludes most of the questions people actually have. Which patients meet the
inclusion criteria; which messages failed and why; which rows look wrong; what
this legacy column actually means. No aggregate answers any of them, because
each is a judgement **over** records rather than an aggregation **of** them.

What makes reading affordable is the decomposition the package already does. A
slice that starts as 400M rows is, a few levels down, a few dozen — and a few
dozen fit. So the recursion was always the thing that earns the right to read;
the engine simply never exercised it, because the leaf could only ever summarize.

The second gap is that a run leaves nothing behind. Sub-calls are independent map
operations: each sees its own subset, and whatever it learns exists only inside
the report paragraph it produced. That is a property REPL-based RLM cannot avoid
— a Python local has nowhere to put a finding that outlives the call — but it is
not a property of this substrate. A global can hold findings keyed by the slice
that produced them, which makes a decomposition an artifact rather than a
paragraph.

## What this does not change

The context bound, which was always the real claim, is untouched. A view is
capped at N records, so what the model accumulates is still slices inspected
times cap-per-slice, and never anything proportional to the size of the store.

The governed path is untouched and stays the default. `RLM.Lens.Stats` is what an
un-configured engine uses, so a store under a PHI constraint or an extent too
large to read at any depth gets exactly the guarantee the package started with.
What changes is that it is now a **choice** rather than the only behaviour, and a
store that can be read says so by being handed a different lens.

## User Scenarios & Testing _(mandatory)_

### User Story 1 - Answer from records once the subset is small (Priority: P1)

An analyst asks which orders in a slice were rejected and why. The traversal
divides until a slice holds fewer records than the cap; at that point the
sub-call receives the records themselves and answers from them rather than
describing their distribution.

**Why this priority**: This is the milestone. A decomposition whose leaves are
still summaries has not done the thing the recursion was for.

### User Story 2 - A governed store is unchanged (Priority: P1)

A run over a PHI-bearing extent is configured with no lens. Every prompt in the
run carries aggregates and no record reaches the model, exactly as before.

**Why this priority**: The package's existing guarantee is absolute for the
stores that depend on it. A widening that weakened the default would break the
only reason those stores could use it at all.

### User Story 3 - A slice too large to read degrades visibly (Priority: P1)

A slice above the cap, or one whose count came back capped, is described by its
statistics instead — and the report says which slices those were.

**Why this priority**: Constitution II, one level up from a count. A view that
showed 20 of 4,000 records without saying so would let the model read a partial
set as a complete one, and every claim drawn from it inherits the error.

### User Story 4 - A run leaves a queryable artifact (Priority: P2)

After a run, the caller reads per-slice findings from `RLM.State` rather than
re-parsing the report, and a run that exhausted its budget can be resumed against
what it already established.

**Why this priority**: Valuable and enabling, but the run is still correct
without it, so it does not gate the milestone.

### User Story 5 - A pre-lens source keeps working (Priority: P1)

A source written before this milestone, which does not implement `Materialize`,
runs unchanged under any lens.

**Why this priority**: The same obligation `Ready()` and `NullCount()` were built
to satisfy. An existing source must not need editing to stay correct.

## Requirements _(mandatory)_

- **FR-001** `RLM.Lens` is an abstract seam with `View`, `Instructions` and
  `Kind`. The engine holds one and uses it for every leaf.
- **FR-002** `RLM.Lens.Stats` returns `Source.Describe` byte-for-byte and is the
  engine's default, so an existing run is unchanged in every byte.
- **FR-003** `RLM.Lens.Contents` returns records when the slice fits and falls
  back to statistics when it does not.
- **FR-004** Every fallback and every truncation is disclosed to the report.
- **FR-005** `Source.Materialize` is concrete and returns nothing, so a source
  that predates it degrades rather than errors.
- **FR-006** `Source.Fits` is concrete, refuses a capped peek regardless of its
  count, and is overridable by a store with a stranger notion of size.
- **FR-007** A materialized view never exceeds its cap, and reports truncation
  when there was more to return.
- **FR-008** An implementation of `Materialize` renders only columns the source
  has declared, so a slice remains an authorizable unit.
- **FR-009** `Instructions` come from the lens, because a model told to describe
  statistics while holding records produces a summary of data it was meant to
  reason over, and the output still reads like an analysis.
- **FR-010** `RLM.State` records findings keyed by slice path, shares the trace's
  run id, and is durable when the trace is.
- **FR-011** A slice whose sub-call failed is still recorded, so a resumed run can
  tell it from a slice the budget never reached.
- **FR-012** State exists after a refused run, so a caller may read it
  unconditionally.

## Open questions

- **Charging for a view.** A materialized view is a real read and is currently
  uncharged, on the grounds that the call budget already bounds how many leaves
  there can be. That holds while one view is one query; a lens that fanned out
  would need its own ceiling.
- **Replay under a contents lens.** Peeks are pure functions of the store and so
  is `Materialize`, so replay against an unchanged store reproduces the view. A
  store that has changed is already caught by the fingerprint. What is not yet
  decided is whether a durable trace should record materialized content as a
  sidecar, which would make replay independent of the store entirely at the cost
  of putting records in the trace.
- **Sub-engines.** `Run(question, .traceId, rootPath)` is already a complete run
  confined to one slice, so a leaf could recurse into a full sub-engine rather
  than a single sub-call. The traversal covers the same ground today, so this is
  only worth doing if a sub-engine needs its own budget or its own lens — for
  instance statistics at the top of a store and records at the bottom.
