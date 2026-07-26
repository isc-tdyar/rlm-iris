---
description: "Task list for 004-global-source"
---

# Tasks: RLM.Source.Global

**Input**: Design documents from `/specs/004-global-source/`
**Prerequisites**: spec.md, plan.md, research.md, data-model.md,
contracts/source-global.md

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
`%UnitTest` skips them, and the run still prints "All PASSED".

Diagnostics that need multi-line ObjectScript must go in a `.mac` routine copied
in with `docker cp`. Piped multi-line braces fail with `<SYNTAX>` — research.md
R6.

---

## Phase 1: Setup

**Purpose**: baseline recorded before anything changes, so the
`Dimensions(path)` signature change is provably behavior-preserving.

- [x] T001 Verify container `rlm-iris` is running and is not being used for
      another project's work
- [x] T002 Run the suite and record the pass count as the pre-feature baseline
      (expected 148)
- [x] T003 [P] Record which files reference `Dimensions()` and at which lines, as
      the checklist for Phase 2 (expected: `Engine.cls:380`, `Slice.cls:46`,
      `Slice.cls:132`, `Policy.cls:101`)

---

## Phase 2: Foundational — `Dimensions()` learns where it is

**Purpose**: the one engine-level change the plan identified. Blocking: no story
can be implemented correctly without it, because a global's children are
path-dependent.

**This phase must not change any behavior.** Its gate is the 148 existing tests
passing unmodified.

- [x] T004 Write `src/UnitTest/RLM/SourceDimPath.cls` asserting that
      `Dimensions("")` and `Dimensions()` return identical output for an
      `RLM.Source.Table` fixture, and that a source overriding `Dimensions(path)`
      receives the path the engine resolved
- [x] T005 Add the optional `path` argument to `RLM.Source.Dimensions()` in
      `src/RLM/Source.cls`, defaulting to `""`, documenting why a hierarchical
      store needs it
- [x] T006 Update the signature in `src/RLM/Source/Table.cls`, ignoring the
      argument, with a comment saying a table's columns are the same at every
      slice so it has nothing to do with it
- [x] T007 Pass the path at all four call sites: `Engine.cls` `Candidates`,
      `Slice.cls` `Resolve` and `Menu`, `Policy.cls` `Children`. `Policy.Children`
      and `Slice.Menu` gain an optional `path` parameter to carry it
- [x] T008 **Phase gate**: full suite green at 148 + the new `SourceDimPath`
      tests, with no existing test edited. A single edited assertion means the
      change was not behavior-preserving

---

## Phase 3: US3 — A refused global costs nothing (P1)

**Purpose**: the allowlist, first, because it is the feature's largest liability
and because every later test constructs a source and would otherwise be
constructing one with no gate.

**Independent test**: construct against each denied pattern and assert refusal
with a reason, and that no walk ran.

- [x] T009 [P] [US3] Write `src/UnitTest/RLM/SourceGlobalAllow.cls`: one test per
      default-denied pattern (`^%cspSession`, `^ISCLOG`, `^rMAP`, `^ROUTINE`,
      `^oddDEF`), each asserting refusal and that the reason names the pattern
- [x] T010 [P] [US3] Add to the same class: an empty allowlist refuses
      everything; `^Sales*` admits `^SalesOrder` and refuses `^Inventory`;
      `^*` still cannot reach `^ROUTINE`, because deny is checked after allow and
      wins
- [x] T011 [P] [US3] Add to the same class: malformed references are refused
      before the allowlist is consulted, and the reason names the malformation —
      no leading `^`, an extended reference (`|`, `[`, `"`), a subscripted
      reference (`(`)
- [x] T012 [US3] Create `src/RLM/Source/Global.cls` with `GlobalRef`, `VisitCap`,
      `DepthCap`, `AllowList`, `TopN`, the `DENY` class parameter, and a
      `%OnNew` that validates in the data-model.md order and refuses with a
      reason. No walk code yet
- [x] T013 [US3] Assert refusal happens before any read: a test constructs
      against a denied global that does not exist and asserts the reason is the
      denial rather than a missing-global error
- [x] T014 [US3] **Phase gate**: `SourceGlobalAllow` green, full suite green

---

## Phase 4: US1 — Characterize a global with no schema (P1)

**Purpose**: the walk, the dimensions, and the arithmetic that must reconcile.

**Independent test**: a fixture with hand-counted structure; every peek figure
compared against the hand count.

- [x] T015 [US1] Write `src/UnitTest/RLM/FixtureGlobal.cls`: builds `^||RLMTest`
      with a documented structure whose node count, per-child counts, data-node
      and pointer-node counts are stated as constants in the class, so a test
      asserts against a declared number rather than against another walk
- [x] T016 [P] [US1] Write `src/UnitTest/RLM/SourceGlobal.cls` `TestDimensions`:
      `s1`'s children are exactly the fixture's first-level subscripts, each with
      a hex token and a raw-subscript label
- [x] T017 [P] [US1] Add `TestEverySubscriptRoundTrips`: for every subscript in
      the fixture, hex → raw → hex is the identity, including the comma, quote and
      close-paren cases from research.md R1
- [x] T018 [P] [US1] Add `TestRootPeekMatchesTheHandCount`: `n`, `children`,
      `dataNodes`, `pointerNodes` and `depth` all equal `FixtureGlobal`'s declared
      constants
- [x] T019 [P] [US1] Add `TestChildrenSumToTheParent`: the `n` of every `s1` child
      sums exactly to the root's `n` on an uncapped walk, and `NullCount` is 0
- [x] T020 [P] [US1] Add `TestScopedWalkDoesNotReturnZero`: a child slice's `n`
      is greater than 0 — the specific regression from research.md R2, where the
      trailing `)` makes every subtree look empty while the run still succeeds
- [x] T021 [P] [US1] Add `TestDimensionsAreComputedAtThePath`: `s2`'s children
      under one `s1` slice are that slice's subscripts and do not include another
      `s1` slice's subscripts
- [x] T022 [P] [US1] Add `TestAFabricatedTokenIsRefused`: a hex token for a
      subscript that does not exist is refused by `RLM.Slice`, and the refusal
      carries the grammar
- [x] T023 [US1] Implement `Dimensions(path)`, `Predicate(components)` and the
      bounded walk in `RLM.Source.Global`: `$NAME` under indirection for
      references, and recursive `$ORDER` for the walk. Not `$QUERY` as
      research.md R2 proposed — a probe showed it visits only nodes holding a
      value, so a global with pure pointer interiors reports a node count far
      below its real one and a pointer count of 0. Recursing on `$ORDER` also
      removes the need for stem comparison, and with it R2's trailing-`)` bug
- [x] T024 [US1] Implement `Peek` returning the contract's required properties
      (`n`, `capped`) plus `depth`, `children`, `dataNodes`, `pointerNodes`,
      returning an `error` property rather than throwing
- [x] T025 [US1] Implement `Describe` as self-labelling metric lines per
      contracts/source-global.md
- [x] T026 [US1] **Phase gate**: `SourceGlobal` green, full suite green

---

## Phase 5: US2 — A walk that stopped early says so (P1)

**Purpose**: Constitution III. A capped count presented as a total corrupts every
downstream claim.

**Independent test**: cap below the fixture's size; assert the disclosure.

- [x] T027 [P] [US2] Write `src/UnitTest/RLM/SourceGlobalCaps.cls`
      `TestVisitCapSetsCapped`: a cap below the fixture's node count yields
      `capped` = 1 and `n` = the cap exactly
- [x] T028 [P] [US2] Add `TestUncappedWalkIsNotMarkedCapped`: a cap above the node
      count yields `capped` = 0 and the true count
- [x] T029 [P] [US2] Add `TestDepthCapSetsCappedAndBoundsDepth`: a depth cap below
      the fixture's depth yields `capped` = 1 and `depth` equal to the cap
- [x] T030 [P] [US2] Add `TestDescribeWordsACappedCountAsAFloor`: the described
      text of a capped peek contains a disclosure and the text of an uncapped peek
      does not. Asserts presence, not wording
- [x] T031 [P] [US2] Add `TestAReportOfACappedRunDisclosesIt`: a full run whose
      peeks capped produces a report whose caveats name the capping
- [x] T032 [US2] Implement both caps in the walk, setting `capped` when either
      stopped it. Also landed with T024, for the same reason: the caps are two
      conditions inside the walk's recursion and could not be added to it later
      without rewriting it
- [x] T033 [US2] **Phase gate**: `SourceGlobalCaps` green, full suite green

---

## Phase 6: US4 — Fanout entropy drives the split (P2)

**Purpose**: makes `RLM.Policy.Greedy` work on globals with no policy change.

**Independent test**: an even fixture and a skewed one; assert the scores
separate.

- [x] T034 [P] [US4] Write `src/UnitTest/RLM/SourceGlobalMetric.cls`
      `TestEvenChildrenScoreHigh`: equal child counts score above 0.9
- [x] T035 [P] [US4] Add `TestSkewedChildrenScoreLow`: one child holding 95% of
      nodes scores below 0.3
- [x] T036 [P] [US4] Add `TestASingleChildScoresZero` and assert `ShouldSplit` is
      false for it
- [x] T037 [P] [US4] Add `TestTheMetricIsInRange`: across every fixture slice, the
      value is within [0,1]
- [x] T038 [P] [US4] Add `TestPeekingTwiceIsIdentical`: two peeks of the frozen
      fixture serialize identically — Constitution V, and the test that catches
      any clock or random dependence
- [x] T039 [P] [US4] Add `TestGreedyChoosesWithoutAModelCall`: a run under
      `RLM.Policy.Greedy` over the global completes with 0 model calls
- [x] T040 [US4] Implement `SplitMetric` as normalized entropy of the child node
      count distribution, returning 0 for fewer than two children
- [x] T041 [US4] **Phase gate**: `SourceGlobalMetric` green, full suite green

---

## Phase 7: US5 — Subscript shape, not subscript content (P2)

**Purpose**: what lets the model say "this level is a date and that one is a
facility code" without seeing either.

**Independent test**: known type mix and known value lengths, every figure
asserted against a hand computation.

- [x] T042 [P] [US5] Write `src/UnitTest/RLM/SourceGlobalShape.cls`
      `TestSubscriptTypeMix`: numeric, string and list counts match the fixture's
      declared constants
- [x] T043 [P] [US5] Add `TestTypeMixPartitionsTheChildren`:
      `subNumeric + subString + subList` equals `children`, so a
      double-counting classifier cannot pass
- [x] T044 [P] [US5] Add `TestValueLengthMoments`: mean and population sd match
      hand-computed values within 0.01, and are 0 for an empty or single-value
      slice rather than erroring
- [x] T045 [P] [US5] Add `TestTopFanoutIsBoundedAndOrdered`: at most `TopN`
      entries, descending by `n`, each token round-tripping to its label
- [x] T046 [P] [US5] Add `TestPeekSizeIsIndependentOfStoreSize`: peek a fixture
      and its 100x multiple, assert both serialize under 2,000 characters and that
      the two lengths differ by less than 10%. This is the package's central claim
      measured rather than asserted
- [x] T047 [P] [US5] Add `TestNoStoredValueReachesTheDescription`: a value held
      at exactly one node appears in no peek and no built prompt —
      Constitution I, SC-006
- [x] T048 [US5] Implement the type mix, value-length moments and `topFanout` in
      `Peek`. Landed with T024 rather than here: the moments and the fanout
      ranking share the walk's running totals, and splitting them across two
      edits would have meant a second pass over the same state. Phase 7's tests
      therefore confirm behaviour rather than drive it — noted because a phase
      whose implementation task was already done is a phase whose tests were
      written against working code
- [x] T049 [US5] **Phase gate**: `SourceGlobalShape` green, full suite green

---

## Phase 8: E2E gate and polish

- [x] T050 Write `src/UnitTest/RLM/EndToEndGlobal.cls`: a full decomposition of
      `^||RLMTest` under `RLM.LLM.Null`, asserting the exact call count, that the
      report names every child slice, that the trace records a decision per level,
      and that the run is byte-identical on a second execution
- [x] T051 Add to the same class: a run whose source was refused produces a report
      stating the refusal with 0 model calls
- [x] T052 [P] Assert portability directly: `RLM.Source.Global` source text
      contains no `%AI.`, no `%Net.`, and no SQL — Constitution VI, checked rather
      than trusted
- [x] T053 [P] Assert read-only: the fixture's node count and full contents are
      unchanged after a complete decomposition
- [x] T054 **Feature gate**: full suite green, and the count is 148 + every test
      added above with no prior test edited
- [x] T055 [P] Update `docs/SPEC.md` §7 to check off M2, and `README.md` to
      replace "M2, designed in SPEC §4.1 and not yet written" in the walkthrough
      with what actually shipped
- [x] T056 [P] Add `specs/004-global-source/quickstart.md` showing a real
      decomposition of a real global, with the figures the suite produces
- [x] T057 Commit, stating what changed and why the `Dimensions(path)` change is
      behavior-preserving, plus the platform limits from research.md

---

## Dependencies

```text
Phase 1 (setup)
   └─> Phase 2 (Dimensions path)      BLOCKING: hierarchical stores need it
          └─> Phase 3 (US3 allowlist)  first: every later test constructs a source
                 └─> Phase 4 (US1 walk + dimensions)
                        ├─> Phase 5 (US2 caps)
                        ├─> Phase 6 (US4 metric)
                        └─> Phase 7 (US5 shape)
                               └─> Phase 8 (E2E gate)
```

Phases 5, 6 and 7 are independent of each other once Phase 4 lands. Within each
phase the `[P]` test tasks are parallel; the implementation task that follows them
is not.

## MVP

Phases 1–4 are the MVP: a global with no schema is characterized and decomposed,
behind a fail-closed allowlist. Phases 5–7 are each an independent increment on
that, and Phase 8 is the gate that says the milestone is done.
