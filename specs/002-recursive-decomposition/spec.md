# Feature Specification: Recursive decomposition

**Feature Branch**: `002-recursive-decomposition`
**Created**: 2026-07-25
**Status**: Draft
**Input**: M1.5 — the five library gaps that block hosting the `gaia-iml`
prototype: a recursive engine, a bucketed source, a Markdown report with a
rendered trace, root scoping, and a store-readiness precondition.

## Why this feature exists

A survey of the `gaia-iml` prototype against the library found the port blocked
on five missing abstractions, not on prototype-side untidiness. Everything the
library already covers deletes cleanly from the prototype — its slice grammar,
its budget, its trace, its file writer, its LLM adapter. What is left is five
things the library cannot express at all, and each is a general capability rather
than a gaia quirk:

| Gap                             | Why it is general                        |
| ------------------------------- | ---------------------------------------- |
| Recursion below the root        | Any store deeper than one level          |
| Continuous columns as buckets   | Most real numeric tables                 |
| Markdown output, rendered trace | Any report read outside a terminal       |
| Scoping the root                | Any question about part of a store       |
| Store-readiness precondition    | Any store present but unfit to report on |

The prototype is the acceptance test for the feature, not its purpose.

## User Scenarios & Testing _(mandatory)_

### User Story 1 - Decompose below the root (Priority: P1)

A store whose interesting structure is two levels down gets decomposed to that
depth. The engine asks the policy for a split at the root, then asks again for
each child slice worth splitting further, threading the dimensions already used
down each branch so no branch splits twice on the same one.

**Why this priority**: Today `RLM.Engine.Run()` decides once and loops the
children flat. It is a one-level decomposition wearing the word "recursive". The
prototype's own shipped output reaches depth 2, so no other story can be
validated against it until this exists. `Candidates(path)` already accepts a path
and tracks used dimensions; nothing has ever called it with one.

**Independent Test**: Run the fixture store whose depth-2 slices have metrics far
below their parents'. Assert the trace holds decision rows at depth 0 and depth
1, that the depth-1 decision does not re-choose the root's dimension, and that a
depth-2 slice's aggregates appear in the report.

**Acceptance Scenarios**:

1. **Given** a store where `colour` separates at the root and `size` separates
   within red, **When** a run executes with a depth limit of 2, **Then** the
   trace holds a decision at depth 0 choosing `colour` and a decision at depth 1
   choosing `size`, and the report describes `colour:red/size:small`.
2. **Given** a slice whose metric is already low, **When** the engine considers
   it, **Then** no decision is made for it and no peek is spent asking: a slice
   that no longer mixes populations has nothing left to separate.
3. **Given** a branch that has already split on `colour`, **When** candidates are
   computed for one of its children, **Then** `colour` is absent from them.
4. **Given** a depth limit of 1, **When** a run executes, **Then** the behaviour
   is exactly today's: one root decision and flat children.
5. **Given** a budget that runs out mid-recursion, **When** a slice cannot be
   funded, **Then** the run stops descending, still synthesizes, and the report
   names the slices it did not reach along with the statistics it already had for
   them.

---

### User Story 2 - Split a continuous column into buckets (Priority: P2)

A store declares a dimension as a numeric property plus ordered breakpoints, and
the library turns it into named ranged children.

**Why this priority**: `RLM.Source.Table` derives children with
`SELECT DISTINCT`, which is right for a categorical column and useless for a
continuous one — on the prototype's `reject_fraction` it would enumerate roughly
75,000 distinct doubles as tokens. This is the shape most real numeric tables
need, and without it the prototype has no store at all.

**Independent Test**: Declare a bucketed dimension over the test table's `Price`
with breakpoints; assert the children are the declared buckets in declared order,
that their counts sum to the parent's, and that a value sitting exactly on a
breakpoint lands in exactly one bucket.

**Acceptance Scenarios**:

1. **Given** breakpoints 10 / 50 / 100 on a numeric property, **When**
   `Dimensions()` is called, **Then** four children are returned in ascending
   order with labels naming their ranges.
2. **Given** a bucketed dimension, **When** a slice is peeked, **Then** the
   predicate binds the breakpoints as query parameters rather than splicing them
   into SQL text.
3. **Given** a row whose value equals a breakpoint exactly, **When** every bucket
   is peeked, **Then** the row is counted in exactly one of them and the bucket
   counts sum to the unsliced count.
4. **Given** a bucketed and a categorical dimension on one store, **When** a
   policy compares them, **Then** both are ordinary candidates and neither
   requires the policy to know which kind it is.
5. **Given** a bucket containing no rows, **When** it is peeked, **Then** it
   reports `n=0` rather than an error, and a policy scoring it is told the
   evidence was thin instead of being handed a division by zero.

---

### User Story 3 - A report a human reads outside a terminal (Priority: P3)

A run can emit GitHub-flavored Markdown, with the recursion rendered as a
readable trace and the nesting of the slices preserved.

**Why this priority**: `RLM.Report` writes plain text with `-----` underlines and
a fixed five-section skeleton. The prototype's deliverable is a Markdown document
committed beside a data pipeline. Separately, nothing in the library renders an
`RLM.Trace` at all — rows are recorded and never read by a human, which leaves
the disclosure principle half-delivered.

**Independent Test**: Run the fixture store to depth 2 and assert the output has
`##` headings, a fenced trace block naming every step with its role and depth,
and nested bullets whose indentation matches slice depth.

**Acceptance Scenarios**:

1. **Given** Markdown style is selected, **When** the report is written, **Then**
   headings are `##` and the plain-text underlines do not appear.
2. **Given** plain style, **When** the report is written, **Then** the output is
   byte-identical to what `RLM.Report` produces today.
3. **Given** a depth-2 decomposition, **When** slice findings are written,
   **Then** a depth-2 slice is indented under its parent rather than flattened to
   the top level.
4. **Given** a finished run, **When** its trace is rendered, **Then** every
   decision, sub-call and synthesis appears with its role and depth, and a
   declined split appears with its reason.
5. **Given** a report written to a file, **When** it is read back, **Then**
   non-ASCII characters survive intact.

---

### User Story 4 - Ask about part of a store (Priority: P4)

A caller can restrict a whole decomposition to a subset of the store without
being able to hand raw predicate text past the slice grammar.

**Why this priority**: `Run()` unconditionally peeks the whole store. Half the
prototype's entry points decompose a subset — one looks only at the rows above a
threshold. The restriction is the caller's and not the model's, which is what
makes it expressible without weakening Principle II.

**Independent Test**: Scope a run to one dimension token; assert every peek in
the run, root included, is confined to it, that the report says the store was
scoped, and that the scope never reaches the model as text to manipulate.

**Acceptance Scenarios**:

1. **Given** a run scoped to `colour:red`, **When** the root is peeked, **Then**
   the count is red's and not the store's.
2. **Given** a scoped run, **When** candidates are computed, **Then** the scoping
   dimension is not offered as a way to split.
3. **Given** a scoped run, **When** the report is written, **Then** the scope is
   stated where the store is described, because a reader shown a subset's figures
   as the store's draws a wrong conclusion.
4. **Given** a scope expressed as anything other than resolvable slice
   components, **When** the run starts, **Then** it is refused before any model
   call.

---

### User Story 5 - Refuse to report on a store that is not ready (Priority: P5)

A store can declare itself unfit to be reported on, and a run over it fails
loudly instead of producing a confident document about whichever subset happened
to be usable.

**Why this priority**: The prototype guards this explicitly and its comment gives
the reason: silently averaging over the rows that happen to have predictions
produces a document that is both confident and wrong. The library has
`peek.error` for one failed peek and `peek.capped` for a truncated count; "the
store is present but not fit to report on" is a third state with no
representation. It is last because it is a guard rather than a capability.

**Independent Test**: A fixture store that reports itself not ready; assert the
run makes no model call, returns a report saying why, and that flipping the store
to ready makes the same run proceed.

**Acceptance Scenarios**:

1. **Given** a store that reports itself not ready, **When** a run starts,
   **Then** no model call is made and the reason is returned to the caller.
2. **Given** a store that does not implement the check, **When** a run starts,
   **Then** it proceeds — readiness is opt-in, so no existing store changes
   behaviour.
3. **Given** a source that throws rather than returning an error, **When** a run
   executes, **Then** the caller receives a report saying the analysis was
   unavailable instead of an exception, so a decomposition embedded in a larger
   pipeline cannot take that pipeline down.

### Edge Cases

- A slice whose only remaining candidate has one child is not splittable; the
  existing eligibility rule already excludes it, and it must still hold at depth.
- A recursion that would exceed `RLM.Slice.MAXDEPTH` (3): the engine's depth limit
  is its own, but the grammar's ceiling must not be silently exceeded.
- Two model calls left and a split that would produce four children: the split
  must not be chosen if it cannot fund at least one child, or the run pays for a
  decision it cannot act on.
- Breakpoints given out of order, duplicated, or empty.
- A bucketed dimension over a nullable column: rows with no value belong to no
  bucket, so the bucket counts do not sum to the parent's, and the gap must be
  disclosed rather than absorbed.
- A scope that selects zero rows.
- Markdown special characters in a slice label.

## Requirements _(mandatory)_

### Functional Requirements

- **FR-001**: `RLM.Engine` MUST decompose recursively, deciding a split per slice
  rather than only at the root, up to a configurable depth whose default
  preserves today's one-level behaviour.
- **FR-002**: The engine MUST thread the dimensions already used on a path into
  candidate computation, so no branch splits twice on the same dimension.
- **FR-003**: The engine MUST consult the source on whether a slice is worth
  splitting before spending a decision on it.
- **FR-004**: The engine MUST NOT choose a split it cannot fund at least one
  child of.
- **FR-005**: A slice reached but not analyzed for budget reasons MUST appear in
  the report with the statistics already known for it, not be omitted.
- **FR-006**: Every decision at every depth MUST be traced with its depth and its
  slice key, declines included.
- **FR-007**: A source MUST be able to declare a dimension as a property plus
  ordered breakpoints, yielding ranged children in ascending order with
  self-describing labels.
- **FR-008**: Bucket boundaries MUST be half-open so every value falls in exactly
  one bucket, and MUST be bound as query parameters rather than concatenated into
  predicate text.
- **FR-009**: A bucketed dimension MUST be indistinguishable from a categorical
  one to a policy.
- **FR-010**: `RLM.Report` MUST support a Markdown style alongside its current
  plain style, with the plain style byte-identical to today's output.
- **FR-011**: `RLM.Report` MUST be able to render an `RLM.Trace` as a
  human-readable block naming each step's role, depth, slice and outcome.
- **FR-012**: Slice findings MUST be indented by depth so nesting survives into
  the rendered report.
- **FR-013**: `RLM.Engine.Run` MUST accept an optional root scope expressed as
  slice components, resolved through `RLM.Slice` and refused if it does not
  resolve.
- **FR-014**: A scoped run MUST state its scope wherever it describes the store,
  and MUST NOT offer the scoping dimension as a candidate split.
- **FR-015**: `RLM.Source` MUST offer an overridable readiness check whose default
  is "ready", and `RLM.Engine` MUST abort before any model call when a store
  reports itself not ready, returning the reason.
- **FR-016**: `RLM.Engine.Run` MUST NOT propagate an exception from a source, a
  policy or a provider to its caller; it MUST return a report saying the analysis
  was unavailable and why.
- **FR-017**: No requirement above may place `%AI.*`, HTTP or SQL into
  `RLM.Engine`, `RLM.Report`, `RLM.Policy` or `RLM.Trace`.

### Key Entities

- **Depth-limited path**: an ordered list of `dimension:token` components plus the
  set of dimensions already consumed along it. What the engine threads downward
  and what the trace records per row.
- **Bucketed dimension**: a token name, a numeric property, and an ordered list
  of breakpoints. Expands to one half-open ranged child per interval.
- **Root scope**: a caller-supplied list of slice components applied to every peek
  in a run, including the root's.
- **Readiness verdict**: ready, or not ready with a reason. A property of the
  store, evaluated once per run.
- **Report style**: plain or Markdown. Chooses heading, indentation and fenced
  block rendering; changes no figure.

### Out of scope

- **Model-planned heterogeneous decomposition.** The prototype's second variant
  has its model name arbitrary slice paths across different dimensions in one
  plan. `RLM.Policy.ChooseSplit` returns one dimension, and that narrowness is
  Principle II's mechanism. Hosting it needs a second seam, which is its own
  feature or a deliberate decision not to have one.
- **Per-role model selection.** The prototype runs sub-calls on a cheaper model
  than the root. `RLM.Trace` already records a model per row as though it could
  vary; wiring it belongs with M5 and the AI Hub module.
- **Learning a policy from traces.** M3.

## Success Criteria _(mandatory)_

### Measurable Outcomes

- **SC-001**: The fixture store decomposes to depth 2 and the depth-2 slice's
  aggregates appear in the report — measured on the trace's depth column, not by
  reading prose.
- **SC-002**: A run at the default depth produces a report byte-identical to the
  one this feature's parent produced, so recursion is opt-in for existing
  callers.
- **SC-003**: A bucketed dimension over 10,000 rows of a continuous column yields
  the declared number of children and their counts sum to the parent's exactly.
- **SC-004**: The Markdown and plain renderings of one run differ only in
  formatting: every figure and every caveat present in one is present in the
  other.
- **SC-005**: In a scoped run, no figure a reader sees is presented as the whole
  store's; every one is labelled with the scope.
- **SC-006**: A store that reports itself not ready costs zero model calls.
- **SC-007**: The prototype's five dimensions, 21 slices and both entry points are
  expressible against the library with no class of its own beyond one
  `RLM.Source` subclass and a caller script. This is the feature's reason for
  existing and is verified in the port, not here.

## Assumptions

- The depth limit defaults to 1 — today's behaviour — so this feature cannot
  change an existing caller's output merely by existing.
- `RLM.Slice.MAXDEPTH` (3) stays the grammar's hard ceiling; the engine's depth
  limit is bounded by it rather than replacing it.
- Bucket ranges are half-open lower-inclusive (`lo <= v < hi`), the convention the
  prototype uses, so its labels port unchanged.
- Readiness is a property of the store and not of the question, so it is checked
  once per run.
- The prototype's report bodies are model-authored prose with no temperature set,
  so byte-identical output against them is not a goal. The deterministic parts —
  `Describe()` for every slice, the slice grammar, the provenance section — are.
