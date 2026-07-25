# Tasks: Split-choice policy

**Input**: Design documents in `/specs/001-split-policy/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md,
contracts/policy.md, quickstart.md

**Tests are mandatory.** Every phase writes its unit tests before the code they
cover, and every user-story phase ends on an E2E gate that must pass before the
next phase starts.

**Run tests with**:

```bash
docker exec rlm-iris iris session IRIS -U USER
```

```objectscript
Set ^UnitTestRoot = "/home/irisowner/dev/src/UnitTest"
Do ##class(%UnitTest.Manager).RunTest("RLM", "/noload/nodelete/norecursive")
```

## Phase 1: Setup

- [x] T001 Verify the `rlm-iris` container is running and the 54 existing tests
      still pass, so any later failure is attributable to this feature
- [x] T002 Add a third dimension (`Weight`, which separates nothing) to
      `src/UnitTest/RLM/Widget.cls` and extend `Populate()` so a greedy policy
      has a genuine loser to reject
- [x] T003 [P] Add a flat store to `src/UnitTest/RLM/Fixture.cls` — every
      dimension leaves the metric near the root — as the fixture for the
      declined-split path

## Phase 2: Foundational

Blocking: every user story needs the decision value object and the trace
sidecar.

- [x] T004 Write `src/UnitTest/RLM/Decision.cls` unit tests: `Reason` populated
      on success as well as decline, `Candidates` preserves declaration order,
      `AddCandidate()` returns the candidate it appended, a decline has an empty
      `Dimension` with a non-empty `Reason`
- [x] T005 Implement `src/RLM/Decision.cls` and `src/RLM/Decision/Candidate.cls`
      per data-model.md (Dimension, Reason, MetricBefore, MetricAfter,
      PolicyClass, PeeksSpent, Capped, Candidates; candidate carries Dimension,
      Score, ChildMetrics, Children, Sampled, Error)
- [x] T006 Extend `src/UnitTest/RLM/Engine.cls` with a trace-sidecar test:
      writing a decision leaves the ten-field `$LIST` row untouched and puts the
      detail under `("d")` and `("d","cand",n)`
- [x] T007 Add `AddDecision(decision, depth, sourceClass, sliceKey)` to
      `src/RLM/Trace.cls`, writing a `decision` row plus the `"d"` subtree; do
      not change any existing field position
- [x] T008 Run the full suite — existing 54 tests plus the new ones — and
      confirm the current ordering assertions in `UnitTest.RLM.EndToEnd` still
      hold, because that is the proof the change is additive

## Phase 3: User Story 1 — No model call spent on navigation (P1)

**Goal**: A run can decompose a store without spending a model call to decide
how.

**Independent test**: Run the `Widget` store with `RLM.Policy.Greedy`; the
trace holds zero `plan` rows, the report still names the slices, and the total
model calls are one fewer than the same run under the LLM policy.

### Tests first (US1)

- [x] T009 [P] [US1] Write `src/UnitTest/RLM/Policy.cls`:
      `TestChoosesTheSeparatingDimension` (Colour over Size over Weight on the
      `Widget` store), `TestDeclinesWhenNothingSeparates` (flat fixture →
      empty `Dimension`, non-empty `Reason`),
      `TestTiesBreakByDeclarationOrder`,
      `TestIdenticalInvocationsReturnIdenticalDecisions`
- [x] T010 [P] [US1] Add budget tests to `src/UnitTest/RLM/Policy.cls`:
      `TestChargesEveryPeek`, `TestNeverTouchesTheReservedSlot`,
      `TestStopsWhenBudgetRefuses` (decision returned, `Capped` set)
- [x] T011 [P] [US1] Add cap tests to `src/UnitTest/RLM/Policy.cls`:
      `TestMaxChildrenSampledIsReported` (`Sampled < Children`),
      `TestMaxPeeksPerDecisionIsReported` (`Capped` set), using a
      high-fanout dimension
- [x] T012 [US1] Add `TestGreedyRunSpendsNoPlanCall` to
      `src/UnitTest/RLM/EndToEnd.cls` — the US1 phase gate

### Implementation (US1)

- [x] T013 [US1] Implement abstract `src/RLM/Policy.cls` with
      `ChooseSplit(source, peek, candidates, budget) As RLM.Decision` per
      contracts/policy.md, plus `MaxPeeksPerDecision` (12) and
      `MaxChildrenSampled` (8) parameters
- [x] T014 [US1] Implement `src/RLM/Policy/Greedy.cls`: per candidate, peek up
      to `MaxChildrenSampled` children in declaration order, score by
      size-weighted mean of child metrics (research §1), record raw child
      metrics, charge every peek, set `Capped`/`Sampled` when a bound bites,
      decline when no candidate beats `MetricBefore`
- [x] T015 [US1] Add `Policy` property and candidate-eligibility computation
      (declared / not on path / ≥2 children) to `src/RLM/Engine.cls`; delegate
      the split choice and act on the returned dimension by resolving one slice
      per child
- [x] T016 [US1] Add the declined-split caveat to `src/RLM/Report.cls` so
      "not decomposed because nothing separated it" reaches the reader
      (FR-002, Constitution III)
- [x] T017 [US1] **Phase gate**: run the whole suite; T012 and every pre-existing
      test must pass before Phase 4

## Phase 4: User Story 2 — Model-driven choice, behind the seam (P2)

**Goal**: Today's behaviour survives unchanged, expressed as one policy among
several.

**Independent test**: A run with `RLM.Policy.LLM` on a scripted `RLM.LLM.Null`
produces a report byte-identical to the pre-feature run, and a hallucinated
dimension name becomes a decline rather than a split.

### Tests first (US2)

- [x] T018 [P] [US2] Write `src/UnitTest/RLM/PolicyLLM.cls`:
      `TestReturnsTheDimensionTheModelNamed`,
      `TestHallucinatedDimensionBecomesADecline` (model's answer quoted in
      `Reason`), `TestPromptListsOnlyCandidatesAndAggregates`,
      `TestChargesExactlyOneModelCall`
- [x] T019 [US2] Add `TestLLMPolicyReportIsUnchanged` to
      `src/UnitTest/RLM/EndToEnd.cls` — byte-compare against the report the
      pre-feature engine produced from the same scripted replies (SC-004). This
      is the US2 phase gate.

### Implementation (US2)

- [x] T020 [US2] Implement `src/RLM/Policy/LLM.cls`: one `Complete()` call whose
      prompt carries the candidate names and the parent's aggregates only,
      validate the reply against `candidates`, return a decision either way
      (FR-005, FR-006)
- [x] T021 [US2] Default `RLM.Engine.Policy` to `RLM.Policy.LLM` in `%OnNew`
      when none is supplied (FR-007), keeping `RLM.Engine` free of any
      `%AI.*` or HTTP reference
- [x] T022 [US2] **Phase gate**: run the whole suite; T019 must pass before
      Phase 5

## Phase 5: User Story 3 — Score the road not taken (P3)

**Goal**: A finished run can be re-scored against the dimensions it did not
choose, without a model call.

**Independent test**: From a trace alone, enumerate every candidate of every
decision with its score and its evidence quality; the unchosen arms are
identifiable and re-peekable.

### Tests first (US3)

- [x] T023 [P] [US3] Write `src/UnitTest/RLM/Trace.cls`:
      `TestEveryCandidateIsEnumerableByOrder`,
      `TestChildMetricsSurviveTheRoundTrip`,
      `TestFailedCandidateRecordsItsError` (FR-010),
      `TestRowWithoutDecisionSubtreeIsASubcallOrSynthesis`
- [x] T024 [US3] Add `TestAlternativeArmsAreRecoverableFromTraceAlone` to
      `src/UnitTest/RLM/EndToEnd.cls`: run, discard the engine, then rebuild
      each decision's candidate set from `^||RLM.Trace` and re-peek one
      unchosen arm from the store (SC-003). This is the US3 phase gate.

### Implementation (US3)

- [x] T025 [US3] Ensure `RLM.Engine` writes a decision row for every split
      choice including declines, so a run with no decomposition still records
      why (FR-009)
- [x] T026 [US3] Add a `Decisions(runId)` reader to `src/RLM/Trace.cls` that
      walks the sidecar and returns decisions with their candidates, so callers
      do not hand-parse `$LIST` rows
- [x] T027 [US3] **Phase gate**: run the whole suite; T024 must pass

## Phase 6: Polish

- [x] T028 [P] Verify quickstart.md's snippets run verbatim in the container;
      fix the doc, not the test, if they drift
- [x] T029 [P] Update `README.md` with the policy seam and the greedy-vs-LLM
      cost difference
- [x] T030 Confirm SC-001 by measuring: same store, both policies, compare
      `RLM.Budget.Used`; record the numbers in the PR description
- [x] T031 Run `markdownlint-cli2 --fix` and `prettier --write` over every `.md`
      touched

## Dependencies

- Phase 1 → Phase 2 → Phase 3 → Phase 4 → Phase 5 → Phase 6.
- US1 depends on Foundational (T005, T007). US2 depends on US1's `RLM.Policy`
  and the engine seam (T013, T015). US3 depends on decisions actually being
  produced (T014 or T020).
- Within a phase, `[P]` tasks touch different files and can run together.

## Parallel opportunities

- Phase 1: T002 and T003 are separate fixture classes.
- Phase 3: T009, T010, T011 are separate test methods in one class — write them
  together, then implement.
- Phase 5: T023's four methods are independent.

## Implementation strategy

**MVP is Phase 3.** US1 alone delivers the feature's point: a decomposition that
spends no model call on navigation. US2 is a compatibility guarantee and US3 is
what makes the choice evaluable, but a stop after Phase 3 leaves a working,
tested package with the LLM path untouched behind its default.
