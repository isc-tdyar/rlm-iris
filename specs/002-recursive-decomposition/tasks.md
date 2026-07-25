# Tasks: Recursive decomposition

**Input**: Design documents from `/specs/002-recursive-decomposition/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md,
contracts/README.md, quickstart.md

**Tests are mandatory.** Every story phase writes its unit tests before the code
they test, and ends on an E2E gate that must pass before the next phase starts.

**Container**: all test runs happen in `rlm-iris` (32805 → 1972) and nowhere else.

**Suite invocation** (the `"ck"` qualifier is mandatory — without it classes
import without compiling and `%UnitTest` skips them while printing "All PASSED"):

```bash
printf 'do $system.OBJ.LoadDir("/home/irisowner/dev/src","ck",,1)\n
set ^UnitTestRoot="/home/irisowner/dev/src/UnitTest"\n
do ##class(%%UnitTest.Manager).RunTest("RLM","/noload/nodelete/norecursive")\n
halt\n' | docker exec -i rlm-iris iris session IRIS -U USER
```

Always run the whole `"RLM"` suite. Sub-suite paths (`RunTest("RLM/Decision")`)
fail with ERROR #5007.

## Phase 1: Setup

- [x] T001 Verify the `rlm-iris` container is running and the suite is green at
      93 tests before any edit, recording the count in
      `specs/002-recursive-decomposition/tasks.md` under Phase 1 notes
- [x] T002 Capture the SC-002 baseline: run the existing depth-1 end-to-end case
      and store its exact report text as a fixture constant in
      `src/UnitTest/RLM/EndToEnd.cls` so byte-identity is asserted against a
      recorded string rather than a re-derivation

## Phase 2: Foundational (blocking prerequisites)

- [x] T003 Add `Method Ready(Output reason As %String) As %Boolean` to
      `src/RLM/Source.cls`, concrete, returning 1 with `reason` set to `""`
- [x] T004 [P] Add `Property MaxDepth As %Integer [ InitialExpression = 1 ]` and
      `Property ReportStyle As %String [ InitialExpression = "plain" ]` to
      `src/RLM/Engine.cls` with no behaviour change yet
- [x] T005 [P] Add `Property Style As %String [ InitialExpression = "plain" ]` to
      `src/RLM/Report.cls` with no behaviour change yet
- [x] T006 Run the suite; 93 tests still pass and T002's recorded baseline still
      matches — the three new properties are inert by construction

## Phase 3: User Story 1 — Decompose below the root (P1)

**Goal**: `MaxDepth` = n decomposes n levels deep, depth-first pre-order, with
depth 1 unchanged.

**Independent test**: a two-dimension fixture run at `MaxDepth` = 2 makes a
second decision inside a depth-1 slice; the same store at `MaxDepth` = 1
produces T002's recorded text byte for byte.

### Tests first (P1)

- [x] T007 [P] [US1] Create `src/UnitTest/RLM/FixtureNested.cls`: a store with
      two categorical dimensions where one depth-1 slice still mixes populations
      and its sibling does not, so a decision is taken on one and declined on the
      other
- [x] T008 [P] [US1] Create `src/UnitTest/RLM/EngineRecursion.cls` with unit
      tests for: traversal is declaration order (pre-order); `depth` reaches
      trace field 2 as the real depth; `Candidates(path)` is called with the
      non-empty path; a dimension used by an ancestor is not offered again
- [x] T009 [US1] Add to `src/UnitTest/RLM/EngineRecursion.cls`: the frontier
      refuses to push past `RLM.Slice.MAXDEPTH` and says so in a caveat rather
      than letting `RLM.Slice.Resolve` refuse the path later
- [x] T010 [US1] Add to `src/UnitTest/RLM/EngineRecursion.cls`: FR-003 — a slice
      the source says is not worth splitting costs zero peeks and zero decisions,
      asserted by counting `Budget.PeeksUsed` across the run
- [x] T011 [US1] Add to `src/UnitTest/RLM/EngineRecursion.cls`: FR-004/FR-005 —
      a budget too small to fund a child means no split is chosen, and the
      unreached slices are named in the report's caveats
- [x] T012 [US1] Add the SC-002 assertion to `src/UnitTest/RLM/EndToEnd.cls`:
      default-depth output equals T002's recorded baseline exactly

### Implementation (P1)

- [x] T013 [US1] Replace the flat depth-1 loop in `Run` in `src/RLM/Engine.cls`
      with an explicit stack of `$ListBuild(path, depth)` pairs, pushed in
      reverse declaration order, per data-model.md's frontier
- [x] T014 [US1] In `src/RLM/Engine.cls`, call `..Source.ShouldSplit(peek)`
      before spending a decision on a slice, and skip it when false
      (FR-003, research decision 3)
- [x] T015 [US1] In `src/RLM/Engine.cls`, gate the push on `MaxDepth` and on the
      grammar ceiling, and record every unreached slice for the caveat list
      (FR-004, FR-005)
- [x] T016 [US1] In `src/RLM/Engine.cls`, pass the real depth to
      `..Trace.Add(...)` and `..Trace.AddDecision(...)` so trace field 2 carries
      it (FR-006)
- [x] T017 [US1] **Phase gate**: run the whole `"RLM"` suite. Depth 2 over
      `FixtureNested` produces a nested decision; depth 1 is byte-identical.
      Both must pass before Phase 4.

## Phase 4: User Story 2 — Bucketed dimensions (P2)

**Goal**: a continuous column splits on declared breakpoints, indistinguishably
from a categorical dimension.

**Independent test**: buckets over `Widget.Rating` partition the rows — the child
counts plus the null count equal the parent count — and a policy cannot tell the
bucketed dimension from the categorical one. (`Rating` rather than `Price`:
`Price` is the measure the split metric is computed over, so bucketing it would
make the dimension and the metric the same column and the partition assertions
would not be independent of the scoring ones.)

### Tests first (P2)

- [x] T018 [P] [US2] Add a nullable numeric property to
      `src/UnitTest/RLM/Widget.cls` and seed rows with nulls in it
- [x] T019 [P] [US2] Create `src/UnitTest/RLM/SourceBucketed.cls` with unit
      tests for declaration-time refusal: unknown property, empty breakpoint list,
      non-ascending breakpoints — each returns a bad `%Status` and declares no
      dimension
- [x] T020 [US2] Add to `src/UnitTest/RLM/SourceBucketed.cls`: `n` breakpoints
      yield `n+1` children with tokens `b0`…`bn` in ascending order, and
      supplied `labels` override the derived range labels one for one
- [x] T021 [US2] Add to `src/UnitTest/RLM/SourceBucketed.cls`: FR-008 half-open
      boundaries — a row exactly on a breakpoint lands in the upper bucket, and
      the child counts plus `NullCount()` sum to the parent's count
- [x] T022 [US2] Add to `src/UnitTest/RLM/SourceBucketed.cls`: FR-009 — the
      dimension spec from `Dimensions()` for a bucketed dimension has the same
      shape as a categorical one, asserted field by field
- [x] T023 [US2] Add to `src/UnitTest/RLM/SourceTable.cls`: the widened term
      encoding round-trips — `Predicate()` output feeds `Peek()` for a bucketed
      slice, a categorical slice, and a path mixing both
- [x] T024 [US2] Add to `src/UnitTest/RLM/EndToEnd.cls`: SC-003 — a bucketed
      dimension over 10,000 rows of a continuous column yields the declared
      number of children, and the null gap appears in the report

### Implementation (P2)

- [x] T025 [US2] Widen the private term encoding in `src/RLM/Source/Table.cls`
      from `property<C2>value` to `property<C2>op<C2>value`, updating
      `Predicate()` and `Peek()` together; every operator comes from the table in
      data-model.md
- [x] T026 [US2] Implement `AddBucketedDimension` in
      `src/RLM/Source/Table.cls` with the six obligations in
      contracts/README.md, validating at declaration time
- [x] T027 [US2] Extend `Dimensions()` in `src/RLM/Source/Table.cls` to emit
      bucketed dimensions in the same shape as categorical ones, without a
      `SELECT DISTINCT` on the bucketed property
- [x] T028 [US2] Implement `NullCount(predicate)` in `src/RLM/Source/Table.cls`,
      returning 0 when no bucketed dimension is declared. Signature widened during
      implementation to `NullCount(predicate, dimension)` and given a concrete
      default on `RLM.Source`: the engine asks about the dimension it is splitting
      on, and a store may bucket two columns with different null counts, so a
      store-wide figure would disclose the wrong gap.
- [x] T029 [US2] In `src/RLM/Engine.cls`, disclose the bucket/parent sum gap as
      a caveat when `NullCount()` is non-zero for a split dimension
- [x] T030 [US2] **Phase gate**: run the whole `"RLM"` suite. Buckets over
      `Widget.Price` partition correctly, counts sum with nulls disclosed, and
      SC-002 still holds.

## Phase 5: User Story 3 — Markdown report and rendered trace (P3)

**Goal**: the same run renders as plain or Markdown with identical figures,
and a trace can be read by a human.

**Independent test**: plain style is byte-identical to the pre-feature output;
Markdown differs only in formatting; `RenderTrace` names every row including
declined decisions.

### Tests first (P3)

- [x] T031 [P] [US3] Create `src/UnitTest/RLM/ReportStyle.cls` with unit tests
      for: plain `Heading` byte-identity against the pre-feature string; Markdown
      `Heading` emits `##` and no `-----`; `Bullet(text, depth)` indents by depth;
      `Fenced` fences in Markdown and indents in plain, passing content through
      unaltered
- [x] T032 [US3] Add to `src/UnitTest/RLM/ReportStyle.cls`: `RenderTrace` returns
      one line per trace row with role, depth, slice and outcome, and includes a
      declined decision with its reason (FR-011)
- [x] T033 [US3] Add to `src/UnitTest/RLM/EndToEnd.cls`: SC-004 — run the same
      question twice, once per style, and assert every number and every caveat
      present in one is present in the other

### Implementation (P3)

- [x] T034 [US3] Make `Heading()` style-aware and add `Bullet(text, depth)` and
      `Fenced(lines, language)` to `src/RLM/Report.cls`, branching only inside
      those three primitives
- [x] T035 [US3] Implement `ClassMethod RenderTrace(runId, durable)` in
      `src/RLM/Report.cls`, reading the trace global and the `"d"` sidecar for
      decisions and their reasons
- [x] T036 [US3] In `src/RLM/Engine.cls`, pass `..ReportStyle` to the report it
      builds, and emit slice findings through `Bullet(text, depth)` so nesting
      survives (FR-012)
- [x] T037 [US3] **Phase gate**: run the whole `"RLM"` suite. Markdown and plain
      carry the same figures; plain is byte-identical; nested bullets indent.

## Phase 6: User Story 4 — Ask about part of a store (P4)

**Goal**: `Run(question, .traceId, rootPath)` confines a run to a slice, states
that it did, and refuses a bad scope before any model call.

**Independent test**: a run scoped to one slice never peeks outside it, does not
offer the scoping dimension as a split, and refuses `"shape:round"` with
`llm.Calls` = 0.

### Tests first (P4)

- [x] T038 [P] [US4] Add to `src/UnitTest/RLM/EngineRecursion.cls`: every peek in
      a scoped run carries the scope as a prefix, asserted by recording the
      predicates the source was asked for
- [x] T039 [US4] Add to `src/UnitTest/RLM/EngineRecursion.cls`: the scoping
      dimension is absent from `Candidates(rootPath)`, and a scope one level deep
      leaves exactly `MAXDEPTH - 1` levels of decomposition
- [x] T040 [US4] Add to `src/UnitTest/RLM/EngineRecursion.cls`: an unresolvable
      scope returns a report naming the refusal with zero model calls, using the
      null LLM's call counter
- [x] T041 [US4] Add to `src/UnitTest/RLM/EndToEnd.cls`: SC-005 — a scoped run's
      report states its scope wherever it describes the store, so no figure is
      presented as the whole store's (FR-014)

### Implementation (P4)

- [x] T042 [US4] Add the `rootPath As %String = ""` argument to `Run` in
      `src/RLM/Engine.cls`, resolve it through `RLM.Slice.Resolve` before any
      model call, and seed the frontier with it at depth 0
- [x] T043 [US4] On a resolve failure in `src/RLM/Engine.cls`, return a report
      stating the refusal and make no call (contract obligation 3)
- [x] T044 [US4] In `src/RLM/Engine.cls`, carry the scope's label from `Resolve`
      into the store description and every heading that names the store (FR-014)
- [x] T045 [US4] **Phase gate**: run the whole `"RLM"` suite. A scoped run is
      confined and says so; a bad scope is refused call-free; SC-002 holds.

## Phase 7: User Story 5 — Refuse a store that is not ready (P5)

**Goal**: a store that reports itself unfit costs zero model calls, and nothing
in `Run` reaches the caller as an exception.

**Independent test**: a not-ready fixture returns its reason with zero model
calls; a source that throws yields a report naming the failure rather than
propagating it.

### Tests first (P5)

- [x] T046 [P] [US5] Create `src/UnitTest/RLM/FixtureNotReady.cls`: a source
      overriding `Ready(Output reason)` to return 0 with an actionable reason, and
      a sibling fixture whose `Peek` throws (`FixtureThrows.cls`). Two more
      fixtures were needed for T048 and are not interchangeable with it:
      `PolicyThrows.cls` and `LLMThrows.cls`. Each of the three throws from a
      different frame — below the engine, inside the seam it calls, and two frames
      down inside the policy — and a `Try` positioned to catch the first can miss
      the third, so one throwing fixture would not have covered FR-016.
- [x] T047 [US5] Add to `src/UnitTest/RLM/EndToEnd.cls`: SC-006 — a run over the
      not-ready fixture makes zero model calls and its report contains the reason
- [x] T048 [US5] Add to `src/UnitTest/RLM/Engine.cls`: FR-016 — a throwing
      source, a throwing policy and a throwing provider each yield a report whose
      caveats name the failure, and `Run` returns normally in all three cases
- [x] T049 [US5] Add to `src/UnitTest/RLM/Engine.cls`: an existing source that
      does not override `Ready` runs unchanged (FR-015's default)

### Implementation (P5)

- [x] T050 [US5] In `src/RLM/Engine.cls`, check `..Source.Ready(.reason)` before
      any model call and return the reason as a report when false
- [x] T051 [US5] Wrap the body of `Run` in `src/RLM/Engine.cls` in a
      `Try`/`Catch` with a single exit point, since `Quit <value>` is not allowed
      in a `Catch` block (research decision 7). Implemented by moving the body to
      a private `Execute(question, .traceId, rootPath, report)` and leaving `Run`
      as the wrapper: the body has several early returns, and threading a result
      variable through each of them silently returns `""` from any one that is
      missed. `Run` builds the report and passes it in so the `Catch` still holds
      what was written before the failure.
- [x] T052 [US5] **Phase gate**: run the whole `"RLM"` suite. A not-ready store
      costs zero calls; every throw becomes a report; SC-002 holds.

## Phase 8: Polish and cross-cutting

- [x] T058 Widen `RLM.Policy.ChooseSplit` with a `path` argument and add
      `RLM.Policy.ChildPredicate`. Discovered during Phase 3: `Greedy` built a
      child predicate from `dim:token` alone, so at depth 1 or below it scored
      the store-wide child rather than the child of the slice it was dividing. The
      score it reported was a real number about the wrong population, which is
      why no existing test caught it. contracts/README.md's "What is not in the
      contract" claim was wrong and is corrected.

- [x] T053 [P] Update `README.md` with `MaxDepth`, `ReportStyle`, bucketed
      dimensions, the root scope argument and `Ready()`. The opening example was
      also wrong before this feature: it called `eng.Report(...)`, which does not
      exist, over `RLM.Source.Global`, which is M2.
- [x] T054 [P] Update the class comment on `src/RLM/Engine.cls` to describe the
      frontier and the seven obligations from contracts/README.md
- [x] T055 Verify every snippet in
      `specs/002-recursive-decomposition/quickstart.md` runs as written,
      correcting the document where it does not. Four corrections: bucket labels
      are `Price < 10` / `Price [10,50)`, not prose; the null-gap caveat names the
      slice; the scope refusal carries `ERROR #5001` through verbatim; and the
      depth-2 call count is 6 under `RLM.Policy.LLM`, which the default budget
      of 8 does cover — the document claimed it would not.
- [x] T056 Measure and record SC-001 (depth-2 metric below its parent's) and
      SC-003 (bucket count over 10,000 rows) as numbers in the test output, not
      as assertions of existence. Both now log through `$$$LogMessage` and appear
      in every suite run:
      `SC-001: root split on 'color' left metric 0.520; 'size' below it left 0.055`
      and `SC-003: 10010 rows bucketed into 3 children with 5 model calls; 1668
    rows in no bucket, disclosed`. `$$$LogMessage` obeys the same one-line-macro
      rule as `$$$Assert*` and `$$$ERROR`.
- [x] T057 Run `markdownlint-cli2 --fix` and `prettier --write` on every `.md`
      touched in this feature

- [x] T059 Fix the column alignment in `RLM.Report.RenderTrace`. Found verifying
      T055: `$Justify(role, -10)` returns the role unpadded, because `$Justify`'s
      third argument is a decimal count and it has no left-aligning form — so the
      depth column moved with the length of each role name and the rendered trace
      read as a list rather than a table. The T032 tests passed throughout, since
      they grep for text. Covered now by `TestRenderTraceAlignsTheDepthColumn`.

## Dependencies

- Phase 1 → Phase 2 → Phase 3. Phase 3 (US1) must land first: US3's nesting,
  US4's scope-as-path and US5's abort-before-call all sit on the traversal it
  builds.
- Phase 4 (US2) touches only `src/RLM/Source/Table.cls` plus one caveat in the
  engine, so it is technically independent of Phase 3 and could run in parallel.
  It is sequenced second because the prototype needs both and the depth-2 case
  is more convincing over a bucketed column.
- Phases 5, 6, 7 each depend on Phase 3 only, and on nothing from each other.
  Phase 6 (US4) landed with Phase 3: a scope is a non-empty starting path, so the
  traversal delivered it with one `Resolve` call and no scoping-specific code.
- Phase 8 depends on all of the above.

## Parallel opportunities

Within a phase, tasks marked `[P]` touch different files and can be written
together: T004/T005; T007/T008; T018/T019; T031 alone; T038 alone; T046 alone;
T053/T054. Everything else in a phase edits a file another task in that phase
also edits, so it is sequential.

## Implementation strategy

US1 alone is a shippable increment: recursion with everything else defaulted off.
Each later phase adds one capability and re-asserts SC-002, so the depth-1
document is proven unchanged five separate times. SC-007 — the prototype's five
dimensions and 21 slices — is verified in the `gaia-iml` port, not here.
