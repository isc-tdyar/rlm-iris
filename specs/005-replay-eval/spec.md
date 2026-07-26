# Feature Specification: replay and offline evaluation

**Feature Branch**: `005-replay-eval`
**Created**: 2026-07-25
**Status**: Draft
**Input**: M3 from [docs/SPEC.md](../../docs/SPEC.md) §5 and §7

## Why this milestone exists

SPEC §5 makes a claim the package has not yet cashed: because a peek is a pure
function of a frozen store, a trace plus the store replays a run with no model
call, and every alternative arm at every recorded step can be enumerated
offline. That claim is the reason the model is forbidden from authoring code —
model-authored code is not a function of the store, so it does not replay.

Everything M0–M2 shipped is mechanism. What nobody can currently answer is
whether the mechanism is worth its calls. `RLM.Policy.Greedy` is free and
deterministic; `RLM.Policy.LLM` costs one call per decision and needs a key. The
package ships both and recommends neither, because there is no number.

This milestone produces the number, and produces it without a live model: replay
a recorded run against the store it ran on, enumerate the arms the run did not
take, and score policies against each other on the same question over the same
store.

The secondary payoff is CI. A decomposition today is tested for mechanics — call
counts, prompt contents, report headings. After this milestone it can be tested
for _quality_: a change that makes the engine choose worse splits fails a test
rather than passing one.

## User Scenarios & Testing _(mandatory)_

### User Story 1 - Replay a recorded run with no model call (Priority: P1)

An engineer has a durable trace from a run that happened last week. They replay
it against the same store and get the same decisions and the same peek figures —
with zero model calls, no key configured, and no network.

**Why this priority**: This is the milestone's foundation and Constitution V made
executable. Every other story in this feature is a consumer of it.

**Independent Test**: Run a decomposition under `RLM.LLM.Null` with a durable
trace over a frozen fixture, replay the trace, and assert the replayed decisions
and peek figures are identical to the recorded ones and that the model was called
zero times.

**Acceptance Scenarios**:

1. **Given** a durable trace of a completed run and the unchanged store, **When**
   it is replayed, **Then** every recorded decision is reproduced with the same
   chosen dimension and the same metric, and the model is called zero times.
2. **Given** the same trace, **When** it is replayed twice, **Then** both replays
   produce byte-identical output.
3. **Given** a trace whose run refused a slice, **When** it is replayed, **Then**
   the replay records the same refusal rather than skipping the row.
4. **Given** a replay, **When** its report is compared to the original run's,
   **Then** the sections derived from the store are identical, and sections
   derived from model text are reproduced from the trace and labelled as
   reproduced.

---

### User Story 2 - Enumerate the arms the run did not take (Priority: P1)

At every recorded decision the run chose one dimension out of a candidate list.
The evaluator peeks the children of each dimension the run rejected and reports
what that split would have scored — no model call, because the model's job was
only ever to name a candidate and the candidates are all on the record.

**Why this priority**: Counterfactuals are what make the trace an evaluation
dataset rather than an audit log. Without them a policy can only be compared by
running it again live, which costs calls and cannot be done for a policy nobody
has written yet.

**Independent Test**: Over a fixture with two dimensions of clearly different
separating power, record a run, enumerate the arms, and assert the rejected arm's
score is present, agrees with a direct peek, and cost zero model calls.

**Acceptance Scenarios**:

1. **Given** a decision that chose dimension A from candidates A and B, **When**
   the arms are enumerated, **Then** the result carries a score for B computed
   from the store and 0 model calls.
2. **Given** a decision the policy declined, **When** the arms are enumerated,
   **Then** every candidate is scored, so "was declining right?" is answerable.
3. **Given** an arm whose peek fails or is refused, **When** the arms are
   enumerated, **Then** that arm is reported as unscored with its reason, not
   omitted and not scored 0.
4. **Given** an enumeration, **When** its peek count is compared to its budget,
   **Then** the peeks it spent are reported and it stops when the peek budget is
   exhausted rather than running unbounded over a large store.

---

### User Story 3 - Does the LLM beat Greedy? (Priority: P1)

An engineer runs the same question against the same store under two policies and
gets a scorecard: what each policy chose, what each spent, and how the resulting
decompositions score against a store-derived objective. The answer is a number
per policy, reproducible on the same store.

**Why this priority**: This is the open empirical question SPEC §5 names, and the
milestone's headline. If Greedy wins on a workload, the package can recommend
shipping Greedy — cheaper, deterministic, no key.

**Independent Test**: Score `RLM.Policy.Greedy` and `RLM.Policy.LLM` (driven by
a scripted `RLM.LLM.Null`) on a fixture built so one specific dimension is the
separating one. Assert the scorecard ranks a policy that picks it above a policy
that does not, and that both rows report what they spent.

**Acceptance Scenarios**:

1. **Given** two policies and one store, **When** both are scored, **Then** the
   scorecard has one row per policy carrying calls spent, peeks spent, slices
   examined and the objective value.
2. **Given** a policy that chooses the separating dimension and one that chooses
   a dimension that divides nothing, **When** both are scored, **Then** the first
   ranks strictly higher.
3. **Given** the same scoring run executed twice on an unchanged store, **When**
   the two scorecards are compared, **Then** they are identical.
4. **Given** a policy whose model call fails, **When** it is scored, **Then** its
   row reports the failure rather than a score computed from a partial run.

---

### User Story 4 - A store that changed invalidates the replay (Priority: P2)

Replay is only sound over a frozen store. When the store has changed since the
trace was written, the replay says so and refuses rather than presenting
different figures as a reproduction.

**Why this priority**: A replay that silently disagrees with its trace is worse
than no replay: it is the same failure mode as an undisclosed cap, one level up.
Constitution III applies to the evaluation tooling too.

**Independent Test**: Record a run, write one node to the fixture, replay, and
assert the replay refuses with a reason naming the mismatch and makes no claim
about the recorded run.

**Acceptance Scenarios**:

1. **Given** a trace and a store mutated since it was written, **When** it is
   replayed, **Then** the replay refuses and the reason states that the store no
   longer matches the trace.
2. **Given** a trace and the unchanged store, **When** it is replayed, **Then**
   there is no such refusal.
3. **Given** a trace written against a different source class, **When** it is
   replayed against this store, **Then** it is refused before any peek.

---

### User Story 5 - The whole evaluation runs in CI (Priority: P2)

The scorecard, the replay and the arm enumeration all run under `RLM.LLM.Null`
with no network access and no key, as ordinary `%UnitTest` classes, and their
output is deterministic enough to assert on exactly.

**Why this priority**: An evaluation that only runs by hand against a live
provider is an evaluation that stops being run. It is also the property SPEC §5
claims no comparable library has.

**Independent Test**: The feature's own test classes are the proof: they run in
the standard suite invocation, offline, and assert exact figures.

**Acceptance Scenarios**:

1. **Given** the standard suite invocation with no provider configured, **When**
   the feature's tests run, **Then** they pass.
2. **Given** a policy that chooses deliberately badly, **When** it is scored
   against Greedy, **Then** it scores strictly lower — so a regression in split
   quality fails a test rather than passing one.
3. **Given** two runs of the suite, **When** the scorecards are compared, **Then**
   they are identical.

---

### Edge Cases

- A trace with zero decisions, from a run that refused at readiness: replay
  reproduces the refusal and scores nothing.
- A trace row from a future version carrying more fields than this code knows:
  positional `$LIST` access returns "" for the unknown field, which is a silent
  wrong answer, so the trace carries a format version and a replay of an
  unrecognized version is refused.
- A decision whose candidate list is empty: enumeration reports no arms rather
  than failing.
- Two policies that spend different numbers of calls: the objective is reported
  alongside cost and never netted into one number the caller cannot decompose.
- `SplitMetric` is meaningful only within one source class, so a scorecard covers
  one store and says which.

## Requirements _(mandatory)_

### Functional Requirements

- **FR-001**: The system MUST replay a recorded run from a durable trace plus the
  store, reproducing every recorded decision, with zero `RLM.LLM` calls.
- **FR-002**: Replay MUST be deterministic: two replays of one trace over an
  unchanged store produce identical output.
- **FR-003**: The system MUST detect that the store changed since the trace was
  written and refuse the replay with a reason.
- **FR-004**: The system MUST enumerate, for each recorded decision, every
  candidate the run did not choose, and score each from the store with zero model
  calls.
- **FR-005**: An arm that cannot be scored MUST be reported as unscored with its
  reason, never scored zero and never omitted.
- **FR-006**: Arm enumeration MUST be bounded by a peek budget and MUST report the
  peeks it spent and whether it stopped early.
- **FR-007**: The system MUST score a set of policies over one store and one
  question, producing one row per policy carrying calls spent, peeks spent, slices
  examined, and an objective value.
- **FR-008**: The objective MUST be computed from store-provided figures only —
  no model call, no wall clock, no randomness.
- **FR-009**: A scorecard MUST report cost and objective as separate figures and
  MUST NOT combine them into a single ranking number.
- **FR-010**: A policy whose run failed MUST be reported as failed rather than
  scored from a partial run.
- **FR-011**: The trace format MUST carry a version, and a replay of an
  unrecognized version MUST be refused.
- **FR-012**: Everything in this feature MUST run offline under `RLM.LLM.Null`
  with no `%AI.*`, no HTTP client and no SQL, per Constitution VI.
- **FR-013**: Replay MUST reproduce model-authored text from the trace rather than
  regenerating it, and MUST mark it as reproduced.

### Key Entities

- **Replay**: a trace identifier plus a source. Verifies the store matches, then
  walks the recorded rows reproducing each decision and each peek.
- **Store fingerprint**: a small deterministic figure over the store, written into
  the trace at run time and compared at replay time. Small enough to store per run
  and specific enough that one changed value fails the comparison.
- **Arm**: one candidate dimension at one recorded decision, with the score it
  would have produced, the peeks it cost, or the reason it could not be scored.
- **Scorecard**: one row per policy over one store and one question — calls,
  peeks, slices examined, objective value, and failure if any.
- **Objective**: a store-derived figure for how good a decomposition is. Less
  residual mixture across the leaves it produced is better; reported alongside
  cost, never netted against it.

## Success Criteria _(mandatory)_

- **SC-001**: A recorded decomposition replays with 0 model calls and reproduces
  every recorded decision.
- **SC-002**: Two replays of the same trace over an unchanged store produce
  byte-identical output.
- **SC-003**: A store mutated by one node causes the replay to refuse.
- **SC-004**: Every candidate at every recorded decision is either scored from the
  store or reported unscored with a reason. No candidate is silently dropped.
- **SC-005**: A scorecard over a fixture with a known separating dimension ranks
  a policy that finds it strictly above one that does not.
- **SC-006**: The whole feature's tests pass with no provider configured and no
  network access.
- **SC-007**: Scoring two policies over the fixture spends zero calls against any
  real provider and completes within the suite's ordinary runtime.

## Assumptions

- **Durable traces**: replay reads `^RLM.Trace`. `RLM.Engine.DurableTrace` already
  exists and defaults to 0; evaluation callers set it. Process-private traces
  vanish with the process and are not replayable across sessions, which is the
  intended behaviour rather than a gap.
- **The objective is per-source**: `SplitMetric` is normalized 0–1 per store by
  constitutional constraint, so the objective compares policies over one store and
  means nothing across stores. Scorecards are scoped to one store and say so.
- **Model text is reproduced, not regenerated**: replay is about decisions, and
  a decision is a function of the store. Sub-call prose is replayed verbatim
  from the trace and labelled. A replay that called a model to re-derive prose
  would not be a replay.
- **The fingerprint is a figure, not a copy**: derived from aggregates the source
  already computes, so it costs one peek and stores like a number. Constitution
  I forbids storing store contents anywhere, a trace included.
- **No new source is written**: the fixtures are the existing `Widget` table source
  and `^||RLMTest`.
- **`RLM.Policy.LLM` under a scripted Null** is how the LLM policy is scored
  offline. Scoring against a live provider is a caller's choice and out of scope
  for CI.
