# Feature Specification: Split-choice policy

**Feature Branch**: `001-split-policy`
**Created**: 2026-07-25
**Status**: Draft
**Input**: `RLM.Policy`: pluggable split-choice policy with a Greedy baseline.

## Context

Today the engine makes one plan call in which the language model both decides
_how_ to decompose the store and names every slice it wants. Two problems follow
from bundling those decisions.

The model spends budget on navigation. Choosing which dimension separates a
population is a comparison of numbers the store already computed; paying a model
call for it leaves fewer calls for the part only a model can do, which is saying
what the numbers mean.

And there is nothing to compare a run against. If a decomposition is poor, no one
can tell whether the model chose badly or the store offered nothing better,
because there is no alternative arm on the record. A policy that costs no model
call gives every run a baseline.

A policy is also the thing a learned policy would later replace, so introducing
the seam now is what makes the trace worth recording.

## User Scenarios & Testing _(mandatory)_

### User Story 1 - No model call spent on navigation (Priority: P1)

An analyst runs a decomposition over a table with several candidate dimensions.
The dimension to split on is chosen from the aggregate statistics alone, and the
model's calls all go to interpreting slices. The run costs strictly fewer model
calls than the same run does today and reaches the same slices.

**Why this priority**: This is the feature. It is also the only story that
changes what a run costs, and it is independently useful with no other story
implemented — a Greedy policy plus the existing engine is a complete, cheaper
product.

**Independent Test**: Run the existing end-to-end decomposition over
`UnitTest.RLM.Widget` with a Greedy policy and a scripted model. Assert the model
call count drops by one (no plan call), the slices examined are the ones a human
would pick given the fixture's deliberately-shaped metrics, and the report is
otherwise unchanged.

**Acceptance Scenarios**:

1. **Given** a store where one dimension separates the measure sharply and
   another does not, **When** a Greedy policy chooses a split, **Then** it chooses
   the separating dimension.
2. **Given** the same store, **When** the decomposition runs, **Then** no model
   call is made to choose the dimension.
3. **Given** a store where no dimension reduces the metric, **When** a Greedy
   policy is asked to choose, **Then** it declines to split rather than picking
   arbitrarily, and the report says the store was not decomposed and why.

---

### User Story 2 - Model-driven choice, behind the seam (Priority: P2)

A user who wants the model to choose the decomposition keeps that behaviour by
selecting a different policy. Reports produced this way are identical to those the
engine produces today.

**Why this priority**: Without it the feature is a replacement rather than an
addition, and the comparison in Story 3 has nothing to compare against. It is
lower priority than Story 1 only because the behaviour already exists and is
being moved, not invented.

**Independent Test**: Run a decomposition with the LLM policy and a scripted
model, and assert the report is byte-identical to the one the engine produced
before this feature, from the same script.

**Acceptance Scenarios**:

1. **Given** the LLM policy and a scripted model, **When** a decomposition runs,
   **Then** the report is byte-identical to the pre-feature output for the same
   script.
2. **Given** a model that names a dimension the store does not offer, **When** the
   LLM policy returns it, **Then** it is refused and reported, exactly as a
   refused slice is today.

---

### User Story 3 - Enough on the record to score the road not taken (Priority: P3)

Someone evaluating decomposition quality reads a trace and can see, for each split
decision, which dimension was chosen, which others were available, and what the
statistics were for each — enough to compute what a different choice would have
yielded without running anything.

**Why this priority**: It is what makes the policy seam worth having rather than
merely tidy, but a policy is useful before it is measurable, so it comes after
both policies exist.

**Independent Test**: Run a decomposition, read the trace rows for the split
decision, and compute the metric the alternative dimension would have produced
using only trace contents and peeks — no model call.

**Acceptance Scenarios**:

1. **Given** a completed run, **When** its trace is read, **Then** each split
   decision records the chosen dimension and every candidate that was considered.
2. **Given** a completed run over an unchanged store, **When** the alternative
   arms are enumerated offline, **Then** each candidate's metric can be obtained
   without a model call.

---

### Edge Cases

- A store declares no dimensions. The policy must decline, and the run must still
  produce an answer about the store as a whole.
- Every candidate dimension leaves the metric unchanged. Splitting would burn
  budget for nothing, so the policy declines.
- A candidate's peek fails. That candidate is unavailable, the failure is
  recorded, and the policy chooses among the rest rather than aborting.
- A dimension has one child. Splitting on it produces a slice identical to its
  parent, so it is not a candidate.
- Evaluating candidates itself has a cost — one peek each. The policy must not be
  able to spend the whole budget deciding.
- The LLM policy names a dimension not in the candidate set, including a
  hallucinated one. Refused, not executed.

## Requirements _(mandatory)_

### Functional Requirements

- **FR-001**: The system MUST provide a policy abstraction that, given a store,
  a peek of the current slice, and the candidate dimensions, returns either one
  dimension or a decision not to split.
- **FR-002**: A policy MUST be able to decline to split, and the reason MUST reach
  the report.
- **FR-003**: The system MUST provide a policy that chooses using store statistics
  alone and makes no model call.
- **FR-004**: The statistics-only policy MUST choose the dimension whose children
  most reduce the store's split metric, and MUST decline when no dimension reduces
  it by a configurable margin.
- **FR-005**: The system MUST provide a policy that delegates the choice to the
  language model, preserving the engine's current output for the same model
  responses.
- **FR-006**: A dimension named by a model MUST be validated against the candidate
  set before use; anything else is refused and reported (Constitution II).
- **FR-007**: The engine MUST accept a policy and MUST default to one that
  preserves current behaviour, so existing callers are unaffected.
- **FR-008**: Peeks a policy performs to evaluate candidates MUST be charged
  against the run's budget, and MUST NOT be able to consume the slot reserved for
  synthesis (Constitution III).
- **FR-009**: Each split decision MUST be recorded with the chosen dimension, the
  candidates considered, the metric before and after, and the policy that made it.
- **FR-010**: A candidate whose peek fails MUST be excluded, recorded as
  unavailable, and MUST NOT abort the run.
- **FR-011**: A dimension with fewer than two children MUST NOT be offered as a
  candidate.
- **FR-012**: No statistic a policy examines may include store contents; policies
  see peeks only (Constitution I).

### Key Entities

- **Policy**: A rule for choosing how to divide the current slice. Holds no store
  state; asked once per split decision.
- **Candidate**: A dimension available for splitting the current slice — declared
  by the store, not already used on this path, and with at least two children.
- **Split decision**: The record of one policy invocation: candidates offered,
  dimension chosen or declined, metrics, and which policy decided.

## Success Criteria _(mandatory)_

### Measurable Outcomes

- **SC-001**: A decomposition over a store with two dimensions costs one fewer
  model call with the statistics-only policy than with the model-driven one,
  reaching the same slices.
- **SC-002**: On a store where one dimension separates the measure and another
  does not, the statistics-only policy chooses the separating dimension in 100%
  of runs — it is deterministic, so anything less is a defect.
- **SC-003**: A run's split decisions can be re-scored against every alternative
  dimension using the trace and the unchanged store, with zero model calls.
- **SC-004**: Reports produced with the model-driven policy are byte-identical to
  pre-feature reports for the same model responses.
- **SC-005**: No run exceeds its total call budget, including the calls a policy
  spends evaluating candidates.

## Assumptions

- `SplitMetric` being normalized 0–1 per store is what lets one policy work over
  any store; a store returning an unnormalized metric is a store defect, not a
  policy concern.
- One split decision per depth level is enough for now. Splitting different child
  slices on different dimensions is a later feature and is out of scope.
- The greedy lookahead is one level deep. Deeper lookahead multiplies peeks and
  is out of scope.
- "Byte-identical" in SC-004 means for a scripted model. A real model is not
  reproducible and no claim is made about it.
- Peeks are cheap relative to model calls, but not free. The cost that matters is
  model calls; peek cost is bounded by capping candidate evaluation, not by
  optimizing peeks.
- The existing `RLM.Trace` row shape can carry the new fields, or gains them
  additively — no existing field changes meaning.
