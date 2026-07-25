---
description: "Task list for 003-gaia-port"
---

# Tasks: Port the gaia-iml prototype onto rlm-iris

**Input**: Design documents from `/specs/003-gaia-port/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/README.md

**Tests**: mandatory. Every story phase writes its unit tests first and ends on
an E2E gate. No phase advances on a failing gate.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel — different files, no dependency on an incomplete
  task
- **[Story]**: US1…US5 from spec.md

## Two repositories

Paths are relative to the repository named in the task. Spec artifacts live in
`rlm-iris`; the port's code lives in `gaia-iml`, for which write permission was
given explicitly.

- `rlm-iris` = `/Users/tdyar/ws/rlm-iris` — library, container `rlm-iris`
- `gaia-iml` = `/Users/tdyar/ws/gaia-iml` — prototype, container `gaia-iml-iris`

Containers are never crossed. The library suite runs in `rlm-iris`; every Gaia
test runs in `gaia-iml-iris`.

## Running the suites

`rlm-iris` (136 tests, must stay green after every phase):

```bash
printf 'do $system.OBJ.LoadDir("/home/irisowner/dev/src","ck",,1)
set ^UnitTestRoot="/home/irisowner/dev/src/UnitTest"
do ##class(%UnitTest.Manager).RunTest("RLM","/noload/nodelete/norecursive")
halt
' | docker exec -i rlm-iris iris session IRIS -U USER
```

`gaia-iml`:

```bash
printf 'do $system.OBJ.LoadDir("/home/irisowner/dev/lib/rlm-core/src","ck",,1)
do $system.OBJ.LoadDir("/home/irisowner/dev/src","ck",,1)
set ^UnitTestRoot="/home/irisowner/dev/src/UnitTest"
do ##class(%UnitTest.Manager).RunTest("Gaia","/noload/nodelete/norecursive")
halt
' | docker exec -i gaia-iml-iris iris session IRIS -U USER
```

The `"ck"` qualifier is mandatory in both. Without it classes import without
compiling, `%UnitTest` skips them, and the run still prints "All PASSED".

---

## Phase 1: Setup

**Purpose**: both containers up, both suites green, baseline figures recorded
before anything moves.

- [x] T001 Verify `rlm-iris` and `gaia-iml-iris` are both running
      (`docker ps`), and that neither is being used for the other's work
- [x] T002 Run the `rlm-iris` suite and record the pass count as the pre-port
      baseline (expected 136)
- [x] T003 Run the existing `gaia-iml` suite (`UnitTest.Gaia.RLM2`) and record
      its pass count as the pre-port baseline
- [x] T004 [P] Record pre-port line counts per file under `gaia-iml/src/Gaia/`
      into `specs/003-gaia-port/baseline-lines.txt` in `rlm-iris` — SC-002
      measures against this, and a figure recomputed after the fact is not a
      baseline
- [x] T005 [P] Confirm the pre-port reports are preserved at
      `gaia-iml/data/out-baseline/` and are readable

---

## Phase 2: Foundational (blocking)

**Purpose**: the library must compile inside `gaia-iml-iris`, and a caller must
be able to write a report to a file. Until both hold, nothing in US1–US5 can
exist.

**⚠️ CRITICAL**: no user story work begins until this phase's gate passes.

### Library change first — `RLM.Report.WriteTextToFile` (rlm-iris)

Defect 3 of plan.md. Under FR-014 the fix lands here with a test, not as a
workaround in Gaia.

- [x] T006 Write the failing test first in
      `rlm-iris/src/UnitTest/RLM/ReportStyle.cls`: `WriteTextToFile(text, path)`
      writes UTF-8, round-trips an em dash, returns a bad status (not an
      exception) for an unwritable path, and the existing instance
      `WriteToFile(path)` behaviour is unchanged
- [x] T007 Run the `rlm-iris` suite and confirm the new test FAILS for the right
      reason (`<METHOD DOES NOT EXIST>`), not a compile error
- [x] T008 Add `ClassMethod WriteTextToFile(text, path) As %Status` to
      `rlm-iris/src/RLM/Report.cls` and reduce the instance method
      `WriteToFile(path)` at line 129 to a delegating one-liner
- [x] T009 Run the `rlm-iris` suite: 136 + new tests, all pass. **Gate.**

### Submodule delivery (gaia-iml)

Research decision 1. IPM is not available in the prototype's image, verified.

- [x] T010 Add `rlm-iris` as a git submodule at `gaia-iml/lib/rlm-core`, pinned
      to the commit that contains T008
- [x] T011 Edit `gaia-iml/iris.script` to `LoadDir("/home/irisowner/dev/lib/rlm-core/src","ck",,1)`
      **before** the existing `LoadDir` over `src/` — the prototype's classes
      extend the library's, so load order is not cosmetic
- [x] T012 [P] Add a `<Dependencies>` entry naming `rlm-core` to
      `gaia-iml/module.xml`, for the IPM path on images that have IPM
- [x] T013 [P] Add `lib/rlm-core` guidance to `gaia-iml/README.md`: a plain
      `git clone` yields an empty submodule and nothing compiles
- [x] T014 Rebuild/restart `gaia-iml-iris` and confirm `RLM.Engine`,
      `RLM.Source.Table`, `RLM.Slice`, `RLM.Budget`, `RLM.Report` and
      `RLM.LLM.Null` all compile in that container
- [x] T015 Assert FR-013 mechanically: no file matching `src/RLM/*` exists under
      `gaia-iml/src/`. A copy would satisfy the compiler and violate the spec
- [x] T016 Run the existing `gaia-iml` suite. It must still match T003. **Gate.**

**Checkpoint**: library compiles in the prototype's container, a caller can
write a report to disk, no copies exist. US1 and US2 can now begin.

---

## Phase 3: User Story 1 — Gaia is a store the library can read (P1) 🎯 MVP

**Goal**: `Gaia.Source` presents the quality table through `RLM.Source`'s six
methods with nothing reaching around them.

**Independent Test**: instantiate `Gaia.Source` and exercise it with no engine,
no policy and no model.

### Tests for US1 — write these first, confirm they fail

- [x] T017 [P] [US1] Create `gaia-iml/src/UnitTest/Gaia/Source.cls` with the
      declaration tests: `Dimensions()` returns exactly the six of
      data-model.md; the child count is computed and **printed**, not asserted
      against a constant (SC-001, and the reason the "21 slices" figure
      survived as long as it did); every child label carries its numeric range
- [x] T018 [P] [US1] Add the resolution tests: for each of the 22 children,
      `RLM.Slice.Resolve` yields a predicate whose `Peek().n` matches the
      measured population from data-model.md (`variability` 17,899 / 17,204 /
      31,224 / 8,671; `detection` 17,899 / 57,099), and the four `variability`
      children sum to 74,998
- [x] T019 [P] [US1] Add the boundary test: `epoch_count` is half-open at 5, 20
      and 60. 2,834 rows sit exactly on a breakpoint, so `>=` vs `>` is
      observable here even though it is not for `pct_change`
- [x] T020 [P] [US1] Add the containment test: for a two-level path, each
      child's `n` sums to its parent's `n` and no row is counted twice
- [x] T021 [P] [US1] Add the `Peek()` shape test: all sixteen aggregates of
      data-model.md present plus `capped = 0`; `{"n": 0}` for an empty slice; a
      malformed predicate yields `{"error": …}` rather than an exception
- [x] T022 [P] [US1] Add the `Describe()` tests: the eleven self-labelling lines
      present with their units, both warnings present (a coefficient of
      variation is not an uncertainty; a prediction error is not a reject
      fraction), and "This slice contains no sources." for `n = 0`
- [x] T023 [P] [US1] Add the `SplitMetric()` tests: within 0-1 inclusive for
      every child; clamps to exactly 1 for a slice more spread than the survey;
      returns 0 for an error peek and for a zero baseline; the baseline is
      computed once per instance and two instances do not share it
- [x] T024 [P] [US1] Add the `ShouldSplit()` tests: true only when
      `SplitMetric >= 1` **and** `n >= 400`; false at `n = 399` regardless of
      spread; the `threshold` argument is ignored, asserted by passing 0.99 and
      0.01 and getting the same answer
- [x] T025 [P] [US1] Add the `Ready()` tests: passes on the live table; the
      two refusal messages are distinguishable and each names both counts and
      the routine to run (simulate the empty and partial cases without mutating
      the real table)
- [x] T026 [P] [US1] Add the principle-I test: a `source_id` held by exactly one
      row appears in no string `Gaia.Source` produces — not in a peek, not in a
      `Describe`, not in a label
- [x] T027 [P] [US1] Add the `NullCount()` test: wired and returning 0 for every
      dimension today, asserted rather than assumed (FR-002, principle III)
- [x] T028 [US1] Run the Gaia suite and confirm the US1 tests FAIL for the right
      reason (`Gaia.Source` does not exist), not a compile error

### Implementation for US1

- [x] T029 [US1] Create `gaia-iml/src/Gaia/Source.cls` extending
      `RLM.Source.Table`: `%OnNew()` takes no arguments, calls
      `##super("SQLUser.GaiaQualityScored", "reject_fraction")`, then declares
      the five prototype dimensions via `AddBucketedDimension` with explicit
      labels, checking every returned `%Status` (FR-001)
- [x] T030 [US1] Declare the sixth dimension `detection` over `pct_change` with
      one breakpoint at 100 (FR-001a) — the population `Triage` has always
      described, now nameable
- [x] T031 [US1] Override `Dimensions()` to call `##super()` and overwrite each
      dimension's `label` with the prototype's descriptive sentence, leaving
      children untouched. The library has no declared slot for dimension-level
      prose; this is where it goes
- [x] T032 [US1] Override `Peek(predicate)`: the prototype's sixteen aggregates
      plus `capped: 0`, built on `..Where(predicate, .args)` with every value
      bound as a parameter. It must not assemble a `WHERE` clause as text —
      sharing the inherited method is what stops `Peek` and `NullCount`
      disagreeing about which rows a predicate names (FR-002)
- [x] T033 [US1] Override `Describe(label, peek)`: the eleven lines verbatim
      from `Gaia/RLM.cls`, both warnings, and the empty-slice sentence (FR-003)
- [x] T034 [US1] Add `Property Baseline As %Numeric [ InitialExpression = -1 ]`
      and override `SplitMetric(peek)` as `min(1, sd_rej / Baseline)`, computing
      the baseline on first call and caching it in the instance — instance scope
      is run scope (FR-004, research decision 5)
- [x] T035 [US1] Override `ShouldSplit(peek, threshold)` as
      `(SplitMetric(peek) >= 1) && (peek.n >= 400)`, with a comment at the site
      recording that `threshold` is ignored deliberately and that the parent
      declares it (FR-005)
- [x] T036 [US1] Override `Ready(.reason)` with its own `COUNT` query, not a
      peek: the engine calls it before the root peek precisely because that peek
      is the expensive call on a store mid-load. Two distinguishable refusals
      (FR-006)
- [x] T037 [US1] Run the Gaia suite: all US1 tests pass. Print the computed
      dimension and child counts (SC-001)
- [x] T038 [US1] Run the `rlm-iris` suite. Still green. A break here is a
      library defect and FR-014 says the fix goes there. **Gate.**

**Checkpoint**: the store is readable by the library with no engine involved.
This is the real test of whether `RLM.Source` is the right contract.

---

## Phase 4: User Story 2 — the prototype's provider becomes an RLM.LLM (P1)

**Goal**: `%AI.Agent` reached only through `RLM.LLM.Complete()`.

**Independent Test**: `Complete()` returns text with an OK status; a broken
configuration returns `""` with a bad status and no exception.

### Tests for US2 — write these first

- [x] T039 [P] [US2] Create `gaia-iml/src/UnitTest/Gaia/LLM.cls`: `Complete()`
      with a live key returns non-empty text with an OK status and `..Model`
      names the model that answered
- [x] T040 [P] [US2] Add the failure tests: no API key, an unreachable provider,
      and an empty prompt each return `""` with a status naming the failure and
      **never** throw. The report is a bonus deliverable; its absence must not
      disturb `result.csv`
- [x] T041 [P] [US2] Add the SC-005 test: search
      `lib/rlm-core/src/RLM/Engine.cls` for `%AI.` and require zero matches.
      Search, not inspection
- [x] T042 [US2] Run the Gaia suite and confirm the US2 tests fail for the right
      reason

### Implementation for US2

- [x] T043 [US2] Create `gaia-iml/src/Gaia/LLM/Agent.cls` extending
      `%AI.Agent`, carrying the prototype's `PROVIDER` (openai), `MODEL`
      (gpt-4o-mini) and `APIKEY` (`@{env.OPENAI_API_KEY}`) parameters
- [x] T044 [US2] Create `gaia-iml/src/Gaia/LLM/AIHub.cls` extending `RLM.LLM`:
      `Complete(instructions, prompt, .sc)` does `%Init` / `CreateSession` /
      `Chat` inside `Try`/`Catch`, one round trip, no tool loop, sets `..Model`,
      returns `""` with `sc` on any failure (FR-009)
- [x] T045 [US2] Run the Gaia suite: US2 tests pass
- [x] T046 [US2] Run the `rlm-iris` suite. Still green. **Gate.**

**Checkpoint**: the engine drives an AI Hub provider with no edit to the engine.
Principle VI is exercised rather than asserted.

---

## Phase 5: User Story 3 — the two entry points run on the library (P2)

**Goal**: `Audit()` and `Triage()` become engine constructions; ~700 lines
leave.

**Independent Test**: both entry points under `RLM.LLM.Null` produce a complete
report, byte-identical across runs; then one real-provider `Audit()` over all
74,998 rows.

### Tests for US3 — write these first

- [x] T047 [P] [US3] Create `gaia-iml/src/UnitTest/Gaia/Port.cls`: `Audit()`
      under a scripted `RLM.LLM.Null` runs twice and the two reports are
      byte-identical (SC-003)
- [x] T048 [P] [US3] Add the report-completeness test under the null provider:
      the report names the store, the slices examined, an answer, the limits of
      the analysis, and the calls spent
- [x] T049 [P] [US3] Add the `Triage()` scope test: the run is confined by the
      slice name `detection:b1`, that slice holds 57,099 rows, the report says
      which subset it describes, and no SQL string crosses into the engine
      (FR-010)
- [x] T050 [P] [US3] Add the budget-exhaustion test: with a budget too small to
      reach every slice, the report **names** the dropped slices rather than
      omitting them silently (principle III)
- [x] T051 [P] [US3] Add the empty-slice test: `detection:b1/variability:b0` is
      empty by construction; the report describes it as empty and the run spends
      no model call on it
- [x] T052 [P] [US3] Add the never-throws test: with the provider removed,
      `Audit()` returns a status and a report rather than raising
- [x] T053 [P] [US3] Add the FR-008 grep test: no call budget, recursion trace,
      `Ask`, `Indent`, `Recurse` or `WriteReport` remains anywhere under
      `gaia-iml/src/Gaia/` (excluding `RLM2.cls`, whose delegation budget stays
      by FR-012)
- [x] T054 [US3] Run the Gaia suite and confirm the US3 tests fail for the right
      reason

### Implementation for US3

- [x] T055 [US3] Rewrite `Gaia.RLM.Audit(outPath)` as the quickstart.md body:
      construct `RLM.Engine` over `Gaia.Source` + `Gaia.LLM.AIHub` +
      `RLM.Budget(..#MAXCALLS)`, set `MaxDepth = ..#MAXDEPTH` and
      `ReportStyle = "markdown"`, call `Run`, write with
      `##class(RLM.Report).WriteTextToFile(text, outPath)` and return the report
      **text** (FR-007). The return type is `%String`, not `%Status`: `^RLMAudit`
      prints `$Length(report)` and T059 forbids editing it — see the amendment in
      contracts/README.md
- [x] T056 [US3] Rewrite `Gaia.RLM.Triage(outPath)` the same way, passing
      `"detection:b1"` as `Run`'s third argument
- [x] T057 [US3] Delete from `gaia-iml/src/Gaia/RLM.cls` every row of the
      removal table in contracts/README.md: `CallCount()`, `Ask()`, `Recurse()`,
      `ChooseDimension()`, `ShouldRecurse()`, `BaselineSpread()`, `Indent()`,
      `Report()`, the trace strings, and the `SPLITRATIO` / `SPLITMINROWS`
      parameters (FR-008). `MAXDEPTH` and `MAXCALLS` stay as engine
      configuration — `^RLMAudit` prints both
- [x] T058 [US3] Drop `Extends %AI.Agent` from `Gaia.RLM` and its `PROVIDER` /
      `MODEL` / `APIKEY` parameters — they moved to `Gaia.LLM.Agent`. An entry
      point that is also a provider cannot be handed a scripted provider for
      tests (research decision 2)
- [x] T059 [US3] Confirm `^RLMAudit` and `^RLMTriage` are unedited and still
      work: the signatures did not change, so the routines must not need to
- [x] T060 [US3] Run the Gaia suite: all US3 tests pass
- [x] T061 [US3] Run `Audit()` once against the real provider over all 74,998
      rows; check the figures reconcile — child counts sum to their parent, any
      gap disclosed (SC-004). Smoke gate, not a text assertion
- [x] T062 [US3] Recompute line counts under `gaia-iml/src/Gaia/`, diff against
      T004, and report both figures: lines lost, and that every line lost was
      library machinery rather than domain knowledge (SC-002, ≥500)
- [x] T063 [US3] Run the `rlm-iris` suite. Still green. **Gate.**

**Checkpoint**: the duplication is gone and the reports still get written.

---

## Phase 6: User Story 4 — the duplicated grammar goes (P3)

**Goal**: `Gaia/Slice.cls` deleted; `Gaia.RLM2` resolves through `RLM.Slice`.

**Independent Test**: every name the old grammar accepted still resolves, every
name it refused is still refused, and `Gaia.RLM2.Audit()` still reports.

### Tests for US4 — write these first

- [x] T064 [US4] Port the grammar tests in
      `gaia-iml/src/UnitTest/Gaia/RLM2.cls` to `RLM.Slice`, keeping every case:
      the whole slice enumeration accepted, and the injection attempts refused
      (SC-006). Tokens change from `reject_level:severe` to `reject_level:b3`;
      the accept/refuse verdicts must not
- [x] T065 [P] [US4] Add the injection test explicitly:
      `reject_level:severe' OR 1=1 --` is refused as a name the store does not
      offer, no query runs, and the refusal carries the grammar
- [x] T066 [P] [US4] Add the nesting test: a two-component name yields a
      predicate restricting both components and a label naming both
- [x] T067 [P] [US4] Add the FR-011 grep test: no occurrence of `Gaia.Slice`
      anywhere under `gaia-iml/src/`
- [x] T068 [US4] Run the Gaia suite and confirm the US4 tests fail for the right
      reason

### Implementation for US4

- [x] T069 [US4] Replace every `Gaia.Slice` call in
      `gaia-iml/src/Gaia/RLM2.cls` with the `RLM.Slice` equivalent against a
      `Gaia.Source`, leaving its own delegation budget and trace in place
      (FR-012 — the model owns the recursion there, so the library has nothing
      to lend it, and RLM2 exists to be compared against the engine)
- [x] T070 [US4] Update `gaia-iml/src/Gaia/Tools/SliceAnalyst.cls` and
      `Tools/Survey.cls` if either names `Gaia.Slice`
- [x] T071 [US4] Delete `gaia-iml/src/Gaia/Slice.cls`
- [x] T072 [US4] Run the Gaia suite: US4 tests pass and `Gaia.RLM2.Audit()`
      still produces a report
- [x] T073 [US4] Run the `rlm-iris` suite. Still green. **Gate.**

**Checkpoint**: one grammar, one whitelist, one place a name can be refused.

---

## Phase 7: User Story 5 — what survives is documented as what it is (P3)

**Goal**: the documentation describes the post-port design, in both
repositories.

- [x] T074 [P] [US5] Update `gaia-iml/README.md`: name `rlm-iris` as the
      dependency, state what `Gaia.Source` contributes and what the library
      supplies, and give the `--recursive` clone
- [x] T075 [P] [US5] Rewrite `Gaia.RLM2`'s class comment: the contrast is
      between the library's engine and model-driven delegation, not between two
      hand-written recursions
- [x] T076 [P] [US5] Update `gaia-iml/module.xml` description to match
- [x] T077 [P] [US5] Record in `rlm-iris/README.md` that a store outside the
      library's own test suite runs on it, with the measured figures: six
      dimensions, 22 children, 74,998 rows, lines removed
- [x] T078 [US5] Reconcile `specs/003-gaia-port/quickstart.md` against what the
      port actually does and correct any figure that moved. Every figure in it
      is claimed as verified
- [x] T079 [US5] Run `markdownlint-cli2 --fix` and `prettier --write` over every
      `.md` touched in both repositories, to zero errors

---

## Phase 8: Polish & cross-cutting

- [x] T080 Update `specs/003-gaia-port/plan.md` if the port exposed a library
      defect beyond `WriteTextToFile` — the fix and its test belong in
      `rlm-iris` under FR-014, and the plan's defect list is where it is recorded
- [x] T081 Run the full `rlm-iris` suite and the full Gaia suite one final time;
      report both counts against T002 and T003 (SC-007)
- [ ] T082 Walk quickstart.md end to end in a clean container to prove the
      `--recursive` clone path works for someone who is not on this laptop —
      **BLOCKED**: `git clone --recursive` fails with
      `upload-pack: not our ref 8b2bcf7`, because the submodule pin is a local
      commit. Unblocks the moment `rlm-iris` is pushed; needs explicit permission
- [x] T083 Confirm `^RunScript`, `result.csv` and the contest timing are
      untouched by this feature — diff the routine and re-run the timed path
      once
- [ ] T084 Commit in both repositories, separately, with no AI attribution.
      Nothing is pushed without explicit instruction

---

## Dependencies & Execution Order

### Phase dependencies

- **Phase 1 Setup**: no dependencies
- **Phase 2 Foundational**: needs Phase 1. **Blocks everything.** The library
  must compile in `gaia-iml-iris` before a class can extend it, and
  `WriteTextToFile` must exist before an entry point can be finished
- **Phase 3 US1** and **Phase 4 US2**: both need Phase 2 only, and are
  independent of each other
- **Phase 5 US3**: needs US1 and US2
- **Phase 6 US4**: needs US1 only (`RLM.Slice` resolves against a `Gaia.Source`).
  Independent of US3
- **Phase 7 US5**: last, because it describes what the phases did rather than
  what they were planned to do
- **Phase 8 Polish**: needs everything

### Within each phase

- Unit tests first, and confirmed failing for the right reason before any
  implementation. A test that fails to compile is not a failing test
- The phase's own suite, then the `rlm-iris` suite, is the gate. A phase that
  breaks the library suite found a library defect; FR-014 says the fix goes
  there

### Parallel opportunities

- T004, T005 together
- T012, T013 together
- T017–T027: all US1 tests, all different assertions in one new file — write
  together, they fail together
- T039–T041 together
- T047–T053 together
- T065–T067 together
- T074–T077 together
- US1 (Phase 3) and US2 (Phase 4) are fully independent after Phase 2
- US4 (Phase 6) can run alongside US3 (Phase 5) once US1 is done

---

## Implementation Strategy

### MVP

Phases 1–3. At T038 the library reads a real store it was not written alongside,
with no engine, no policy and no model involved. That is the claim the whole
extraction rests on, and it is testable before a single model call is spent.

### Incremental delivery

1. Phase 1 + 2 → the library compiles in the prototype's container
2. Phase 3 → the store is readable (MVP; the contract is proven or it is not)
3. Phase 4 → the provider is portable
4. Phase 5 → the ~700 lines leave and the reports still get written
5. Phase 6 → one grammar remains
6. Phase 7 + 8 → the documentation stops describing the old design

### What would make this feature fail usefully

If US1 cannot be written without reaching around `RLM.Source`'s six methods,
that is the finding, and it belongs in `rlm-iris` as a spec change rather than
in `Gaia.Source` as a workaround. The port is the instrument, not the goal.

---

## Notes

- The `"ck"` load qualifier is mandatory in both containers. A failing compile
  still prints "All PASSED"
- `$$macro(...)` cannot span source lines in ObjectScript — this bites
  `$$AssertEquals(`, `$$ERROR(` and `$$LogMessage(`, as MPP5612 cascading to
  `<SYNTAX>`
- Always run the whole suite name (`"RLM"`, `"Gaia"`); sub-suite paths fail with
  ERROR #5007
- Method names truncate at 31 characters
- Counts are printed, never asserted against remembered constants. That rule is
  why the wrong slice count was caught before implementation rather than after
- Commit after each logical group; push only on explicit instruction
