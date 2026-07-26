# Tasks: Interop and Audit sources

**Branch**: `006-interop-audit-sources` | **Spec**: [spec.md](spec.md) |
**Plan**: [plan.md](plan.md)

Baseline: 265 tests passing. Every phase writes its tests before its
implementation, and each phase's tests are the gate on the next.

## Phase 1 — Shared extent base

- [x] T001 Write `src/UnitTest/RLM/SourceExtent.cls`: a concrete test subclass of
      `RLM.Source.Extent` over a fixture persistent class, asserting dimension
      declaration refuses a property that does not exist, `Predicate` encodes a
      categorical term and a bucket term, `Where` decodes both, and `SQLTable`
      reads the dictionary rather than deriving the name
- [x] T002 Write `src/UnitTest/RLM/FixtureExtent.cls`: a persistent class with a
      categorical column, a nullable categorical column and a numeric column, plus
      a `Build()` that populates a known distribution and a `Wipe()`
- [x] T003 Create `src/RLM/Source/Extent.cls` — abstract, extends `RLM.Source`:
      `ClassName`, `MaxRows`, `Dims`, `DimOrder`, `Buckets`, `BucketLabels`,
      `AddDimension`, `AddBucketedDimension`, `Dimensions`, `Predicate`, `Term`,
      `Where`, `BucketLabel`, `NullCount`, `SQLTable`, `Column`, `Query`. Class
      comment records why `RLM.Source.Table` is not re-parented onto it
- [x] T004 Add `Distribution(predicate, columns, topK)` to `RLM.Source.Extent`:
      a bounded `TOP k … GROUP BY … ORDER BY COUNT(*) DESC` returning an array of
      `{key, n}` plus the covered total, so a slice with ten thousand distinct
      groups costs the same peek as one with three
- [x] T005 Add `Entropy(distribution, total)` to `RLM.Source.Extent`: normalized
      0–1 entropy with a remainder bucket for everything past the top k, matching
      `RLM.Source.Global`'s treatment of a truncated fanout list
- [x] T006 **Phase gate**: `UnitTest.RLM.SourceExtent` passes, suite green

## Phase 2 — US1 Interop peek, dimensions, metric

- [x] T007 Write `src/UnitTest/RLM/SourceInterop.cls` with real
      `Ens.MessageHeader` rows inserted in `OnBeforeOneTest` and deleted by
      recorded id in `OnAfterOneTest`: assert the extent count after insert rather
      than assuming it
- [x] T008 [US1] Test: `Dimensions()` offers source, target, status and hour, and
      the source/target children are the config names actually present
- [x] T009 [US1] Test: `Peek()` returns `n`, `errors`, `sources`, `targets` and
      `busiest` matching the planted distribution exactly
- [x] T010 [US1] Test: `Peek()` under a `MaxRows` cap reports `capped` 1 and
      `Describe` words the count as a floor ("at least")
- [x] T011 [US1] Test: `SplitMetric` is 0 for a slice carrying one source-target
      pair, near 1 for an evenly mixed one, and strictly between for a skewed one
- [x] T012 [US1] Test: a peeked slice's described text contains no body id, no
      body class name and no description, with marker strings planted in a header's
      `Description`
- [x] T013 [US1] Create `src/RLM/Source/Interop.cls` extending
      `RLM.Source.Extent`: default extent `Ens.MessageHeader`, the four
      dimensions, `Peek`, `Describe`, `SplitMetric`
- [x] T014 [US1] Implement the status enumeration label map in
      `RLM.Source.Interop`, with an unknown code described by its raw value and
      marked unknown rather than dropped (FR-014)
- [x] T015 **Phase gate**: `UnitTest.RLM.SourceInterop` passes, suite green

## Phase 3 — US2 Interop readiness refusals

- [x] T016 [US2] Test: a source pointed at an extent with no rows refuses from
      `Ready` with a reason naming emptiness
- [x] T017 [US2] Test: a source whose namespace is not interop-enabled refuses
      naming that, asserted by pointing the check at a namespace state the test
      can control rather than by disabling interop
- [x] T018 [US2] Test: a populated interop-enabled extent does not refuse — the
      other side of the assertion, without which the check could refuse everything
- [x] T019 [US2] Implement `Ready` in `RLM.Source.Interop`: interop-enabled first,
      then empty, one reason each
- [x] T020 **Phase gate**: refusal tests pass, suite green

## Phase 4 — US3 Audit source

- [x] T021 Write `src/UnitTest/RLM/FixtureAudit.cls`: a persistent class with the
      audit column shape (`EventSource`, `EventType`, `Username`, `Namespace`,
      `EventData`, `Description`), a `Build()` planting a known distribution with
      marker strings in `EventData` and `Description`, and a `Wipe()`
- [x] T022 Write `src/UnitTest/RLM/SourceAudit.cls` against the fixture extent
- [x] T023 [US3] Test: `Dimensions()` offers event source, event type, username
      and namespace, discovered from the data
- [x] T024 [US3] Test: `Peek()` returns `n`, `users`, `namespaces` and `dominant`
      matching the planted distribution
- [x] T025 [US3] Test: `SplitMetric` is the normalized event-type entropy — 0 for
      a single-type slice, near 1 for an even mix
- [x] T026 [US3] Test: neither the peek nor the described text contains the marker
      strings planted in `EventData`, `Description` or `UserInfo`
- [x] T027 [US3] Test: a source pointed at the real `%SYS.Audit` refuses when
      auditing is disabled, asserting the reason matches the machine's actual
      auditing state so the test holds on a machine where it is enabled
- [x] T028 [US3] Test: a fixture-backed source does not run the auditing check —
      a fixture is not the audit log, and refusing it for the system's audit
      setting would make the source untestable
- [x] T029 [US3] Create `src/RLM/Source/Audit.cls` extending `RLM.Source.Extent`:
      default extent `%SYS.Audit`, four dimensions, `Peek`, `Describe`,
      `SplitMetric`, `Ready`
- [x] T030 **Phase gate**: `UnitTest.RLM.SourceAudit` passes, suite green

## Phase 5 — US5 time bucketing and reconciliation

- [x] T031 [US5] Test: the `hour` dimension offers a fixed small number of
      children over a store spanning several hours, and the same number over one
      spanning one hour — the count does not follow the data
- [x] T032 [US5] Test: child counts over `hour` sum to the parent count plus the
      disclosed `NullCount` exactly, with `=` and no tolerance, including rows
      whose `TimeCreated` is null
- [x] T033 [US5] Test: the same reconciliation holds for a categorical dimension
      with null values present, where `NullCount` is what closes the gap
- [x] T034 [US5] Implement the hour bucketing in `RLM.Source.Interop` and extend
      `NullCount` coverage to a derived bucketed column
- [x] T035 **Phase gate**: reconciliation tests pass, suite green

## Phase 6 — US4 end-to-end feature gate

- [x] T036 [US4] Write `src/UnitTest/RLM/EndToEndInteropAudit.cls`: an
      `RLM.Engine` run over each source with `RLM.LLM.Null`, asserting a report
      comes back and no sub-call failed
- [x] T037 [US4] Test: each run replays byte for byte through `RLM.Replay` with
      0 model calls
- [x] T038 [US4] Test: each source appears as a row in an `RLM.Eval.Scorecard`
      alongside Greedy and the LLM policy, with no change to the scorecard
- [x] T039 [US4] Test: a `$QUERY` walk of each finished trace finds no planted
      marker string anywhere in it (SC-002)
- [x] T040 [US4] Test: both sources' source text contains no `%AI.` (FR-017,
      Constitution VI)
- [x] T041 [US4] Test: both extents are unchanged by a run, a replay and a
      scorecard — fingerprinted by row count and by a checksum over the columns
      the source reads
- [x] T042 **Feature gate**: full suite green, count is 265 plus every test added
      above, with no prior test edited
- [ ] T043 [P] Update `docs/SPEC.md` §7 to check off M4 with what shipped, and
      `README.md`'s milestone list
- [ ] T044 [P] Add `specs/006-interop-audit-sources/quickstart.md` with the
      figures the suite actually produces
- [ ] T045 Commit, stating what shipped, why `RLM.Source.Table` was not
      re-parented, and the container limits the tests work around

---

## Dependencies

```text
Phase 1 (Extent)              BLOCKING: both sources need it
   ├─> Phase 2 (US1 Interop peek)
   │      └─> Phase 3 (US2 refusals)
   │             └─> Phase 5 (US5 bucketing)
   └─> Phase 4 (US3 Audit)
                └─> Phase 6 (US4 gate)
```

Phase 4 is independent of Phases 2, 3 and 5 once Phase 1 lands.

## MVP

Phases 1–3: a live message flow decomposes and refuses honestly. That alone is the
source SPEC §4.1 ranks second only to `Global`.
