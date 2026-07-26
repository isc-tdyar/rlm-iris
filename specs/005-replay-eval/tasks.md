---
description: "Task list for 005-replay-eval"
---

# Tasks: replay and offline evaluation

**Input**: Design documents from `/specs/005-replay-eval/`
**Prerequisites**: spec.md, plan.md, research.md, data-model.md,
contracts/replay-eval.md

**Tests**: mandatory. Every story phase writes its unit tests first and ends on
an E2E gate. No phase advances on a failing gate. Constitution IV.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel — different files, no dependency on an incomplete
  task
- **[Story]**: US1…US5 from spec.md

## One repository, one container

Everything is in `rlm-iris` = `/Users/tdyar/ws/rlm-iris`, container `rlm-iris`.
No other container is touched.

## Running the suite

```bash
printf 'do $system.OBJ.LoadDir("/home/irisowner/dev/src","ck",,1)
set ^UnitTestRoot="/home/irisowner/dev/src/UnitTest"
do ##class(%UnitTest.Manager).RunTest("RLM","/noload/nodelete/norecursive")
halt
' | docker exec -i rlm-iris iris session IRIS -U USER
```

The `"ck"` qualifier is mandatory. Without it classes import without compiling,
`%UnitTest` runs the previously compiled versions, and the run still prints
"All PASSED".

Diagnostics that need multi-line ObjectScript go in a class file copied in with
`docker cp` and loaded with `LoadDir(..., "ck")`. Piped multi-line braces fail
with `<SYNTAX>`, and a `.mac` through `$system.OBJ.Load` is rejected as an
unknown file type — research R7.

---

## Phase 1: Setup

**Purpose**: baseline recorded before anything changes, so the trace format
change is provably additive.

- [x] T001 Verify container `rlm-iris` is running and is not being used for
      another project's work
- [x] T002 Run the suite and record the pass count as the pre-feature baseline
      (expected 211)
- [x] T003 [P] Record every reader of `^RLM.Trace` and of `RLM.Trace`'s methods,
      as the checklist for Phase 2 (expected: `Trace.Decisions`, `Trace.RowCount`,
      `Trace.Row`, `Trace.Count`, `Report.RenderTrace`, plus the assertions in
      `UnitTest.RLM.Trace` and `UnitTest.RLM.Engine`)

---

## Phase 2: Foundational — trace format v2

**Purpose**: replay needs a version, a fingerprint and the model's own text. All
three are new subscripts; the positional row does not change.

**This phase must not change any behavior.** Its gate is the 211 existing tests
passing unmodified.

- [x] T004 Write `src/UnitTest/RLM/TraceFormat.cls`: a durable run writes
      `"v"` = 2, a `"fp"`, and a `"q"`; a process-private run writes none of the
      three, because it cannot be replayed across sessions and the fingerprint
      would be paid for nothing
- [x] T005 Add to the same class: every existing reader returns the same values
      before and after the new nodes exist — `RowCount` does not count `"v"`,
      `"fp"` or `"q"` as rows, and `Decisions` does not mistake `"t"` for a
      decision sidecar
- [x] T006 Add to the same class: a sub-call's model text is readable back from
      `(runId, seq, "t")` exactly as the model returned it, and a row with no
      model output writes no `"t"` node rather than an empty one
- [x] T007 [US1] Add `Parameter FORMAT = 2`, `Version(runId, durable)`,
      `Fingerprint(runId, durable)` and `Text(seq)` to `src/RLM/Trace.cls`, plus
      the writes for `"v"`, `"fp"`, `"q"` and `"t"`. Durable runs only
- [x] T008 [US1] Implement `RLM.Trace.StoreFingerprint(source)` as the CRC-32
      chain over the root peek's JSON and each first-level slice's, per
      data-model.md. Document in the class comment that it fingerprints the peeks
      and not the data, and what that fails to detect
- [x] T009 [US1] Have `RLM.Engine.Execute` write the fingerprint, question and
      version at the start of a durable run, and `RLM.Engine.Ask` write the model
      text sidecar. `$Length(prompt)`/`$Length(out)` stay in the row unchanged
- [x] T010 **Phase gate**: full suite green at 211 + the new `TraceFormat` tests,
      with no existing test edited. A single edited assertion means the format
      change was not additive

---

## Phase 3: US1 — Replay a recorded run with no model call (P1)

**Purpose**: Constitution V, executable. Everything else in this feature consumes
it.

**Independent test**: record a run over a frozen fixture, replay it, compare
decisions and peeks, assert 0 model calls.

- [x] T011 [P] [US1] Write `src/UnitTest/RLM/Replay.cls`
      `TestEveryDecisionIsReproduced`: each replayed decision has the same chosen
      dimension and the same metric as the recorded one, and the count matches
- [x] T012 [P] [US1] Add `TestReplaySpendsNoModelCall`: `Calls` is 0 and the
      `RLM.LLM.Null` handed to the replay records 0 calls of its own
- [x] T013 [P] [US1] Add `TestTwoReplaysAreByteIdentical`: two replays of one
      trace over an unchanged store produce identical reports — SC-002
- [x] T014 [P] [US1] Add `TestAReplayedReportMatchesTheOriginalOnStoreFacts`: the
      store-derived sections are identical to the original run's, and the
      model-derived sections are present and labelled as reproduced
- [x] T015 [P] [US1] Add `TestARefusedSliceIsReproducedNotSkipped`: a run that
      refused a slice replays with that refusal on the record
- [x] T016 [P] [US1] Add `TestAV1TraceIsRefused`: a trace with no `"v"` node is
      refused with a reason naming the version found and the version supported —
      not replayed with empty prose
- [x] T017 [US1] Implement `src/RLM/Replay.cls` per contracts/replay-eval.md:
      `%OnNew`, `Verify`, `Run`, `Calls`, `Decisions`, `Parameter FORMAT`
- [x] T018 [US1] **Phase gate**: `Replay` green, full suite green

---

## Phase 4: US2 — Enumerate the arms the run did not take (P1)

**Purpose**: what makes a trace an evaluation dataset instead of an audit log.

**Independent test**: a fixture with one clearly separating dimension and one
that divides nothing; assert the unchosen arm's score is present and agrees with
a direct peek.

- [x] T019 [P] [US2] Write `src/UnitTest/RLM/FixtureSeparating.cls`: a `Widget`
      population where one column partitions the rows evenly and another leaves
      one bucket holding almost everything, with both facts declared as constants
      so a test asserts against a number rather than against another query
- [x] T020 [P] [US2] Write `src/UnitTest/RLM/EvalArms.cls`
      `TestAnUnchosenArmIsScored`: the arm the run did not take carries a score
      that equals a direct `Peek` + `SplitMetric` of the same slices
- [x] T021 [P] [US2] Add `TestEnumerationSpendsNoModelCall`: `calls` is 0 and the
      Null LLM records no call
- [x] T022 [P] [US2] Add `TestADeclinedDecisionStillScoresEveryCandidate`: so
      "was declining right?" is answerable
- [x] T023 [P] [US2] Add `TestAnUnscorableArmCarriesItsReason`: an arm whose peek
      fails is reported with an `error` and no score — never scored 0, because 0
      is a legitimate score meaning "divides nothing"
- [x] T024 [P] [US2] Add `TestEnumerationIsBoundedAndReportsWhatItSpent`: a peek
      budget below the arm count sets `capped` and `peeks` equals the budget
- [x] T025 [P] [US2] Add `TestAnEmptyCandidateListYieldsNoArms`: reported as zero
      arms, not as a failure
- [x] T026 [US2] Implement `src/RLM/Eval/Arms.cls` `Enumerate` per
      contracts/replay-eval.md
- [x] T027 [US2] **Phase gate**: `EvalArms` green, full suite green

---

## Phase 5: US3 — Does the LLM beat Greedy? (P1)

**Purpose**: the milestone's headline. The open question SPEC §5 names, answered
with a number and no live provider.

**Independent test**: score Greedy against a deliberately bad policy on the
separating fixture; assert the ranking and that both rows report their cost.

- [x] T028 [P] [US3] Write `src/UnitTest/RLM/PolicyBad.cls`: a policy that always
      chooses the candidate with the _worst_ score. This is what makes US5 #2
      testable — a regression in split quality has to fail a test, and a policy
      that is bad on purpose is the only way to assert the scorecard can tell
- [x] T029 [P] [US3] Write `src/UnitTest/RLM/EvalScorecard.cls`
      `TestOneRowPerPolicyWithCostAndObjective`: each row carries `calls`,
      `peeks`, `slices`, `objective`, `chose` and `runId`
- [x] T030 [P] [US3] Add `TestAGoodPolicyOutranksABadOne`: Greedy's objective is
      strictly better than `PolicyBad`'s on the separating fixture — SC-005
- [x] T031 [P] [US3] Add `TestTheLLMPolicyIsScoredOffline`: `RLM.Policy.LLM`
      driven by a scripted `RLM.LLM.Null` produces a row with a non-zero `calls`
      and an objective, and no network access occurs
- [x] T032 [P] [US3] Add `TestScoringIsDeterministic`: two scorecards over an
      unchanged store render byte-identically — SC-003
- [x] T033 [P] [US3] Add `TestAFailedPolicyRowReportsTheFailure`: a policy whose
      model call fails carries `error` and no objective, rather than an objective
      computed from a partial run
- [x] T034 [P] [US3] Add `TestCostAndObjectiveAreSeparateFigures`: the rendered
      card has both columns and no combined ranking number — FR-009, asserted
      because a future "helpful" summary column is exactly the regression
- [x] T035 [US3] Implement `src/RLM/Eval/Scorecard.cls`: `Score`, `Objective`,
      `Render` per contracts/replay-eval.md
- [x] T036 [US3] **Phase gate**: `EvalScorecard` green, full suite green

---

## Phase 6: US4 — A store that changed invalidates the replay (P2)

**Purpose**: Constitution III applied to the evaluation tooling. A replay that
silently disagrees with its trace is the undisclosed-cap failure one level up.

**Independent test**: mutate one node after recording; assert the refusal.

- [x] T037 [P] [US4] Write `src/UnitTest/RLM/ReplayMismatch.cls`
      `TestAMutatedStoreRefusesTheReplay`: one node written after the trace, and
      the reason states the store no longer matches
- [x] T038 [P] [US4] Add `TestAnUnchangedStoreDoesNotRefuse`: the other side of
      the same assertion, or the check means nothing
- [x] T039 [P] [US4] Add `TestAForeignSourceClassIsRefusedBeforeAnyPeek`: a trace
      written against a different source class is refused, and no peek ran
- [x] T040 [P] [US4] Add `TestVerifyIsIdempotentAndDoesNotConsumeTheTrace`: two
      `Verify` calls return the same answer, and a `Run` after a `Verify` still
      works
- [x] T041 [P] [US4] Add `TestTheFingerprintDoesNotContainStoreContents`: the
      planted secret value appears in no trace node — Constitution I, and the
      assertion that catches anyone "improving" the fingerprint into a digest of
      the data
- [x] T042 [US4] Implement fingerprint verification in `RLM.Replay.Verify`
- [x] T043 [US4] **Phase gate**: `ReplayMismatch` green, full suite green

---

## Phase 7: US5 + feature gate

- [x] T044 Write `src/UnitTest/RLM/EndToEndReplay.cls`: record a run over the
      global fixture with a durable trace, replay it, enumerate its arms, and
      score two policies — all in one test, all offline, asserting 0 provider
      calls and exact figures
- [x] T045 [P] Assert portability directly: the source text of `RLM.Replay`,
      `RLM.Eval.Arms` and `RLM.Eval.Scorecard` contains no `%AI.`, no `%Net.` and
      no SQL — Constitution VI, checked rather than trusted
- [x] T046 [P] Assert no clock and no randomness: the same source text contains
      no `$HOROLOG`, no `$ZTIMESTAMP`, no `$RANDOM`, no `$NOW`. The feature _is_
      the determinism guarantee, so a clock read inside it would make the
      guarantee circular
- [x] T047 [P] Assert read-only: the fixture stores are unchanged after a replay
      and a full scorecard, fingerprinted node by node as `EndToEndGlobal` does
- [x] T048 **Feature gate**: full suite green, and the count is 211 + every test
      added above with no prior test edited
- [x] T049 [P] Update `docs/SPEC.md` §7 to check off M3 with what actually
      shipped, and `README.md`'s milestone list. If the scorecard says Greedy
      wins on the fixture, say so in the README — that is the number the
      milestone existed to produce, and hiding it would be the one dishonest
      outcome
- [x] T050 [P] Add `specs/005-replay-eval/quickstart.md` showing a real replay
      and a real scorecard, with the figures the suite produces
- [ ] T051 Commit, stating what changed, why the trace format change is additive,
      and the platform limits from research.md

---

## Dependencies

```text
Phase 1 (setup)
   └─> Phase 2 (trace v2)              BLOCKING: replay needs version + text
          └─> Phase 3 (US1 replay)
                 ├─> Phase 4 (US2 arms)
                 ├─> Phase 5 (US3 scorecard)
                 └─> Phase 6 (US4 mismatch)
                        └─> Phase 7 (US5 + feature gate)
```

Phases 4, 5 and 6 are independent of each other once Phase 3 lands. Phase 5 does
not strictly need Phase 3 — a scorecard is computed from a trace, not from a
replay — but it is sequenced after it because the objective reads the same rows
and getting the reader right once is cheaper than twice.

## MVP

Phases 1–3 are the MVP: a recorded run replays with no model call over a frozen
store. That alone cashes Constitution V. Phases 4–6 are each an independent
increment, and Phase 7 is the gate that says the milestone is done.
