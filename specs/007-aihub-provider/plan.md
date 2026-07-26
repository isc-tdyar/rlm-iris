# Implementation Plan: rlm-aihub

**Branch**: `007-aihub-provider` | **Spec**: [spec.md](spec.md) | **M5**

## Technical Context

- **Language**: ObjectScript.
- **Portable floor**: IRIS 2026.1 community — the `rlm-iris` container, which has
  **no `%AI.*`** (`%Dictionary.CompiledClass.%ExistsId("%AI.Tool")` returns 0).
- **AI floor**: IRIS 2026.3.0AI Build 126U — this project's own `rlm-iris-ai`
  container, run from
  `docker.iscinternal.com/.../irishealth-community:2026.3.0AI.126.0`. A new
  container owned by this project, because CLAUDE.md forbids using another
  project's (`gaia-comm-probe` runs the same image and is off limits).
- **Tests**: `%UnitTest` under `src/UnitTest/RLM`, no live model, no network.

## Constitution Check

| Principle                              | How this feature holds it                                                                                                                              |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| I. Model never receives store contents | Untouched — this milestone adds a transport, not a source. The prompt is whatever the engine already built.                                            |
| II. Model never authors a predicate    | Untouched — `RLM.Slice` still whitelists. Notably this is why `%AI.Agent` with tools is refused: a tool loop is an action space we do not enumerate.   |
| III. Caps reported, never hidden       | The live risk. `%AI.LLM.Response` has no finish reason, so truncation is inferred from usage vs `MaxTokens` and refused. US3 exists entirely for this. |
| IV. Test-first, deterministically      | A `%AI.Provider` subclass stub returns scripted replies; every AI test runs with no key.                                                               |
| V. A run is replayable                 | `Complete` stays a pure text-in/text-out call. No session, no history, so replay is unaffected.                                                        |
| VI. Portable by default                | The load-bearing constraint. Enforced structurally by package layout, and asserted by a test over `rlm-core`'s shipped source text.                    |

No violations. One tension resolved explicitly: the platform's ergonomic entry
point (`%AI.Agent`) is rejected in favour of its lower-level one
(`%AI.Provider.ChatComplete`) because the ergonomic one runs a tool loop.

## Phase 0 — Research (complete)

Measured on `rlm-iris-ai`, not assumed. All three assumptions the design rests on
were checked before planning:

| Question                                       | Finding                                                                                                                                  | Consequence                                                         |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| Does `%AI.*` exist on the AI image?            | 56 `%AI.*` classes; `%AI.Agent` and `%AI.Tool` both present                                                                              | M5 is buildable, in this project's own container                    |
| Which primitive matches `RLM.LLM`?             | `%AI.Agent.Chat` loops (`MaxIterations = 10`); `%AI.Provider.ChatComplete` is stateless single-shot returning `%AI.LLM.Response`         | Build on `ChatComplete`                                             |
| Is there a finish reason?                      | No. `%AI.LLM.Response` has `Content`, `ToolCalls`, `Usage` only; `FromJSON` reads exactly those three keys                               | Truncation must be inferred (US3)                                   |
| Can the callout be stubbed without a key? (A1) | Yes — a subclass overriding `ChatComplete` never reaches `$ZF(-6)`. Verified: stub returned scripted content and usage                   | The test seam is a `%AI.Provider` subclass                          |
| What shape is `Usage`? (A2)                    | `FromJSON` passes the `usage` object through verbatim, so it is whatever the provider sent; OpenAI's `completion_tokens` reads back fine | Read `completion_tokens`, tolerate absence, pin the shape in a test |
| Does `Create` prove reachability?              | No — `Create("openai", {"api_key": "sk-not-a-real-key"})` returned a provider object and listed capabilities                             | Readiness is separate from construction (FR6)                       |
| Are there policy hooks?                        | `%AI.Policy.Authorization.%CanExecute(tool, call, metadata)`, `%AI.Policy.Audit.%LogExecution(call, metadata, result, duration, status)` | US5 uses these signatures                                           |

Two findings changed the spec rather than the plan:

- **`RLM.Trace` records characters, not tokens.** `RLM.Engine` fills
  `tokensIn`/`tokensOut` with `$Length(prompt)`/`$Length(out)`. Writing real
  token counts there for one provider only would make the scorecard's comparison
  between providers meaningless, and fixing it properly means changing
  `RLM.Trace` for every provider — which SC2 puts out of scope. FR5 was rewritten
  to expose usage on the provider object instead.
- **`<Resource Name="RLM.PKG"/>` is recursive with no exclude mechanism.** A
  class named `RLM.LLM.AIHub` ships inside `rlm-core`. This is why the package
  layout below is a requirement and not a preference.

## Phase 1 — Design

### Package layout

```text
src/RLM/                     rlm-core  — unchanged, no %AI. reference anywhere
src/RLMAIHub/                rlm-aihub — every %AI.* touching class
  Provider.cls               RLM.LLM subclass over %AI.Provider.ChatComplete
  Policy.cls                 optional authorization + audit wrapper
src/UnitTest/RLMAIHub/       tests, skipped where %AI.* is absent
```

`RLMAIHub` rather than `RLM.AIHub`: the parent module's resource is the package
`RLM.PKG`, which includes every subpackage, so a nested name cannot be excluded
from it. A sibling top-level package is the only layout under which the two
manifests are provably disjoint — which US4 asserts by comparing them.

The spec's US1 named the class `RLM.AIHub.LLM`. That name is abandoned here for
the reason above; the shipped name is `RLMAIHub.Provider`.

### `RLMAIHub.Provider Extends RLM.LLM`

Properties: `ProviderName`, `Model` (inherited), `Temperature`, `MaxTokens`,
`AuthPolicy`, `AuditPolicy`, and read-only-by-convention `LastPromptTokens`,
`LastCompletionTokens`.

`%OnNew(providerName, model, settings)` — resolves the provider via
`%AI.Provider.Create` when settings are supplied, otherwise by name alone. No
URL, no bearer token, no SSL configuration (FR2).

`Complete(instructions, prompt, .sc)`:

1. Build `[{"role":"system",...},{"role":"user",...}]` — the same two-message
   shape `RLM.LLM.REST.BuildBody` sends, so the two providers see one prompt.
2. Consult `AuthPolicy.%CanExecute` if set; a refusal returns `""` with the
   refusal status (US5).
3. Call `ChatComplete` inside a `Try`. Every exception becomes a status (FR3) —
   `%AI.*` throws where `RLM.LLM`'s contract requires a status.
4. Reject an empty `Content` (FR4).
5. Reject a completion whose reported `completion_tokens` reaches `MaxTokens`
   (FR4, US3), when both are known.
6. Record usage into `LastPromptTokens` / `LastCompletionTokens` (FR5).
7. Report duration and status to `AuditPolicy.%LogExecution` if set (US5).

`Ready(.reason)` — construction proves nothing (Phase 0), so readiness asks
whether `%AI.Provider` exists, whether the named provider resolves, and whether
it advertises `ChatCompletion` in `GetCapabilities()`.

### Truncation without a finish reason

`completion_tokens = MaxTokens` is a proxy. It over-refuses when an answer
legally ends on the limit. That is the correct direction of error under
Principle III — a false refusal is disclosed and costs one slot; a false
acceptance puts a half-sentence into a report as a decision. The test asserts
both the refusal and its boundary: one token below the limit must succeed.

### Skipping, not failing, where `%AI.*` is absent

Measured on both containers rather than designed around: `$System.OBJ.LoadDir`
with `"ck"` **skips** a class whose superclass is missing and continues the load.
On 2026.1, `RLMAIHub.Probe Extends %AI.Provider` produced
`ERROR #5373: Class '%AI.Provider' ... does not exist / Skipping class` and
`Detected 1 errors during load` — and the rest of the tree still compiled, with
the existing suite reporting 300 passed / 0 failed.

So one `src/` tree serves both containers and no compile-list narrowing is
needed. Two consequences the tests must respect:

- The `%AI.*`-dependent classes are simply absent on 2026.1, so any test class
  that names one at compile time is also absent, and `%UnitTest` never sees it.
  A test class that must _run_ in both containers may therefore not reference
  `%AI.*` statically — it resolves the stub through `$ClassMethod` /
  `%New($ClassName)` indirection, or lives among the skipped classes.
- The skip prints an error line during load. That is expected output, not a
  regression, so the milestone gate counts passed/failed tests rather than
  grepping the load log for the word "error".

## Phase 2 — Task strategy

Test-first per phase, each phase gated on its own end-to-end test:

- **Phase 1 (US4)** Package layout + both manifests + the portability test.
  Deliberately first: it is the constraint every later phase must not break, and
  it is testable before any `%AI.*` code exists.
- **Phase 2 (US1)** Stub provider, `RLMAIHub.Provider`, prompt shape, full
  decomposition through it.
- **Phase 3 (US2)** Failure conversion, empty-content refusal, run-survives-failure.
- **Phase 4 (US3)** Truncation inference and its boundary.
- **Phase 5 (US5)** Policy hooks.
- **Phase 6** Docs, both-container suite runs, milestone gate.

## Complexity Tracking

| Concern                                      | Why it is accepted                                                                                                                     |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| A second container for the project           | Required: the portable floor has no `%AI.*` and another project's AI container may not be crossed. It is this project's own container. |
| A second top-level package (`RLMAIHub`)      | Forced by IPM's recursive package resource. The alternative ships `%AI.*` inside `rlm-core`, which is the failure SPEC §3.1 forbids.   |
| Truncation inferred from token counts        | The platform exposes no finish reason. Inferring and over-refusing is the only option that keeps Principle III true.                   |
| Two compile paths (portable vs AI container) | Unavoidable: a class extending `%AI.Provider` cannot compile where that class is absent.                                               |
