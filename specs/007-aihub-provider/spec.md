# Feature Specification: rlm-aihub

**Branch**: `007-aihub-provider` | **Milestone**: M5 | **Status**: Draft

## Why this exists

Every milestone so far has been portable on purpose. `RLM.Engine` names
`RLM.Source`, `RLM.LLM`, `RLM.Budget`, `RLM.Trace` and `RLM.Report` and nothing
else, and `rlm-core` installs on a base IRIS with no AI Hub at all. M5 is where
that abstraction gets tested rather than asserted: a second `RLM.LLM`
implementation, built on `%AI.*`, that the engine cannot tell apart from
`RLM.LLM.REST`.

The value is not "now it works with AI Hub". It is:

1. **A configured provider instead of a URL and a key.** `RLM.LLM.REST` asks the
   caller for a base URL, a bearer token and an SSL configuration. On an AI Hub
   instance the provider is already configured, named, and credentialed at the
   instance level, and a run should be able to say "use the configured provider"
   without a copy of the key ending up in a `%New()` argument.
2. **Governance the engine gets for free.** AI Hub carries an authorization and
   audit policy seam (`%CanExecute`, `%LogExecution`). A slice is already an
   authorizable query — Principle I's whole point — so routing the model call
   through the instance's policy means the peek and the completion are governed
   by the same machinery, not two.
3. **Proof the seam holds.** If a second provider needs the engine to change,
   the abstraction was wrong. This milestone's real acceptance criterion is that
   `RLM.Engine`, `RLM.Policy.LLM`, `RLM.Replay` and `RLM.Eval.Scorecard` gain no
   `%AI.` reference and no new branch.

### What the platform actually offers, and what it does not

Measured on this project's own AI container (`irishealth-community:2026.3.0AI`
Build 126U), not assumed:

- `%AI.Agent.Chat(session, input)` maintains a session and **runs a tool loop**,
  `MaxIterations` defaulting to 10. It is the wrong primitive here: the design
  is one bounded round-trip per decision with all evidence pre-computed, and a
  loop the engine does not control breaks both budget accounting and replay.
- `%AI.Provider.ChatComplete(model, messages, temperature, maxTokens, ...)` is
  stateless, single-shot, and returns `%AI.LLM.Response`. That is exactly the
  `RLM.LLM` contract, so **this is the primitive M5 builds on**.
- `%AI.LLM.Response` carries `Content`, `ToolCalls` and `Usage`. It carries **no
  finish reason** — `%AI.LLM.Response.FromJSON` reads only those three keys. So
  the truncation rejection that Principle III requires, and that
  `RLM.LLM.REST` implements by reading `finish_reason`, has no direct
  equivalent and must be reconstructed from `Usage`.
- `%AI.Provider.Create(name, settings)` succeeds with a syntactically valid but
  unusable key, so construction proves nothing about reachability. Readiness has
  to be a separate question from construction.

## User Scenarios

### US1 — Run a decomposition through the instance's configured provider (P1)

An engineer on an AI Hub instance points an RLM run at a store and names the
provider the instance already has configured. They do not supply a URL, a key or
an SSL configuration, and the report they get back is the same shape as the one
`RLM.LLM.REST` produces.

**Why this priority**: it is the milestone. Without it there is no second
provider and nothing to test the seam against.

**Independent Test**: construct `RLM.AIHub.LLM` against a stub provider,
run a full decomposition, and compare the document to the one the same script
produces through `RLM.LLM.Null`.

**Acceptance**:

- Given an instance with a configured provider, when a run is constructed with
  the provider name and a model, then no URL, key or SSL configuration is
  required from the caller.
- Given such a run, when it completes, then `RLM.Trace` records the model
  identifier, so a run through AI Hub and a run through REST are distinguishable
  in the trace and comparable in the scorecard.
- Given the same scripted decisions, when a decomposition runs through the AI
  Hub provider and through `RLM.LLM.REST`, then the engine executes the same
  number of calls and produces the same document structure.

### US2 — A provider failure costs one slot, not the report (P1)

**Why this priority**: `RLM.LLM`'s contract says implementations must not
throw — return `""` and set the status. `%AI.*` signals failure by throwing
(`%AI.System.HandleError`). An unconverted exception would abort a run mid-report,
which is the one failure mode the budget and the honest-reporting path exist to
prevent.

**Independent Test**: a stub provider that throws on the second call; assert the
run finishes, the report discloses the failed slice, and the budget shows the
slot spent.

**Acceptance**:

- Given a provider that throws, when `Complete` is called, then it returns `""`
  and sets an error status naming the provider failure, and does not throw.
- Given a run where one call fails, when the report is written, then the failure
  is disclosed in the report's own terms rather than omitted.
- Given a response whose content is empty, when it is completed, then that is an
  error status rather than an empty answer treated as a decision.

### US3 — A truncated completion is refused, without a finish reason (P1)

**Why this priority**: Constitution III. `RLM.LLM.REST` refuses a completion
whose `finish_reason` is `length` because a self-truncated answer read as
complete is the documented RLM failure mode. `%AI.LLM.Response` exposes no
finish reason, so refusing truncation here needs a different mechanism — and
shipping without one would be a silent regression in the guarantee, on the
provider a user is most likely to reach for.

**Independent Test**: a stub provider returning a `Usage` whose completion token
count equals the requested `MaxTokens`; assert the call fails with a truncation
status rather than returning the partial text.

**Acceptance**:

- Given a `MaxTokens` limit and a response reporting that many completion
  tokens, when the call returns, then it is an error status naming truncation,
  not a returned answer.
- Given no `MaxTokens` set, when a response arrives, then the truncation check
  is not applied and does not produce a false refusal.
- Given a response with usage absent entirely, when the call returns, then it
  succeeds — an unreported usage block is not evidence of truncation.

### US4 — `rlm-core` still installs on an IRIS with no AI Hub (P1)

**Why this priority**: Constitution VI, and the failure it names — `zpm load`
aborting at compile time on a missing `%AI.Agent` — is the worst OEX first
impression this package could make. `rlm-core`'s manifest ships
`<Resource Name="RLM.PKG"/>`, which is recursive: a class named
`RLM.LLM.AIHub` would be **inside** `rlm-core` and would drag `%AI.*` into the
portable module. The package layout is therefore load-bearing, not cosmetic.

**Independent Test**: enumerate the source text of every class the `rlm-core`
manifest ships and assert no `%AI.` reference appears in any of them.

**Acceptance**:

- Given the `rlm-core` manifest, when its resources are expanded, then no class
  it ships references `%AI.`.
- Given the two manifests, when their resource sets are compared, then they are
  disjoint — no class ships in both.
- Given `rlm-aihub`'s manifest, when its dependencies are read, then it depends
  on `rlm-core`.

### US5 — Route the model call through the instance's policy (P2)

A compliance reviewer needs the model calls a decomposition makes to appear in
the same audit trail as everything else the instance's AI does, and to be
refusable by the same authorization policy.

**Why this priority**: it is the differentiator over `RLM.LLM.REST`, but it is
additive — US1 through US4 are a complete, shippable module without it.

**Independent Test**: an audit policy stub that records calls and an
authorization stub that refuses; assert calls are logged with no prompt content
beyond what the run already discloses, and that a refusal surfaces as a status
rather than an exception.

**Acceptance**:

- Given an audit policy attached, when a completion is made, then the policy
  receives the call with its duration and status.
- Given an authorization policy that refuses, when `Complete` is called, then it
  returns `""` with a status naming the refusal, and the run discloses it.
- Given a policy that itself throws, when `Complete` is called, then the throw is
  converted to a status like any other provider failure.

## Functional Requirements

- **FR1** `RLM.AIHub.LLM` extends `RLM.LLM` and implements `Complete` over
  `%AI.Provider.ChatComplete`.
- **FR2** It accepts a provider name and model, and optionally provider settings;
  it never requires a URL, bearer token or SSL configuration.
- **FR3** It converts every `%AI.*` exception into a `%Status`, and never throws
  out of `Complete`.
- **FR4** It refuses an empty completion, and refuses a completion whose reported
  completion-token usage indicates it was cut off at `MaxTokens`.
- **FR5** It exposes the provider-reported `Usage` token counts from the last
  call as readable state on the provider object. It does **not** write them into
  the trace's `tokensIn`/`tokensOut`: the engine fills those with
  `$Length(prompt)` and `$Length(out)`, which are character counts, and
  redefining them for one provider would make an AI Hub run and a REST run
  incomparable in exactly the scorecard that exists to compare them. Reconciling
  characters and tokens across all providers is a separate change to
  `RLM.Trace`, out of scope here.
- **FR6** It exposes readiness separately from construction, naming the reason
  when the provider is not usable.
- **FR7** All AI Hub classes live under a package root disjoint from `RLM.PKG`,
  so `rlm-core`'s recursive resource cannot ship them.
- **FR8** A second IPM manifest declares `rlm-aihub`, dependent on `rlm-core`.
- **FR9** No class shipped by `rlm-core` gains a `%AI.` reference — asserted by
  a test over source text, not by review.
- **FR10** Optional audit and authorization policies are consulted per call;
  absent policies change nothing.

## Non-Functional Requirements

- **NFR1** Every test in this milestone runs with no live model and no network:
  the provider seam is stubbed, per Constitution IV.
- **NFR2** The existing suite (300 tests) continues to pass unchanged, in the
  2026.1 community container that has no `%AI.*`.
- **NFR3** The AI Hub tests are skipped, not failed, on an instance without
  `%AI.*` — a portable container must stay green.

## Success Criteria

- **SC1** A decomposition runs end to end through the AI Hub provider against a
  stubbed `%AI.Provider`, producing a document with the same structure as the
  REST path.
- **SC2** `RLM.Engine`, `RLM.Policy.LLM`, `RLM.Replay` and `RLM.Eval.Scorecard`
  are unmodified by this milestone.
- **SC3** `rlm-core`'s shipped classes contain zero `%AI.` references, proven by
  a test.
- **SC4** The full suite passes in both containers: the 2026.1 community one
  (AI tests skipped) and this project's own AI container (AI tests run).

## Assumptions

- **A1** The stub seam is a subclass of `%AI.Provider` overriding
  `ChatComplete`. `%AI.Provider` is not abstract and its `ChatComplete` is a
  concrete `$ZF(-6)` callout, so overriding it in a test subclass avoids the
  callout without a live endpoint. To be verified in Phase 0.
- **A2** `Usage` keys follow the OpenAI shape
  (`prompt_tokens` / `completion_tokens` / `total_tokens`). To be verified in
  Phase 0; if the shape differs, FR4's truncation check reads whatever key the
  platform reports and the test pins the observed shape.
- **A3** Model-side truncation detection by token count is a proxy, not the
  finish reason itself. It can produce a false refusal when a completion legally
  ends at exactly the limit. Refusing in that case is the correct trade under
  Principle III: a false refusal is disclosed, a false acceptance is not.
- **A4** Parallel fan-out is **out of scope**. SPEC §6 records ai-hub-eap#26: on
  Build 126U a `%AI.Tool` spawning a child agent never returns when the parent's
  own loop dispatches it, and it leaks license slots. The delegating variant
  waits on that fix; M5 ships the provider and the policy seam.
- **A5** No live provider key is used at any point in this milestone.

## Out of Scope

- Engine-managed parallel fan-out (blocked on ai-hub-eap#26).
- `%AI.Agent` sessions, tool loops, skills and toolsets — the design is one
  bounded round-trip, so a session is not needed and a tool loop is forbidden.
- `%AI.RAG.*`, vector stores and embeddings: a peek is an aggregate, not a
  retrieval.
- Publishing either module to OpenExchange.
