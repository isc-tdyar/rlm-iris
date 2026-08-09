# Enhancement Request: recursive, arbitrary-width sub-agent fan-out in AI Hub

**To:** InterSystems AI Hub team
**From:** Thomas Dyar
**Date:** 2026-08-09
**Target:** `%AI.*` core, post-2026.3AI
**Related:** `ai-hub-eap#26` (blocking defect) · [`docs/SPEC.md` §6](SPEC.md) · `rlm-aihub` (`RLMAIHub.Provider`)

---

## 1. The ask, in three sentences

An `%AI.Agent` must be able to spawn child agents, each of which may spawn its
own children, to a caller-specified depth and with arbitrary fan-out width at
each level. The call must return the child's result to the parent, must work
when the child has tools attached, and must release its license slot on every
exit path. Today none of those three hold, and the first two fail together in a
way that hangs the parent process.

Everything else in this document is detail about why that shape specifically,
and what "correct" has to mean for it to be usable.

## 2. Why now

Recursive decomposition has become the dominant scaffold for long-context and
long-horizon agent work over the last year, and it is converging on one
structure that AI Hub cannot currently express.

The Recursive Language Model formulation (Zhang, Kraska and Khattab, MIT CSAIL,
[arXiv:2512.24601](https://arxiv.org/abs/2512.24601)) replaces a single
`llm.completion(prompt)` with an `rlm.completion(prompt)` that holds the context
in an environment and launches sub-calls against slices of it — recursively,
because a sub-call may itself need to decompose. Their reported result is
processing inputs up to two orders of magnitude beyond the model's context
window, and an RLM over a smaller model outperforming a larger one on the hardest
long-context split.

Prime Intellect's production implementations follow the same shape.
`rlm-harness` (the RL training harness driven by `verifiers`) exposes recursion
as a blocking call the model makes from inside its execution environment, bounded
by `RLM_MAX_DEPTH`. Prime Agent, their shipping product, uses the same primitive
with a fire-and-forget contract and a default depth of 1.

Two structural features recur in all three, and both are the subject of this
request:

- **Depth is a first-class, propagated quantity.** Every implementation passes
  the current depth down, enforces a ceiling, and tags outbound provider traffic
  with it so root calls can be distinguished from sub-agent calls.
- **Width is decided by the model at runtime, not by the harness in advance.**
  The academic formulation's budget guidance is explicitly about choosing batch
  shape per decision ("fat-prompt small batches are correct"), which only means
  anything if the caller can fan out to N children where N is not known when the
  parent started.

A platform that supports one level of fan-out with a fixed width supports none of
this. The requirement is not "parallel tool calls"; it is a tree.

A note on evidence, so this is not oversold. Prime Agent's published long-context
results are strong against harnesses that scaffold long context poorly (0.700 vs
0.420 on OOLONG@128k against GLM-5.2's own harness; 0.940 vs 0.500 against
Codex) and roughly even against a well-scaffolded one — it wins 6 of 9 evals
against Claude Code but *loses* OOLONG, 0.900 to 0.920. The honest claim is that
recursive scaffolding substantially lifts models whose native harness handles
long context poorly, not that it beats every agent. That is still a capability
IRIS customers cannot currently build at all, which is the point of the request.

## 3. What we do today, and why it is not enough

`rlm-core` recurses in ObjectScript and does not use `%AI.Agent` at all. Its
provider seam is `%AI.Provider.ChatComplete`, chosen precisely because it is
stateless and single-shot: `%AI.Agent` maintains a session and runs a tool loop
whose `MaxIterations` defaults to 10, which would break both budget accounting
(the engine charges one slot per decision while the provider spends up to ten,
making the budget line in every report fiction) and replay (an agent's trajectory
depends on tool results rather than only on the frozen store).

That decision was right for `rlm-core` and it is not a substitute for this
request. Recursing in ObjectScript means:

- The recursion is invisible to AI Hub. No trajectory record spans the tree, no
  policy applies per level, and `%AI.Env` cannot observe it when it lands.
- Fan-out is sequential. `docs/SPEC.md` §6 lists parallel `%AI.Op.Map` as the
  arrival that would fix this, and records it as **still blocked on
  `ai-hub-eap#26`**.
- Any customer who wants the RLM pattern *with* AI Hub's authorization and audit
  policies has to choose one or the other.

The workaround is available only because our engine happens to own its own
recursion. A customer building on `%AI.Agent` directly has no workaround at all.

## 4. The blocking defect

**`ai-hub-eap#26`**, recorded in `docs/SPEC.md` §6 and re-confirmed on
2026.3.0AI Build 126U during M5:

> A `%AI.Tool` that spawns a child agent never returns when the parent's own loop
> dispatches it — and only when the child has tools attached. It also leaks
> license slots.

Three things make this the specific blocker rather than one bug among several:

1. **The failure is a hang, not an error.** A parent that never returns cannot be
   retried, timed out by the caller, or diagnosed from a report. It consumes the
   process.
2. **The trigger is exactly the useful case.** A child with no tools is a
   completion, which `%AI.Provider.ChatComplete` already gives us. A child *with*
   tools is the case that motivates having agents at all — and it is the one that
   hangs.
3. **The license leak compounds it.** A hung parent holding leaked slots degrades
   the instance rather than just the run, so the failure is not contained to the
   caller who triggered it.

We have not tested builds after 126U. If this is already fixed, §4 collapses and
§5 is still the request.

## 5. Requested capability

Numbered so they can be accepted or rejected individually.

### Core

- **FR-1 — Recursion to arbitrary depth.** An agent spawned by an agent may
  itself spawn agents. Depth is bounded by a caller-supplied ceiling, not by the
  platform's structure.
- **FR-2 — Children may have tools.** A child with tools attached must behave
  identically to one without, other than being able to call them. This is the
  `ai-hub-eap#26` condition stated as a requirement.
- **FR-3 — The call returns.** A parent dispatching a child receives that child's
  result. Blocking semantics; the parent's own loop must not deadlock on a child
  it dispatched.
- **FR-4 — Arbitrary fan-out width.** A parent may spawn N children at one level,
  where N is determined at runtime, and they execute concurrently. `%AI.Op.Map`
  is the natural home for this if it is the operator that lands.

### Depth as a first-class quantity

- **FR-5 — Depth propagates automatically.** A child can read its own depth
  without the parent having to thread it through a prompt. Threading it by
  convention means any entry point that forgets is an unbounded recursion.
- **FR-6 — The ceiling is enforced by the platform.** Exceeding it fails fast
  with an error distinguishable from a model or provider failure, rather than
  recursing until something else breaks.
- **FR-7 — Graceful degradation at the ceiling is available.** The academic
  formulation degrades an RLM at maximum depth into a plain LM call rather than
  refusing, which keeps a deep branch answerable instead of empty. A platform
  flag selecting "refuse" or "degrade to completion" at the ceiling would let
  callers pick; refusing is the safe default.
- **FR-8 — Depth is visible on outbound provider traffic.** `rlm-harness` sets
  `X-RLM-Depth` on every request so a proxy can separate root calls from
  sub-agent calls. Without an equivalent, trajectories cannot be filtered by
  level, which is what makes recursive runs trainable and auditable.

### Accounting and lifecycle

- **FR-9 — License slots are released on every exit path**: completion, failure,
  cancellation, timeout, and ceiling refusal.
- **FR-10 — Budget aggregates across the subtree.** A parent must be able to
  learn total calls and tokens spent by everything below it. A per-agent counter
  that does not roll up makes cost unknowable for exactly the workload that
  spends the most.
- **FR-11 — Cancellation propagates down.** Cancelling a parent cancels its
  descendants and releases their slots.
- **FR-12 — A failed child does not fail the parent.** The parent receives the
  failure as a value it can report, decide on, or retry. One bad branch of a
  hundred-child fan-out must not lose the other ninety-nine.
- **FR-13 — A timeout per child, and a timeout for the subtree.** The academic
  implementation decrements both budget and timeout on the way down; without a
  subtree-level bound, N children each inside their own timeout can exceed any
  wall-clock the caller intended.

### Observability

- **FR-14 — One trajectory record spans the tree.** Each entry carries its depth
  and its parent, so the call graph is reconstructable. `rlm-harness` does this
  with nested session directories (`sessions/<id>/sub-<id>/...`); we do it with
  `^RLM.Trace`. Either shape is fine; the requirement is that the linkage exists
  and is not inferred from timestamps.
- **FR-15 — Partial results survive a subtree failure.** Whatever completed
  before a failure is readable, because a decomposition that discards its
  established findings on one bad branch is worse than one that reports them with
  the gap named.

## 6. Proposed surface

Illustrative, not prescriptive — the semantics above matter more than the
spelling.

```objectscript
// A child agent, dispatched by its parent, returning its result.
Set child = ##class(%AI.Agent).%New(agentName)
Set child.MaxDepth = 3                  // ceiling for this subtree
Set result = parent.Spawn(child, prompt, .sc)   // FR-3: returns
Write child.Depth                       // FR-5: parent's depth + 1

// Arbitrary-width concurrent fan-out (FR-4).
Set results = ##class(%AI.Op.Map).Run(parent, agents, prompts, .sc)

// Subtree accounting (FR-10).
Write parent.SubtreeUsage.Calls, parent.SubtreeUsage.Tokens
```

Two properties we would specifically ask not to be designed away:

- **`MaxIterations` must remain separable from depth.** A tool loop's iteration
  count and a recursion's depth are different budgets over different things, and
  a single knob covering both makes neither controllable.
- **Spawning should not require the child to be dispatched through a
  `%AI.Tool`.** The tool path is what `ai-hub-eap#26` fails on, and it is also
  the wrong level: recursion is a control-flow primitive, not a capability the
  model has to be persuaded to invoke. `rlm-harness` gets this right by injecting
  the recursive call directly into the execution environment rather than
  exposing it as a tool schema.

## 7. Acceptance criteria

Reproducible without our package:

- **AC-1** A three-level tree (root → child → grandchild), every node holding at
  least one tool, completes and returns the leaf's result to the root.
- **AC-2** A root fanning out to 50 concurrent children completes; wall-clock is
  materially below the sequential sum.
- **AC-3** After AC-1 and AC-2, the instance's license-slot count returns to its
  pre-run value. Repeating each 100 times shows no monotonic growth.
- **AC-4** A depth ceiling of 2 refuses the third level with a distinct error,
  and the run completes rather than hanging.
- **AC-5** One child of a 20-child fan-out throws; the parent receives 19 results
  and one failure, and reports.
- **AC-6** Cancelling the root during a fan-out returns within a bounded interval
  and releases every descendant's slot.
- **AC-7** The trajectory record for AC-1 reconstructs the tree — every entry
  resolves to its parent, and depth is present on each.
- **AC-8** Outbound provider requests from depth 0 are distinguishable from those
  at depth ≥ 1 without inspecting prompt content.

## 8. What we would retire on arrival

`docs/SPEC.md` §6 is written so each AI Hub addition replaces an internal rather
than an interface. On this one:

| Ours today | On arrival |
| --- | --- |
| Sequential recursion in `RLM.Engine` | Parallel fan-out in `rlm-aihub`; `rlm-core` keeps its own for portability |
| `RLM.Budget` per-run accounting | Adopt subtree accounting; keep ours as the portable path |
| `RLM.Trace` + `^RLM.State` | Map onto the core trajectory record if it carries an extensible metric bag |
| `RLM.Slice` depth cap | Keep — it bounds a *name grammar*, not a call tree, and the two ceilings are unrelated |

`rlm-core` would continue to recurse in ObjectScript regardless, because it must
install on base IRIS with no `%AI.*` dependency. This request is about what
`rlm-aihub` and, more importantly, customers building directly on `%AI.Agent` can
express.

## 9. Priority and impact

**Blocking** for any recursive agent workload on AI Hub. Not a performance
improvement — the pattern cannot be built at one level of nesting, and the one
level that exists hangs when the child has tools.

The customers this reaches are the ones with data that cannot leave: a 400M-row
`Ens.MessageHeader` under an SLA, a PHI-bearing clinical extent, an undocumented
global with no schema. Recursive decomposition is currently the best-published
method for reasoning over exactly that, and AI Hub is the only way to do it with
the instance's authorization and audit policies attached. Today those two
requirements are mutually exclusive.

## 10. Open questions for the AI Hub team

1. Is `ai-hub-eap#26` fixed after Build 126U? Everything in §4 is measured on
   126U and not since.
2. Is `%AI.Op.Map` intended to support nested maps — a child that itself maps —
   or only a single level of fan-out?
3. Does the planned core trajectory record carry a depth or parent dimension? If
   not, is an extensible metric bag available so callers can add one?
4. How are license slots accounted for concurrent children — per agent instance,
   per session, or per process? AC-3 is written against instance count because we
   do not know.
5. Is there an intended interaction between recursion depth and
   `%AI.Context.Store` offloading? A child receiving a handle rather than a copy
   is the natural composition, and would make deep trees far cheaper.
