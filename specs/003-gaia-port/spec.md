# Feature Specification: Port the gaia-iml prototype onto rlm-iris

**Feature Branch**: `003-gaia-port`
**Created**: 2026-07-25
**Status**: Draft
**Input**: User description: "Port the gaia-iml prototype onto the rlm-iris
library: rewrite Gaia.RLM as an RLM.Source subclass, delete Gaia.Slice, drop the
duplicated budget and trace and Ask and WriteReport machinery, and decide RLM2
fate."

## Context

`rlm-iris` was extracted from `gaia-iml`. Until the prototype runs on the
extracted library, the extraction is unproven: `rlm-iris` has never been asked to
characterize a store it was not written alongside, so nothing yet shows its seams
are in the right places.

The prototype holds, in `src/Gaia/`, its own version of nearly everything the
library now provides — a call budget, a recursion trace, a one-round-trip `Ask`,
a slice grammar, a report writer, a recursion. Roughly 700 of its 1,525 lines are
the library re-derived. What is genuinely Gaia's is smaller: five domain
dimensions over ESA's epoch-rejection statistics, a sixteen-aggregate query,
eleven self-labelling metric lines with the units and traps spelled out, and a
completeness guard that refuses to report on a partially-scored table.

This feature moves the first set out and keeps the second. The measure of success
is not that the port works — it is what the port reveals about the library.

**Cross-repository.** Spec artifacts live here, in `rlm-iris`. The code lands in
`/Users/tdyar/ws/gaia-iml`, for which write permission was given explicitly. Any
library defect the port exposes is fixed here and re-specified, not worked around
there.

## User Scenarios & Testing _(mandatory)_

### User Story 1 - Gaia is a store the library can read (Priority: P1)

A `Gaia.Source` presents the Gaia quality table to the library: the ways it may
be divided, what one slice looks like in aggregate, how those aggregates must be
worded, how mixed a slice still is, and whether the table is fit to report on at
all. Nothing about recursion, budgets, traces or reports is in it.

**Why this priority**: everything else depends on it, and it is the whole test of
whether `RLM.Source` is the right contract. If a real store cannot be expressed
through those six methods without reaching around them, the abstraction is wrong.

**Independent Test**: instantiate `Gaia.Source` against `GaiaQualityScored` and
exercise it with no engine, no policy and no model: `Dimensions()` returns six
dimensions, `Peek()` over a resolved slice returns counts that sum to their
parent, `Describe()` names every figure, `SplitMetric()` falls when a slice is
narrowed, and `Ready()` refuses a table whose predictions are incomplete.

**Acceptance Scenarios**:

1. **Given** the scored table, **When** `Dimensions()` is called, **Then** it
   returns `reject_level`, `epoch_count`, `signal_quality`, `model_confidence`,
   `variability` and `detection`, and every child's label carries its numeric
   range.
2. **Given** a slice name in the ordinary grammar, **When** `RLM.Slice.Resolve`
   translates it, **Then** the predicate restricts the same rows the prototype's
   hand-written `WHERE` did, and a name the store does not offer is refused with
   no query run.
3. **Given** a table where `pred_reject` is populated for fewer rows than the
   table holds, **When** `Ready(.reason)` is called, **Then** it returns 0 and
   `reason` states how many rows of how many are scored and what to run.
4. **Given** the whole survey and a narrower slice within it, **When**
   `SplitMetric()` is called on each, **Then** the metric is 0-1 and is lower for
   the slice that mixes fewer populations.
5. **Given** a peek of an empty slice, **When** `Describe()` renders it, **Then**
   it says the slice is empty rather than rendering zeros as measurements.

---

### User Story 2 - The prototype's provider becomes an RLM.LLM (Priority: P1)

`Gaia.LLM.AIHub` presents AI Hub's `%AI.Agent` to the library through the
one-method `RLM.LLM` contract: text in, text out, never throwing.

**Why this priority**: the port cannot make a single call without it, and it is
the first real exercise of the claim that `RLM.Engine` has no `%AI.*` dependency.
If the engine needs editing to accommodate an AI Hub provider, the portability
principle is decorative.

**Independent Test**: call `Complete()` with instructions and a prompt and get
text back with an OK status; call it with a broken configuration and get `""`
with a bad status rather than an exception.

**Acceptance Scenarios**:

1. **Given** `OPENAI_API_KEY` is set, **When** `Complete()` is called, **Then**
   it returns the model's text and `Model` names the model that produced it.
2. **Given** no API key, **When** `Complete()` is called, **Then** it returns
   `""` with a status naming the failure, and does not throw.
3. **Given** the engine's class definition, **When** it is searched for `%AI.`,
   **Then** there are no matches — the dependency lives only in this adapter.

---

### User Story 3 - The two entry points run on the library (Priority: P2)

`Gaia.RLM.Audit()` and `Gaia.RLM.Triage()` still take an output path and still
write a Markdown report over the same table, but they now construct an
`RLM.Engine` over a `Gaia.Source` and return what it produces. The recursion, the
budget, the trace, the report assembly and the file write are all the library's.

**Why this priority**: this is where the ~700 duplicated lines actually leave,
and where the port either reproduces the prototype's reports or shows what the
library cannot yet say.

**Independent Test**: run both entry points with a scripted `RLM.LLM.Null` and
get a complete report, deterministic byte for byte, with the trace and caveats
present; then run `Audit()` once against the real provider over all 74,998 rows.

**Acceptance Scenarios**:

1. **Given** a scripted null provider, **When** `Audit()` runs twice, **Then**
   both reports are byte-identical.
2. **Given** the real provider, **When** `Audit()` runs, **Then** the report
   names the store, the slices examined, an answer, and the limits of the
   analysis, and states the calls spent.
3. **Given** `Triage()`, **When** it runs, **Then** the run is confined to the
   57,099 detections by the slice name `detection:b1` rather than a SQL fragment,
   and the report says which subset it describes.
4. **Given** a call budget too small to reach every slice, **When** the run ends,
   **Then** the report names the slices that were dropped rather than omitting
   them silently.
5. **Given** the ported tree, **When** `src/Gaia/` is searched, **Then** no call
   budget, recursion trace, `Ask`, `Indent` or `WriteReport` remains in it.

---

### User Story 4 - The duplicated grammar goes (Priority: P3)

`Gaia/Slice.cls` is deleted. `Gaia.RLM2`, the only thing that used it, resolves
slice names through `RLM.Slice` against `Gaia.Source` instead.

**Why this priority**: it is the clearest duplication in the prototype — two
classes doing the same whitelist walk over the same dimensions — but nothing else
is blocked on removing it.

**Independent Test**: every slice name `Gaia.Slice.Resolve` accepted resolves
through `RLM.Slice.Resolve`, every name it refused is still refused, and
`Gaia.RLM2.Audit()` still produces a report.

**Acceptance Scenarios**:

1. **Given** the injection attempt `reject_level:severe' OR 1=1 --`, **When** it
   is resolved, **Then** it is refused as a name the store does not offer, and
   the refusal carries the grammar.
2. **Given** a nested name, **When** it is resolved, **Then** the predicate
   restricts both components and the label names both.
3. **Given** the ported tree, **When** it is searched for `Gaia.Slice`, **Then**
   there are no matches.

---

### User Story 5 - What survives is documented as what it is (Priority: P3)

The prototype's README, its module manifest and `Gaia.RLM2`'s class comment say
which parts are the library and which are Gaia's, and `rlm-iris` records that a
store outside its own test suite runs on it.

**Why this priority**: a port whose documentation still describes the pre-port
design misleads the next reader more than no documentation would, but no
behaviour depends on it.

**Acceptance Scenarios**:

1. **Given** the prototype README, **When** it describes the RLM analysis,
   **Then** it names `rlm-iris` as the dependency and states what `Gaia.Source`
   contributes.
2. **Given** `Gaia.RLM2`'s class comment, **When** it contrasts the two
   implementations, **Then** the contrast is between the library's engine and
   model-driven delegation, not between two hand-written recursions.

---

### Edge Cases

- **A dimension's bucket edges leave rows uncovered.** `reject_fraction` is
  non-null on every scored row today, so the gap is zero — but the report must
  disclose it if that stops being true, which means wiring the library's
  `NullCount()` rather than assuming it.
- **A slice is empty.** Several dimensions have tails that are empty
  within some parents. An empty slice must be described as empty, not summarized
  from zeros, and must not cost a model call.
- **The table is scored but empty.** `Ready()` must distinguish "no rows" from
  "rows without predictions": the first is a pipeline that never ran, the second
  one that ran partially, and the remedies differ.
- **The provider is absent.** The prototype's contract is that the report is a
  bonus deliverable whose absence must not disturb `result.csv`. `Run` never
  throwing is what preserves that, and it must be verified here, not assumed.
- **A slice path reaches the grammar ceiling.** Gaia declares six dimensions and
  `RLM.Slice.MAXDEPTH` is 3, so paths bottom out before the dimensions do. The
  report must name what it did not reach.
- **`detection` and `variability` divide the same column.** Within
  `detection:b1`, splitting on `variability` leaves `b0` empty by construction —
  the two dimensions are not independent. This is the concrete empty-slice case
  the port tests against, and the engine must not spend a call on it.

## Requirements _(mandatory)_

### Functional Requirements

- **FR-001**: `Gaia.Source` MUST extend `RLM.Source.Table` and declare the
  prototype's five dimensions as bucketed dimensions over `reject_fraction`,
  `n_bp`, `bp_snr`, `pred_sigma` and `pct_change`, with the prototype's prose as
  the child labels.
- **FR-001a**: `Gaia.Source` MUST declare a sixth dimension, `detection`, over
  `pct_change` with one breakpoint at 100, so that the population `Triage` has
  always described is nameable as a slice. `variability` stays as declared.
- **FR-002**: `Gaia.Source` MUST override `Peek()` to return the prototype's
  sixteen aggregates, and MUST include the row count the library's disclosure
  rules read.
- **FR-003**: `Gaia.Source` MUST override `Describe()` to emit the prototype's
  eleven self-labelling metric lines unchanged, including the units and the two
  warnings that a coefficient of variation is not an uncertainty and a prediction
  error is not a reject fraction.
- **FR-004**: `Gaia.Source` MUST override `SplitMetric()` to return the slice's
  reject-fraction spread relative to the survey-wide spread, clamped to 0-1, and
  MUST cache the survey-wide figure for the duration of a run.
- **FR-005**: `Gaia.Source` MUST override `ShouldSplit()` to reproduce the
  prototype's rule: subdivide only when the slice is at least as spread as the
  survey and holds at least 400 rows.
- **FR-006**: `Gaia.Source` MUST override `Ready()` to refuse a table with no
  rows and a table whose scored-row count is below its row count, with a reason
  naming both figures and the routine to run.
- **FR-007**: `Gaia.RLM` MUST retain `Audit()` and `Triage()` with their current
  signatures and questions, implemented by constructing an `RLM.Engine` over a
  `Gaia.Source`.
- **FR-008**: `Gaia.RLM` MUST NOT contain a call budget, a recursion trace, a
  model-call wrapper, an indent helper, a recursion, or a file writer.
- **FR-009**: `Gaia.LLM.AIHub` MUST implement `RLM.LLM.Complete()` over
  `%AI.Agent`, returning `""` with a status on any failure and never throwing.
- **FR-010**: `Triage()` MUST scope its run with the slice name `detection:b1`
  passed as `Run`'s third argument, not with a SQL predicate, and that slice MUST
  select the same 57,099 rows the prototype's `pct_change > 100` selected.
- **FR-011**: `Gaia/Slice.cls` MUST be deleted, and `Gaia.RLM2` MUST resolve
  slice names through `RLM.Slice` against a `Gaia.Source`.
- **FR-012**: `Gaia.RLM2` MUST keep its own delegation budget and trace. It is
  not an `RLM.Engine` run — the model owns the recursion — so the library has
  nothing to lend it there, and the two implementations existing to be compared
  is why it survives at all.
- **FR-013**: The prototype MUST reach the library by pinned reference rather than
  by copy: a git submodule at `lib/rlm-core` loaded before `src/`, plus a
  `<Dependencies>` entry naming `rlm-core` for the IPM path. No class under
  `RLM.*` may exist as a file in `gaia-iml`'s own `src/`.
- **FR-014**: Every library defect the port exposes MUST be fixed in `rlm-iris`
  with a test, not worked around in `Gaia.Source`.

### Key Entities

- **Gaia.Source**: the quality table as a decomposition source. Six bucketed
  dimensions, a sixteen-aggregate peek, eleven metric lines, a relative spread
  metric, and a readiness check over prediction completeness.
- **Gaia.LLM.AIHub**: one method over `%AI.Agent`, the only place `%AI.*` is
  named in the ported path.
- **Gaia.RLM**: two entry points and the engine configuration behind them.
- **Gaia.RLM2**: the delegating counterpart, unchanged in kind, rebased onto the
  library's grammar.

## Success Criteria _(mandatory)_

### Measurable Outcomes

- **SC-001**: `Gaia.Source` declares 6 dimensions and 22 children, counted from
  `Dimensions()` and printed rather than asserted against a constant. The
  prototype declares 5 × 4 = 20; the sixth dimension is `detection`, and why it
  is needed is research decision 3. The "21 slices" figure this spec first
  carried was wrong and did not reconcile with the prototype's own
  `Dimensions()`.
- **SC-002**: `src/Gaia/` loses at least 500 lines, and every line it loses is
  library machinery rather than domain knowledge. Both figures reported.
- **SC-003**: `Audit()` under a scripted provider is byte-identical across two
  runs. The prototype could not claim this: it set no temperature.
- **SC-004**: `Audit()` against the real provider produces a report over all
  74,998 sources whose figures reconcile — slice counts sum to their parent, and
  any gap is disclosed.
- **SC-005**: `RLM.Engine.cls` contains no occurrence of `%AI.` after the port,
  verified by search rather than by inspection.
- **SC-006**: Every slice name the deleted grammar accepted still resolves, and
  every name it refused is still refused. Measured over the whole slice
  enumeration plus the injection attempts the old tests carried.
- **SC-007**: The prototype's test suite passes and the library's 136 tests still
  pass, after every phase.

## Assumptions

- **Bucket tokens become ordinals.** The library names bucketed children `b0`…`bn`
  on purpose, so rewording a label cannot invalidate a trace that named the child.
  The prototype used semantic tokens (`severe`, `clean`). Reports read labels, so
  their prose is unaffected; trace rows will read `reject_level:b3` where they read
  `reject_level:severe`. Accepted rather than changed — a trace naming a token
  whose meaning can be edited is the failure the ordinals prevent.
- **Report bodies will not be byte-identical to the prototype's.** They are
  model-written, the prototype set no temperature, and the ported path cannot:
  `%AI.Agent.Chat` exposes none (research decision 2). Determinism is therefore
  asserted against `RLM.LLM.Null` only, which the prototype could not do at all.
  A frozen golden fixture is therefore a scripted-provider fixture, not a
  recording of a real run. The baselines are preserved at `data/out-baseline/`
  and outside the repository.
- **`Gaia.Analyst` is out of scope.** It is the failed SQL-toolset approach kept
  as the counterexample the README argues from, and it depends on the library not
  at all.
- **`Gaia.Tools.Survey` and `Gaia.Tools.SliceAnalyst` stay.** They are RLM2's
  toolset, and RLM2 stays.
- **The engine's budget replaces `MAXCALLS` and its `MaxDepth` replaces
  `MAXDEPTH`.** The prototype's 18-call, depth-3, one-synthesis-reserved shape is
  expressible in `RLM.Budget` and `RLM.Engine.MaxDepth` as they stand.
- **`gaia-iml-iris` is the container for this work**, as `rlm-iris` is for the
  library. They are never crossed.
