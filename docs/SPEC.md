# rlm-iris — Recursive LM decomposition over live IRIS stores

**Working name:** `rlm-iris` · OpenExchange package, IPM-installable
**Status:** Draft v0.1
**Relationship to AI Hub:** this document specifies what we ship **now**, on
shipping IRIS, depending on nothing that is not already released. §6 separates
what AI Hub verifiably provides today from additions we would like it to grow,
and every "today" column there is shipped, tested behaviour — so nothing here
waits on anything there.

## 1. The claim

The model reasons about a store **it never receives a copy of**. Slice summaries
come back from the engine that owns the data, so the context the root LM sees is
bounded by the number of slices it inspects, not by the size of the store.

Every existing RLM implementation — `rlms`, `dspy.RLM`, the Google ADK port,
`recursive-llm` — begins by loading context into its own process as a Python
REPL variable. That is a fine design for a Markdown dump and an impossible one
for a 400M-row `Ens.MessageHeader` under an SLA, a PHI-bearing clinical table,
or an undocumented global with no schema at all. WordLift's RLM-on-KG is the
only prior art with a non-text environment (GraphQL over RDF), and it is still a
retrieval surface rather than the system of record.

Two consequences follow, and they are the package's reason to exist:

- **No extract step.** The interesting stores are exactly the ones you cannot
  export — too large, too live, too regulated. In-situ is not an optimization.
- **Governance has something to attach to.** A slice is a query against a table
  IRIS still controls, so access can be authorized and audited per slice. Once
  data is a REPL variable there is nothing left to authorize.

### 1.1 The second claim: this is a trainable harness

The first claim is about context. This one is about what the design buys after
the run finishes, and it is the reason the constitutions in §5 are worth their
cost.

Because the model never authors code, **a peek is a pure function of the store**.
Three things follow that no REPL-based RLM can have:

- **Replay is free.** A trace plus the store reproduces a run exactly, with zero
  model calls (`RLM.Replay`).
- **Counterfactuals are free.** Every dimension the run did *not* choose can be
  scored after the fact, at every decision point, again with zero model calls
  (`RLM.Eval.Arms`). That is a reward signal over the whole action set, not just
  the arm that was taken.
- **The objective is computable offline** (`RLM.Eval.Scorecard`).

Put in reinforcement-learning terms, the pieces already map:

| Piece | Role |
| --- | --- |
| `RLM.Trace` | Trajectory — role, depth, slice, metric, tokens, model, text sidecars |
| `RLM.Policy` | The policy seam; the thing that would be trained |
| `RLM.Eval.Arms` | Per-decision reward over every candidate action |
| `RLM.Eval.Scorecard` | Episode return |
| `RLM.Replay` | Deterministic re-evaluation |
| `RLM.State` | Durable per-slice findings |

The contrast is the point. Prime Intellect's `rlm-harness` and Prime Agent both
put the model in a REPL, so their trajectories depend on code the model wrote and
cannot be re-scored without re-running against a live model — which is why
`verifiers` has no offline path and `prime-rl` requires the live policy's own
sampling logprobs. Here, a finished run is a *dataset*: imitation learning and
offline policy comparison are possible where those systems need online rollouts.

So the whole programme reduces to two halves:

> An agent platform is a **trainable harness** when it can (a) run the recursive
> pattern — depth-bounded sub-agents with runtime-decided fan-out — and (b) emit
> a depth-tagged trajectory whose reward is computable offline.
>
> `rlm-core` already does (b). [ER-AIHUB-RECURSIVE-SUBAGENTS.md](ER-AIHUB-RECURSIVE-SUBAGENTS.md)
> asks AI Hub for (a).

What is missing on our side is only an export adapter onto whichever trainer is
in use; the trace format already carries what one needs. What is missing on AI
Hub's side is bounded recursion, and the depth tag that makes a recursive
trajectory separable by level.

## 2. Non-goals for v1

- Not a trainer. No GPUs, no vLLM, no `verifiers` dependency.
- Not an offloading substrate for arbitrary text. Sources are structured stores.
- No arbitrary code execution by the model. See §5 and §5.1 — this is
  load-bearing, not timidity, and §5.1 says precisely which guarantee it
  protects.
- No agent tool-loop. Every LLM call is one bounded round-trip.

**Amended at M6.** The second item was written as though "structured store"
implied "aggregates only", and the source contract encoded that as a prohibition
on returning rows. That conflated two different things. The bound this design
actually needs is that a **view is capped by a constant**, so context grows with
slices inspected rather than with store size; whether the view holds statistics
or records was never what made the bound hold.

Aggregates are what you compute when a slice is too large to read — the
pathological case rather than the design centre. Most questions worth asking are
judgements over records, and the decomposition is precisely what makes reading
them affordable: a slice that starts at 400M rows is, some levels down, small
enough. `RLM.Lens` is the seam that lets a run say which of the two it wants,
with `RLM.Lens.Stats` the default so a governed store keeps the original
guarantee by doing nothing. See [specs/008](../specs/008-lenses-and-state/spec.md).

The other three non-goals are unchanged and remain load-bearing.

## 3. Architecture

```text
RLM.Source           abstract: Dimensions() / Peek(key) / Describe(label, peek)
  .Global            $ORDER walk; visit cap; name allowlist
  .Table             live aggregates via %SQL.Statement
  .Interop           Ens.MessageHeader + body classes
  .Audit             %SYS.Audit

RLM.Slice            fail-closed `dim:token[/dim:token]` grammar over any Source
RLM.Budget           call accounting, reserved synthesis slot
RLM.Trace            structured trajectory record
RLM.Report           UTF-8 report writer, indent
RLM.State            per-slice findings; ^RLM.State or process-private

RLM.Lens             abstract: View(source, label, peek, predicate) -> what the
                     model is shown at a leaf   (the observation space)
  .Stats             Source.Describe, aggregates only; the default
  .Contents          the records themselves, capped, once the slice fits

RLM.Grammar          abstract: what the model may *do*  (the action space, v2)
  .Enumerated        dim:token over Source.Dimensions, via RLM.Slice; the default
  .Query             structured, validated predicate composition; keeps replay,
                     gives up free counterfactuals -- see specs/009

RLM.Policy           abstract: ChooseSplit(peek, candidates) -> dim
  .Greedy            highest relative spread; no LLM
  .LLM               one bounded round-trip
  .Bandit            contextual bandit over candidates (v2)

RLM.LLM              abstract: Complete(instructions, prompt) -> text
  .REST              %Net.HttpRequest -> OpenAI-compatible endpoint
  .Python            $SYSTEM.Python + provider SDK
  .Null              deterministic stub
RLMAIHub.Provider    %AI.Provider.ChatComplete()  (separate package, rlm-aihub)

RLM.Engine           recursion; depends on RLM.Source + RLM.LLM + RLM.Policy only
```

`RLM.Engine` contains no reference to `%AI.*`. The only seam that ever needed to
be abstract is `RLM.LLM`, because every call in the design is a single
round-trip with all evidence pre-computed: no tool loop, no function calling, no
streaming. A plain HTTPS POST satisfies the contract completely.

**The AI Hub provider is `%AI.Provider.ChatComplete`, not `%AI.Agent.Chat`.** An
earlier draft of this spec named `RLM.LLM.AIHub` over `%AI.Agent.Chat()`; that
was wrong on both counts. `%AI.Agent` maintains a session and runs a tool loop
whose `MaxIterations` defaults to 10, so building on it would break the two
things the design most depends on. Budget accounting: the engine charges one
slot per decision while the provider spends up to ten, and the budget line in
every report becomes fiction. Replay: an agent's trajectory depends on tool
results rather than only on the frozen store, so a trace plus the store would no
longer be everything a run was. `ChatComplete` is stateless and single-shot,
which is the `RLM.LLM` contract exactly. `UnitTest.RLMAIHub.EndToEndAIHub` pins
both by asserting an AI Hub run's document is byte-identical to the same run
through `RLM.LLM.Null` and its call count exactly equal.

The class also sits in its own `RLMAIHub` package rather than under `RLM.LLM`,
because IPM's `<Resource Name="RLM.PKG"/>` is recursive: a subpackage of `RLM`
would drag `%AI.*` into `rlm-core`'s own manifest.

### 3.1 Two IPM modules, not one with a flag

- **`rlm-core`** (`module.xml`) — the whole engine, sources, policies, trace
  and replay. No `%AI.*` dependency. Target floor IRIS 2022.1 (**unverified
  below 2024.1** — `%Net.HttpRequest` TLS config and `%DynamicObject` behavior
  need testing on the older builds before the floor is published).
- **`rlm-aihub`** (`module-aihub.xml`) — depends on `rlm-core`; adds the
  `RLMAIHub` package, which is `RLMAIHub.Provider` and nothing else. Requires
  2026.3AI.

The dependency runs one way and is asserted rather than assumed:
`UnitTest.RLMAIHub.Manifests` reads both manifests and checks that `rlm-core`'s
resources do not overlap `rlm-aihub`'s and that `rlm-core` never names it. Both
checks strip comments first — an explanatory XML comment in `module.xml` that
mentions `rlm-aihub` failed the test once, and a comment cannot drag a module
anywhere, only a `<Dependency>` or a `<Resource>` can.

A single module cannot express "requires 2026.3" conditionally, and `zpm load`
failing at compile time on a missing `%AI.Provider` is the worst possible OEX
first impression. Portable is the **default**; AI Hub is the upgrade. If the
polarity were reversed the abstraction would rot — someone would reach for
`%AI.Policy` inside the engine within a month.

One `src/` tree still serves both containers.
`$System.OBJ.LoadDir(..., "ck", , 1)` skips a class whose superclass is missing
and continues, so on base IRIS it reports `Skipping class RLMAIHub.Provider` and
the other 306 tests compile and run green.

## 4. `RLM.Source` contract

Three methods. `Dimensions()` returns the whitelist of decomposition keys, each
with `token`, `label`, and a predicate/prefix. `Peek(key)` returns aggregate
statistics for that slice. `Describe(label, peek)` renders them as
self-labelling metric lines for the prompt.

Two invariants every source must hold:

**The model never authors a predicate.** `Peek()` enumerates children; the model
selects a token from that enumeration; `RLM.Slice.Resolve()` refuses anything
not returned by the previous peek. There is no injection surface to reason
about, because the model's action space is a legal-move list.

**Caps are reported, never hidden.** A bounded walk that returns
`"counted 50,000 nodes (capped); subtree is larger"` is useful; one that returns
`50000` is actively harmful, because the model treats it as a total and every
downstream claim inherits the error. This is the failure mode documented in the
Towards Data Science RLM walkthrough, where the model silently truncated each
article to its first 15K characters and reported nothing.

### 4.1 Sources, ranked by what is only possible in IRIS

| #   | Source    | Why it cannot be done elsewhere                            |
| --- | --------- | ---------------------------------------------------------- |
| 1   | `Global`  | No schema exists; no external engine can enter             |
| 2   | `Interop` | Live production message flow; cannot be exported           |
| 3   | `Table`   | Index-answered aggregates on data under an SLA; no extract |
| 4   | `Audit`   | Governance is the point; exporting defeats it              |

`Global` ships first: strongest differentiator, no prior art, and the store
genuinely cannot fit in any context window. Its peek returns child count
(capped), depth reached, distinct subscripts at the next level with the top few
by fanout, data-node vs pointer-node ratio, value length mean/sd, subscript type
mix (canonical numeric / string / `$LB`-looking), and a value-shape sample —
roughly 500 characters whether the subtree holds 40 nodes or 400 million.

Global access is **read-only against a fail-closed allowlist**: `^$GLOBAL`
filtered against configured patterns, with `^%*`, `^ISC*`, `^rMAP`, `^ROUTINE`,
`^oddDEF` and cross-namespace refused by default. No supported path writes.

### 4.2 Per-source metrics, not fixed columns

`spread` presumes a numeric SQL aggregate and has no meaning for a subscript
walk, where the analogous signal is fanout entropy or child-count skew. Each
source therefore declares its own **split metric** (a normalized 0–1 scalar the
policy compares across candidates) plus an open metric bag carried in the trace.
`RLM.Policy.Greedy` needs only the scalar, so it works over any source without
knowing what the store is.

## 5. `RLM.Trace` and offline evaluation

```objectscript
^RLM.Trace(runId, seq) = $LB(role, depth, sourceClass, sliceKey,
                             splitMetricBefore, splitMetricAfter,
                             chosenDim, candidateDims, capped,
                             tokensIn, tokensOut, latencyMs, policy, model)
^RLM.Trace(runId, seq, "m", name) = value      ; per-source metric bag
```

`role` (`root_decision` / `subagent_peek` / `reduce`) exists because of a real
defect in the Gaia prototype: sub-agent sub-peeks were recorded in the same
trace as root delegations, so a 6-slice plan emitted 8 lines and read as a
budget violation. Budget accounting is correct by construction with the
discriminator and requires a retrofit without it.

**A peek is a pure function of the store.** Given a frozen store, a slice key
resolves to the same aggregates every time — so trajectories replay with no
model call, and with a small candidate set every alternative arm at every
recorded step can be enumerated. That yields, with zero training:

- **Does the LLM beat Greedy?** The open empirical question. If it does not on a
  workload, ship Greedy: cheaper, deterministic, no key required.
- **Fitted budgets.** Split thresholds and call caps are guesses today; measure
  marginal metric reduction per call and set them from data.
- **Provider drift detection.** A vendor silently swaps the model behind an
  alias and decomposition quality shifts; the replayed choice distribution flags
  it.
- **Deterministic CI.** `RLM.LLM.Null` plus replay tests decomposition
  _quality_, not just mechanics. No comparable library has this, because all of
  them need a live model to test at all.

This is why the package forbids model-authored code (§2). Arbitrary
`execute_python` would make replay non-deterministic and forfeit everything
above. The constraint buys the evaluation story.

### 5.1 What the constraint actually bundles

Worth separating, because the rule above is one sentence covering two independent
guarantees, and they come apart cleanly:

- **Determinism → replay.** A resolved move must be a reproducible function of
  stored state. Note what this does *not* require: model-authored SQL is still a
  pure function of the store, so replay survives it. The word doing the work in
  "arbitrary `execute_python`" is **arbitrary** — side effects and
  non-determinism break replay, not authorship.
- **Enumerable moves → counterfactuals.** `Eval.Arms` works because at each
  decision there is a *finite* set of dimensions not taken, each re-scorable with
  one peek. A composed query has no set of arms not taken.

So a wider action space can keep replay while losing free counterfactuals. That
is a real trade rather than a cliff, and today nothing in the package can express
it: `Arms` and `Replay` both assume the enumerated space silently, and a
`Scorecard` will compare two runs without recording what either was permitted to
do. [specs/009](../specs/009-action-space/spec.md) makes the action space a seam
that declares which of the two properties it preserves, so an evaluator refuses
what it cannot honestly compute instead of returning a number that looks like the
old one and means something else.

Mode 4 — arbitrary code — stays out, and 009 says so explicitly rather than by
omission: it forfeits determinism, and therefore replay, which is the property
that distinguishes this package from every other RLM implementation.

## 6. Relationship to the AI Hub surface

Rows are grouped by **what we know about each item**, because an earlier version
of this section mixed three different kinds of claim into one table and read as
though all of them were scheduled.

Provenance, stated once: §6.2 is **our own wish list**. Those capabilities are
things we think AI Hub should grow; none of them is an InterSystems commitment,
none appears in the shipped distribution, and no code in this package imports or
depends on any of them.

### 6.1 Present and verified

Read from `ai-core` @ `994c8f1` (2026-08-07) and recorded in
[AIHUB-SURVEY.md](AIHUB-SURVEY.md). `UnitTest.RLMAIHub.AgentProbe` re-checks any
live instance.

| Capability | Ours | Relationship |
| --- | --- | --- |
| `%AI.Provider.ChatComplete` | `RLMAIHub.Provider` | Already built on it |
| `%AI.Agent.SubAgent` / `CreateSubAgent` | Sequential recursion in `RLM.Engine` | Candidate for `rlm-aihub`; see the ER |
| Tool-access policies, inherited by children | Slice-level authorization argument | Stronger than assumed; adopt in `rlm-aihub` |
| `<Query>` envelope with `truncated` | `capped` on a peek, `truncated` on a materialize | Same invariant, independently derived |
| `AutoCompactOnTokenLimit` | Budget + reserved synthesis slot | Different mechanism, same concern |
| `%AI.RAG.VectorStore.IRIS` | — | Candidate `RLM.Source`; not yet explored |
| `%AI.MCP.Service` + `iris-mcp-server` | — | Could publish a Source as MCP tools |
| **Trainability** (§1.1) | `RLM.Trace` + `Replay` + `Eval.Arms` + `Scorecard` | **Already satisfied.** Needs an export adapter onto a trainer, which is ours to write — not an AI Hub dependency |

### 6.2 Requested by us, not observed anywhere

Named by **what they do** rather than by a class name: any names we once
proposed were ours, and none of them appears in the distribution.

| Capability we asked for | What we do instead, today | If it ever lands |
| --- | --- | --- |
| Context offloading / handles | Peeks are already bounded; no offload needed | `RLM.Source` results become handles; engine unchanged |
| Tool-result offload mode | N/A — we never return raw rows | Opt in for `Describe()` output |
| LID observation renderer | `Describe()` is already canonical | Delegate to it, keep `Describe()` as fallback |
| Scope-reduction invariant | Depth cap + budget in `RLM.Budget` | Adopt in the `rlm-aihub` delegating variant |
| Parallel map / fan-out operator | Sequential recursion | Parallel fan-out in `rlm-aihub` |
| Core trajectory record | `RLM.Trace` | Map onto it if it carries an extensible metric bag; else keep ours |
| Depth on the trajectory and on outbound requests | Not applicable — recursion is ours | Drop our own depth column and read theirs |

Every "today" column is a shipped, tested behaviour. That is the point of the
grouping: **nothing in this package waits on anything in §6.2.** If none of it
ever arrives, `rlm-core` is unaffected and `rlm-aihub` loses only optimizations.

### 6.3 Open and unverified

- Whether `ai-hub-eap#26` still reproduces (below).
- Whether the §6.2 capabilities exist under names we do not know. The probe's
  `Interesting()` list includes our proposed names precisely so a run reports
  their absence as data rather than leaving it assumed.

**ai-hub-eap#26**: on 2026.3.0AI Build 126U a `%AI.Tool` that spawns a child
agent never returns when the parent's own loop dispatches it — and only when the
child has tools attached. It also leaks license slots. Any engine-managed
parallel fan-out in `rlm-aihub` waits on that fix; `rlm-core` is unaffected
because it recurses in ObjectScript. Re-confirmed on Build 126U while building
M5. Written up as an enhancement request with acceptance criteria in
[ER-AIHUB-RECURSIVE-SUBAGENTS.md](ER-AIHUB-RECURSIVE-SUBAGENTS.md), which asks
for the general capability — recursion to arbitrary depth with runtime-decided
fan-out width — rather than only the defect fix.

**`%AI.LLM.Response` carries no finish reason.** `FromJSON` reads `content`, `usage`
and `tool_calls` and nothing else, so `RLM.LLM.REST`'s refusal of a completion
whose `finish_reason` is `length` has no direct equivalent. `RLMAIHub.Provider`
infers truncation from the reported `completion_tokens` reaching the requested
`MaxTokens`. The proxy over-refuses — a completion that legally ends on the
limit is rejected — and that is the correct direction under Principle III: a
false refusal is disclosed in the report and costs one slot, while a false
acceptance puts half a sentence into a report as a finding. Both figures must be
known: no `MaxTokens` means no check, and a provider that reports no usage is
not thereby evidence of truncation. A finish reason on `%AI.LLM.Response` would
let the proxy be deleted.

Two other measured facts about the surface, both of which shaped the class.
`%AI.Provider.Create("openai", {"api_key": "sk-not-a-real-key"})` succeeds and
`GetCapabilities()` returns the full list, so construction proves nothing about
readiness — which is why `Ready()` is a separate question. And
`GetCapabilities()` on an unresolvable provider throws
`<%AICore>ProviderNotFound` while `HasCapability()` returns a plain 0, so
`Ready()` reads the capability list inside a `Try` rather than calling
`HasCapability`: a bare false conflates "this provider cannot chat" with "nobody
could tell me".

The seam that makes all of this cheap is that `RLM.Engine` depends on three
abstractions and no framework. If AI Hub's primitives arrive in a different
shape than §6.2 proposes, the blast radius is `RLMAIHub.Provider` —
not the engine, not the sources, not the trace.

## 7. Milestones

- **M0 — engine + `RLM.LLM.REST` + `Table` source.** Port the Gaia
  implementation onto the abstractions: inject `Dimensions()` into `RLM.Slice`
  rather than hard-calling it, move `WriteReport()` off the delegating class onto
  `RLM.Report`, parameterize the sub-agent class. Tests prove byte-identical
  output on the existing Gaia decomposition.
- **M1 — `RLM.Trace` + `RLM.Policy` contract + Greedy.** Every run emits a
  replayable record; LLM and Greedy are comparable.
- **M2 — `Global` source. Shipped.** Bounded recursive `$ORDER` walk, visit and
  depth caps reported as floors, fail-closed allowlist with a non-overridable
  deny set, hex slice keys, fanout-entropy split metric, and subscript shape
  (type mix, value-length moments, top fanout) without subscript content. 63
  LLM-free tests over a synthetic `^||` global; the peek of a 25x larger store
  serializes to within 3% of the small one. `$QUERY` was rejected for the walk:
  it visits only nodes holding a value, so a global with pointer interiors
  reports a node count far below its real one.
- **M3 — replay + offline evaluation + `RLM.LLM.Null` CI. Shipped.** A finished
  run replays byte for byte with zero model calls: `RLM.Replay` drives the real
  engine through `RLM.LLM.Recorded` and `RLM.Policy.Recorded`, so a replay
  traverses the same code as the run it reproduces rather than a second
  implementation of the traversal. The trace gained a version subscript, the
  question, the config, and each call's text — additively, so a v1 trace still
  reads. A replay refuses when the store has moved, compared through a
  peek-derived fingerprint that contains no store contents; a mutation no peek
  can see does not refuse, which is the honest limit and is asserted as one.
  `RLM.Eval.Arms` enumerates the dimensions a run did not take and scores them
  from the recorded candidates, at no model cost. `RLM.Eval.Scorecard` runs
  several policies over one store and reports cost and objective in separate
  columns, never combined into a ranking. On the separating fixture the LLM
  policy chooses the same dimension as Greedy and pays one extra call for it
  (objective 0.100 both, against 0.540 for a deliberately bad control) — a tie,
  published as one. 265 LLM-free tests.
- **M4 — `Interop` and `Audit` sources. Shipped.** Two real IRIS stores, on a
  shared abstract `RLM.Source.Extent` that turns a dimension declaration into
  SQL: one encoder, one decoder, values bound rather than spliced, and a
  bounded top-k distribution so a slice with ten thousand distinct groups costs
  the same peek as one with three. `RLM.Source.Interop` divides
  `Ens.MessageHeader` by sending config, receiving config, status and hour of
  day; its metric is how mixed the slice's source-target routing is. Hour is
  derived rather than enumerated, so a store spanning a week offers the same 24
  children as one spanning an hour — the fanout is a property of the dimension,
  not of how long the production has been running. `RLM.Source.Audit` divides
  `%SYS.Audit` by facility, event type, user and namespace, and never reads
  `EventData`, `Description` or `UserInfo`: the columns that carry content are
  not selected, so there is nothing to filter out later. Both refuse in the
  store's own terms — a namespace without interop is not a store with no rows,
  and a log that is empty because auditing is off is not a log that is empty
  because nothing happened. Child counts plus the disclosed `NullCount` equal
  the parent with `=` and no tolerance, including rows whose timestamp is null.
  `RLM.Source.Table` was deliberately not re-parented onto the shared base: it
  is shipped and its output is asserted byte for byte by the Gaia port tests,
  and the duplication is the price. 300 LLM-free tests.
- **M5 — `rlm-aihub`. Shipped.** `RLMAIHub.Provider` over
  `%AI.Provider.ChatComplete`, a second IPM manifest, and the instance's
  authorization and audit policies wired in as optional seams. A run needs a
  provider name and a model; no URL, no key, no SSL configuration, asserted by
  reading the class source for the absent properties. The gate was to run the
  _existing_ suite on a second IRIS build, and it earned its keep: it surfaced
  two latent `rlm-core` defects that reproduced on both images. A derived
  dimension's fixed menu — `hour` offers 24 buckets whether or not any row
  landed in them — divided by zero in `RLM.Policy.Greedy` over a small extent
  and cost the whole run, disclosing only `<DIVIDE>`; the candidate is now
  excluded with a reason rather than scored 0, since 0 is the best possible
  metric and would make the emptiest dimension win every time. And
  `RLM.Replay.RecordedSourceClass` walked off the end of the rows onto a
  metadata node and read `PeekTotal` as a class name, refusing replays of traces
  that never named one. 341 LLM-free tests: 306 in `RLM` on both containers, 35
  in `RLMAIHub`.

  `UnitTest.RLM.Portability` was added with it, because the milestone introduced
  a real `%AI.*` dependency into the repository for the first time and the only
  thing keeping it out of `rlm-core` was a package boundary nobody is forced to
  respect. It walks every compiled `RLM.*` class and asserts no `%AI.*` in a
  method body, a property type, a superclass or a signature. The property case is
  the one that would arrive silently: `Property X As %AI.Policy.Audit` puts no
  text in any method, compiles to `ERROR #5373` on a customer's 2026.1, and takes
  the whole class with it.

  Not delivered: the delegating engine variant and parallel fan-out, both still
  blocked on ai-hub-eap#26, and truncation remains a token-count proxy rather
  than a finish reason.

M0–M4 have no AI Hub dependency and no key beyond an OpenAI-compatible endpoint.

## 8. Open questions

- **`rlm-core` version floor.** Assumed 2022.1; untested below 2024.1.
- **Does the LLM beat Greedy?** Answered on one fixture in M3: it does not — same
  dimension, one more call. Open on real stores, which is what the offline
  harness now makes cheap to ask.
- **Metric comparability across sources.** A normalized 0–1 split metric lets
  `Greedy` work source-agnostically, but whether fanout entropy and relative
  aggregate spread are _comparably_ scaled is an assumption to test.
- **Global walk cost on real stores.** `%SYS.GlobalQuery`/`%Library.GlobalEdit`
  may give cheap block-level size estimates that beat a capped walk for the
  count; signatures need verifying before the peek relies on them.
- **Live vs frozen.** Offline evaluation needs a frozen store; production runs
  against mutating data. How representative is frozen-store evaluation?
