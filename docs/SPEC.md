# rlm-iris — Recursive LM decomposition over live IRIS stores

**Working name:** `rlm-iris` · OpenExchange package, IPM-installable
**Status:** Draft v0.1
**Relationship to the AI Hub harness spec:** that document asks the AI Hub team
for core `%AI.*` additions (offloading store, LID renderer, scope-reduction,
parallel operators, trainability). This document specifies what we ship **now**,
on shipping IRIS, without waiting for any of it — and how each piece retires or
adapts when those additions land.

## 1. The claim

The model reasons about a store **it never receives a copy of**. Slice summaries
come back from the engine that owns the data, so the context the root LM sees is
bounded by the number of slices it inspects, not by the size of the store.

Every existing RLM implementation — `rlms`, `dspy.RLM`, the Google ADK port,
`recursive-llm` — begins by loading context into its own process as a Python
REPL variable. That is a fine design for a Markdown dump and an impossible one
for a 400M-row `Ens.MessageHeader` under an SLA, a PHI-bearing clinical table, or
an undocumented global with no schema at all. WordLift's RLM-on-KG is the only
prior art with a non-text environment (GraphQL over RDF), and it is still a
retrieval surface rather than the system of record.

Two consequences follow, and they are the package's reason to exist:

- **No extract step.** The interesting stores are exactly the ones you cannot
  export — too large, too live, too regulated. In-situ is not an optimization.
- **Governance has something to attach to.** A slice is a query against a table
  IRIS still controls, so access can be authorized and audited per slice. Once
  data is a REPL variable there is nothing left to authorize.

## 2. Non-goals for v1

- Not a trainer. No GPUs, no vLLM, no `verifiers` dependency.
- Not an offloading substrate for arbitrary text. Sources are structured stores.
- No arbitrary code execution by the model. See §5 — this is load-bearing, not
  timidity.
- No agent tool-loop. Every LLM call is one bounded round-trip.

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

RLM.Policy           abstract: ChooseSplit(peek, candidates) -> dim
  .Greedy            highest relative spread; no LLM
  .LLM               one bounded round-trip
  .Bandit            contextual bandit over candidates (v2)

RLM.LLM              abstract: Complete(instructions, prompt) -> text
  .REST              %Net.HttpRequest -> OpenAI-compatible endpoint
  .Python            $SYSTEM.Python + provider SDK
  .AIHub             %AI.Agent.Chat()
  .Null              deterministic stub

RLM.Engine           recursion; depends on RLM.Source + RLM.LLM + RLM.Policy only
```

`RLM.Engine` contains no reference to `%AI.*`. The only seam that ever needed to
be abstract is `RLM.LLM`, because every call in the design is a single
round-trip with all evidence pre-computed: no tool loop, no function calling, no
streaming. A plain HTTPS POST satisfies the contract completely.

### 3.1 Two IPM modules, not one with a flag

- **`rlm-core`** — everything above except `RLM.LLM.AIHub`. No `%AI.*`
  dependency. Target floor IRIS 2022.1 (**unverified below 2024.1** — `%Net.HttpRequest`
  TLS config and `%DynamicObject` behavior need testing on the older builds
  before the floor is published).
- **`rlm-aihub`** — depends on `rlm-core`; adds `RLM.LLM.AIHub`, policy hooks,
  and the delegating engine variant.

A single module cannot express "requires 2026.3" conditionally, and `zpm load`
failing at compile time on a missing `%AI.Agent` is the worst possible OEX first
impression. Portable is the **default**; AI Hub is the upgrade. If the polarity
were reversed the abstraction would rot — someone would reach for `%AI.Policy`
inside the engine within a month.

## 4. `RLM.Source` contract

Three methods. `Dimensions()` returns the whitelist of decomposition keys, each
with `token`, `label`, and a predicate/prefix. `Peek(key)` returns aggregate
statistics for that slice. `Describe(label, peek)` renders them as
self-labelling metric lines for the prompt.

Two invariants every source must hold:

**The model never authors a predicate.** `Peek()` enumerates children; the model
selects a token from that enumeration; `RLM.Slice.Resolve()` refuses anything not
returned by the previous peek. There is no injection surface to reason about,
because the model's action space is a legal-move list.

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
genuinely cannot fit in any context window. Its peek returns child count (capped),
depth reached, distinct subscripts at the next level with the top few by fanout,
data-node vs pointer-node ratio, value length mean/sd, subscript type mix
(canonical numeric / string / `$LB`-looking), and a value-shape sample —
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
defect in the Gaia prototype: sub-agent sub-peeks were recorded in the same trace
as root delegations, so a 6-slice plan emitted 8 lines and read as a budget
violation. Budget accounting is correct by construction with the discriminator
and requires a retrofit without it.

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

## 6. Compatibility with the coming AI Hub additions

Designed so each AI Hub addition **replaces an internal, not an interface**:

| AI Hub addition                | What we do now                           | On arrival                                                            |
| ------------------------------ | ---------------------------------------- | --------------------------------------------------------------------- |
| `%AI.Context.Store` offloading | Peeks already bounded; no offload needed | `RLM.Source` results become handles; engine unchanged                 |
| Tool-result `Offload` mode     | N/A — we never return raw rows           | Opt in for `Describe()` output                                        |
| LID observation renderer       | `Describe()` is already canonical        | Delegate to it, keep `Describe()` as fallback                         |
| Scope-reduction invariant      | Depth cap + budget in `RLM.Budget`       | Adopt in the `rlm-aihub` delegating variant                           |
| Parallel `%AI.Op.Map`          | Sequential recursion                     | Parallel fan-out in `rlm-aihub`. **Blocked on ai-hub-eap#26** (below) |
| Trainability / `%AI.Env`       | `RLM.Trace` + replay                     | Export adapter; trace format already sufficient                       |
| Core trajectory record         | `RLM.Trace`                              | Map onto it if it carries an extensible metric bag; else keep ours    |

**ai-hub-eap#26**: on 2026.3.0AI Build 126U a `%AI.Tool` that spawns a child
agent never returns when the parent's own loop dispatches it — and only when the
child has tools attached. It also leaks license slots. Any engine-managed
parallel fan-out in `rlm-aihub` waits on that fix; `rlm-core` is unaffected
because it recurses in ObjectScript.

The seam that makes all of this cheap is that `RLM.Engine` depends on three
abstractions and no framework. If AI Hub's primitives arrive in a different
shape than the harness spec proposes, the blast radius is `RLM.LLM.AIHub` and
`rlm-aihub` — not the engine, not the sources, not the trace.

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
- **M4 — `Interop` and `Audit` sources.**
- **M5 — `rlm-aihub`.** `RLM.LLM.AIHub`, policy hooks, delegating variant.

M0–M3 have no AI Hub dependency and no key beyond an OpenAI-compatible endpoint.

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
