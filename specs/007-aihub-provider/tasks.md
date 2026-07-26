# Tasks: rlm-aihub

**Branch**: `007-aihub-provider` | **Spec**: [spec.md](spec.md) |
**Plan**: [plan.md](plan.md)

Test-first within every phase. Each phase ends with an end-to-end test that
gates the next. Baseline before this milestone: **300 passed / 0 failed** on the
portable `rlm-iris` container.

Two containers are in play, and every phase gate runs in both:

- `rlm-iris` — IRIS 2026.1 community, no `%AI.*`. The AI classes are skipped by
  `LoadDir` and their tests are absent. This must stay at 300+ passed / 0 failed.
- `rlm-iris-ai` — IRIS 2026.3.0AI Build 126U, this project's own container. All
  classes compile and the AI tests run.

## Phase 1 — Portability is provable (US4)

The constraint every later phase must not break, tested before any `%AI.*` code
exists.

- [x] T001 Create `src/UnitTest/RLMAIHub/Manifests.cls` asserting the two IPM
      manifests exist, that `rlm-aihub` declares a dependency on `rlm-core`, and
      that their resource sets are disjoint
- [x] T002 [P] Add to `src/UnitTest/RLMAIHub/Manifests.cls` a test that every
      class under the `RLM` package is free of the text `%AI.`, reading source
      text via `##class(UnitTest.RLM.EndToEndReplay).SourceTextOf(cls)`
- [x] T003 [P] Add to `src/UnitTest/RLMAIHub/Manifests.cls` a test that
      `RLM.Engine`, `RLM.Policy.LLM`, `RLM.Replay` and `RLM.Eval.Scorecard`
      contain no reference to `RLMAIHub` either — the dependency runs one way
- [x] T004 Create `module-aihub.xml` declaring `rlm-aihub`: name, version,
      `<Dependencies><ModuleReference><Name>rlm-core</Name></ModuleReference>`,
      `SourcesRoot src`, `<Resource Name="RLMAIHub.PKG"/>`, and a `UnitTest`
      entry for `UnitTest.RLMAIHub`
- [x] T005 Narrow `module.xml`'s unit-test entry so `rlm-core`'s test phase does
      not claim `UnitTest.RLMAIHub`, and confirm `RLM.PKG` still covers every
      shipped core class
- [x] T006 **Phase gate**: run the full suite on `rlm-iris`; T001–T003 pass and
      the prior 300 still pass

## Phase 2 — A decomposition runs through AI Hub (US1)

- [x] T007 Create `src/UnitTest/RLMAIHub/StubProvider.cls` extending
      `%AI.Provider`, overriding `ChatComplete` to return scripted replies from
      a `%List`, recording every `(model, messages, temperature, maxTokens)` it
      was called with, and optionally carrying a `usage` object
- [x] T008 [P] Create `src/UnitTest/RLMAIHub/Provider.cls` asserting `Complete`
      returns the stub's scripted reply and that the messages array is exactly
      two entries, `system` then `user`, matching `RLM.LLM.REST.BuildBody`'s shape
- [x] T009 [P] Add to `src/UnitTest/RLMAIHub/Provider.cls` a test that
      construction requires no URL, key or SSL configuration, and that `Model` is
      recorded on the object for the trace
- [x] T010 [P] Add to `src/UnitTest/RLMAIHub/Provider.cls` a test that
      `Temperature` and `MaxTokens` reach `ChatComplete` as given, and that unset
      values are passed as empty rather than as zero
- [x] T011 Add to `src/UnitTest/RLMAIHub/Provider.cls` a `Ready` test: absent
      provider names a reason, and a provider lacking the `ChatCompletion`
      capability is refused with a reason (FR6)
- [x] T012 Implement `src/RLMAIHub/Provider.cls` extending `RLM.LLM`:
      properties, `%OnNew`, `BuildMessages`, `Complete`, `Ready`
- [x] T013 Add `LastPromptTokens` / `LastCompletionTokens` to
      `src/RLMAIHub/Provider.cls`, populated from `Usage`, with a test pinning
      the observed `prompt_tokens` / `completion_tokens` key shape (FR5, A2)
- [x] T014 Create `src/UnitTest/RLMAIHub/EndToEndAIHub.cls`: run a full
      decomposition over a fixture source through `RLMAIHub.Provider` with a
      scripted stub, and assert the document equals the one the same script
      produces through `RLM.LLM.Null`
- [x] T015 Add to `src/UnitTest/RLMAIHub/EndToEndAIHub.cls` an assertion that the
      call count matches the `RLM.LLM.Null` run exactly — one bounded round-trip
      per decision, no loop
- [x] T016 **Phase gate**: full suite on `rlm-iris-ai` (AI tests run) and on
      `rlm-iris` (AI tests absent, 300+ still green)

## Phase 3 — A failure costs one slot, not the report (US2)

- [x] T017 Add to `src/UnitTest/RLMAIHub/StubProvider.cls` a mode that throws on
      a nominated call index
- [x] T018 [P] Add to `src/UnitTest/RLMAIHub/Provider.cls` a test that a throwing
      provider makes `Complete` return `""` with an error status naming the
      provider failure, and that `Complete` itself does not throw (FR3)
- [x] T019 [P] Add to `src/UnitTest/RLMAIHub/Provider.cls` a test that an empty
      `Content` is an error status, not an empty answer (FR4)
- [x] T020 Implement the `Try`/`Catch` conversion and the empty-content refusal
      in `src/RLMAIHub/Provider.cls`
- [x] T021 Add to `src/UnitTest/RLMAIHub/EndToEndAIHub.cls` a test that a run
      whose second call throws still produces a report, discloses the failure,
      and shows the slot spent in the budget
- [x] T022 **Phase gate**: full suite in both containers

## Phase 4 — Truncation is refused without a finish reason (US3)

- [x] T023 [P] Add to `src/UnitTest/RLMAIHub/Provider.cls` a test that a response
      whose `completion_tokens` equals `MaxTokens` is an error status naming
      truncation, and the partial text is not returned
- [x] T024 [P] Add the boundary test: `completion_tokens` one below `MaxTokens`
      succeeds and returns the text — the proxy must not refuse everything
- [x] T025 [P] Add a test that with no `MaxTokens` set, no truncation check runs
      and no false refusal occurs
- [x] T026 [P] Add a test that a response with no `usage` object at all
      succeeds — absent usage is not evidence of truncation
- [x] T027 Implement the truncation inference in `src/RLMAIHub/Provider.cls`,
      with a comment recording that the platform exposes no finish reason and why
      over-refusing is the correct direction of error
- [x] T028 **Phase gate**: full suite in both containers

## Phase 5 — The instance's policy governs the call (US5)

- [x] T029 Create `src/UnitTest/RLMAIHub/StubAudit.cls` extending
      `%AI.Policy.Audit`, recording each `%LogExecution` call
- [x] T030 [P] Create `src/UnitTest/RLMAIHub/StubAuth.cls` extending
      `%AI.Policy.Authorization`, with a refuse mode and a throw mode
- [x] T031 [P] Add to `src/UnitTest/RLMAIHub/Provider.cls` a test that an
      attached audit policy receives the call with its duration and status
- [x] T032 [P] Add a test that an audit policy is passed no prompt or completion
      text beyond what the run already discloses — Principle I applies to the
      policy seam too
- [x] T033 [P] Add a test that a refusing authorization policy makes `Complete`
      return `""` with a status naming the refusal
- [x] T034 [P] Add a test that a policy which itself throws is converted to a
      status like any other failure
- [x] T035 [P] Add a test that absent policies change nothing — same result as
      Phase 2's baseline call (FR10)
- [x] T036 Implement `AuthPolicy` / `AuditPolicy` consultation in
      `src/RLMAIHub/Provider.cls`
- [x] T037 Add to `src/UnitTest/RLMAIHub/EndToEndAIHub.cls` a run under a
      refusing policy, asserting the report discloses the refusal rather than
      omitting the slice
- [x] T038 **Phase gate**: full suite in both containers

## Phase 6 — Docs and the milestone gate

- [x] T039 Write `specs/007-aihub-provider/quickstart.md` with the figures the
      code actually printed, not invented ones
- [x] T040 [P] Update `docs/SPEC.md` §3 architecture block: the AI Hub provider
      is `RLMAIHub.Provider` over `%AI.Provider.ChatComplete`, not
      `RLM.LLM.AIHub` over `%AI.Agent.Chat()` — and say why the agent path was
      rejected
- [x] T041 [P] Update `docs/SPEC.md` §3.1 to name `module-aihub.xml` and the
      `RLMAIHub` package, recording that IPM's package resource is recursive
- [x] T042 [P] Update `docs/SPEC.md` §6: mark the parallel fan-out row still
      blocked on ai-hub-eap#26, and record that `%AI.LLM.Response` carries no
      finish reason
- [x] T043 [P] Update `docs/SPEC.md` §7 M5 bullet to "Shipped" with an account of
      what landed and what did not
- [x] T044 [P] Check off `- [x] **M5** \`rlm-aihub\``in`README.md`, and check
      off M1–M4 which are shipped but still unchecked there
- [x] T045 [P] Update `README.md`'s Portability section: `rlm-aihub` supplies a
      provider, and the engine gained no `%AI.` reference
- [x] T046 Run `markdownlint-cli2 --fix` and `prettier --write` on every `.md`
      touched, then re-lint to confirm zero errors
- [x] T047 **Milestone gate**: full suite green in both containers; the portable
      run at 300+ with no prior test edited; commit

## Dependencies

- Phase 1 gates everything: the package layout is what keeps `rlm-core` portable.
- Phase 2 gates Phases 3–5 — they all extend the same provider and stub.
- Phases 3, 4 and 5 are independent of each other and could be reordered.
- Phase 6 requires all prior phases.

## Notes

- `[P]` marks tasks that touch different files or add independent test methods,
  so they can be written in one pass.
- Out of scope, per spec A4: engine-managed parallel fan-out, blocked on
  ai-hub-eap#26.
