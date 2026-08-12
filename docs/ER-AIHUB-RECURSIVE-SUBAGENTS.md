# Enhancement Request: recursive, arbitrary-width sub-agent fan-out in AI Hub

**To:** InterSystems AI Hub team
**From:** Thomas Dyar
**Date:** 2026-08-09 · **Revised** 2026-08-12 against the `ai-core` sample tree
**Target:** `%AI.*` core, post-2026.3AI
**Related:** `ai-hub-eap#26` · [`docs/SPEC.md` §6](SPEC.md) · `rlm-aihub`
**Evidence:** `ai-core` @ `994c8f1` — `Sample.AI.Examples.NestedAgents`,
`Sample.AI.Tools.DelegateTask`, `python/rlm/toolset.py`, `tests/test_rlm_child_agent.py`

---

## 1. The ask, in three sentences

AI Hub already has recursive sub-agents, and the two language bindings do not
agree about them: the Python path gives a child the parent's toolset and
therefore recurses genuinely, while every ObjectScript sample creates children
with no tools at all and therefore cannot recurse past one level. The ask is
parity — an ObjectScript child must be able to hold tools, including the tool
that spawns another child — plus depth as a platform-enforced quantity rather
than a convention each caller reimplements.

The original draft of this document asked for recursion as though it did not
exist. That was wrong, and the corrected ask is narrower and more actionable.

## 2. Why this matters

Recursive decomposition is now the dominant scaffold for long-context and
long-horizon agent work. The Recursive Language Model formulation (Zhang, Kraska
and Khattab, MIT CSAIL, [arXiv:2512.24601](https://arxiv.org/abs/2512.24601))
replaces `llm.completion(prompt)` with an `rlm.completion(prompt)` that holds
context in an environment and launches sub-calls against slices of it —
recursively, because a sub-call may itself need to decompose. Prime Intellect's
`rlm-harness` and Prime Agent both ship the same primitive, bounded by
`RLM_MAX_DEPTH`.

AI Hub's own `python/rlm/` example is an implementation of exactly this pattern,
so the platform has already accepted the premise. This request is about the half
of it that does not work yet.

A note on evidence so this is not oversold: Prime Agent's published long-context
results are strong against harnesses that scaffold long context poorly (0.700 vs
0.420 on OOLONG@128k against GLM-5.2's own harness) and roughly even against a
well-scaffolded one — it wins 6 of 9 evals against Claude Code but *loses*
OOLONG, 0.900 to 0.920. Recursive scaffolding substantially lifts models whose
native harness handles long context badly; it does not beat every agent.

## 3. What already exists

Read from the `ai-core` sample tree. This section supersedes the original §3.

**`%AI.Agent.SubAgent` — the ObjectScript nesting API.**

```objectscript
Set subagent = ##class(%AI.Agent.SubAgent).Create(..ParentAgent, systemPrompt, "")
Set session  = subagent.CreateSession()
Set response = subagent.Run(session, task)
```

`Sample.AI.Tools.DelegateTask` is a `%AI.Tool` that does this from inside a
parent's tool loop — the exact configuration `ai-hub-eap#26` describes — and its
comment says the call *"will use `safe_block_on` internally to handle nested
runtime contexts."* So the re-entry problem is known and addressed.

**`Agent.create_child_agent(model, provider)` — the Python equivalent, Build 121+.**
`python/rlm/README.md` is explicit:

> `RLMToolSet` holds a `parent_agent` reference. When spawning a sub-agent, it
> calls `parent_agent.create_child_agent(model, provider)` which shares the
> parent's tokio runtime instead of creating a new one. This eliminates the
> re-entry panic without any thread pool workarounds.

with a troubleshooting row mapping `cannot call block_on inside a runtime` to
"Pre-Build 121 tokio re-entry panic → upgrade to Build 121+", and
`tests/test_rlm_child_agent.py` validating it at unit, integration and E2E levels.

**Depth already exists in Python, including graceful degradation.**
`python/rlm/toolset.py` carries `current_depth` / `max_depth` and, at the
ceiling, returns truncated content rather than refusing:

```python
if self.current_depth >= self.max_depth:
    return f"[Max depth reached. First 1000 chars:]\n{context[:1000]}..."
```

That is FR-7 of the original draft, already implemented — on one binding.

## 4. The gap: the two bindings disagree

**Python gives a child the toolset.** `python/rlm/toolset.py:533`:

```python
sub_agent = self._create_agent()          # create_child_agent: shares parent runtime
sub_agent.add_tool_set(toolset)           # child holds spawn_subagent too
sub_agent.set_system_prompt(system_prompt)
return sub_agent.run(task)
```

The child therefore holds `spawn_subagent` and can recurse. Genuine depth.

**ObjectScript gives a child nothing.** Every `AddTool` in the sample tree is on
a root agent — `parentAgent`, `level1Agent`, `coordinator`. Not one is on a
sub-agent. `DelegateTask` creates its child with an empty config and never adds a
tool, while its own docstring claims the opposite:

> The sub-agent will have its own conversation context and **can use the same
> tools as the parent.**

It cannot. It has none.

**The consequence is that ObjectScript recursion stops at depth 1.**
`NestedAgents.DeepDelegation()` advertises "Parent → Sub-agent → Sub-sub-agent"
and cannot reach the third level: the sub-agent it creates has no
`delegate_task` tool, so there is nothing for it to delegate with. The example
demonstrates two levels while documenting three.

`RunAll()` also excludes `DeepDelegation()`, attributing this to cost:

> This example is more expensive (multiple nested LLM calls). Run it manually.

That may be entirely about token spend. It is also the one example whose claimed
behaviour is unreachable, and it is the one not covered by the automated path.

**This lines up exactly with `ai-hub-eap#26`**, which SPEC §6 records as failing
*"only when the child has tools attached"*, measured on Build 126U — later than
the Build 121 Python fix. The shipped ObjectScript samples never enter that
configuration. Whether that is because it still fails or because nobody tried it
is the single most valuable thing this request wants answered.

## 5. Requested capability

Renumbered against what now exists. Each says which binding already satisfies it.

### Parity — the core of the request

- **FR-1 — An ObjectScript sub-agent may hold tools.** `%AI.Agent.SubAgent`
  children must accept `ToolManager.AddTool`, or `Create` must take a toolset.
  *Python: yes. ObjectScript: not demonstrated anywhere.*
- **FR-2 — A tool-bearing child dispatched from a parent's tool loop returns.**
  This is `ai-hub-eap#26` stated as a requirement.
  *Python: fixed in Build 121. ObjectScript: unknown, last measured failing on 126U.*
- **FR-3 — A child may hold the spawning tool itself,** so depth is bounded by
  policy rather than by the child being unable to delegate.
  *Python: yes. ObjectScript: no.*
- **FR-4 — `DelegateTask`'s docstring and behaviour agree.** Either give the
  child the parent's tools or stop saying it has them. A sample is the API
  contract most people read first.

### Depth as a platform quantity

- **FR-5 — Depth is tracked and readable by a child** without the caller
  threading it through a prompt. Threading it by convention means any entry point
  that forgets recurses unbounded. *Python: in the RLM example only, not the
  platform. ObjectScript: absent entirely.*
- **FR-6 — The ceiling is enforced by `%AI.*`, not by each sample.** Today
  `max_depth` lives in `RLMToolSet`, so every caller reimplements it and each
  reimplementation is a chance to omit it.
- **FR-7 — Degradation at the ceiling is selectable.** Python truncates; refusing
  is the safer default. Let the caller choose. *Python: truncates, hardcoded.*
- **FR-8 — Depth is visible on outbound provider traffic.** `rlm-harness` sets
  `X-RLM-Depth` on every request so a proxy can separate root from sub-agent
  calls. Without an equivalent, trajectories cannot be filtered by level, which
  is what makes recursive runs trainable and auditable. *Neither binding.*

### Width

- **FR-9 — Arbitrary, runtime-decided fan-out width,** executing concurrently.
  `NestedAgents.ParallelDelegation()` is named "parallel" but its own comment says
  "concurrently (conceptually)" — the delegations are sequential tool calls.
  SPEC §6 expects `%AI.Op.Map` to be where real concurrency lands.

### Accounting and lifecycle

- **FR-10 — License slots released on every exit path**: completion, failure,
  cancellation, timeout, ceiling refusal. The leak is the half of `eap#26` that
  outlives the run.
- **FR-11 — Budget aggregates across the subtree.** `session.GetStats()` returns
  `total_interactions` and `total_tool_calls` for one session; a parent needs the
  total for everything below it.
- **FR-12 — Cancellation propagates down.**
- **FR-13 — A failed child does not fail the parent.** `DelegateTask` returns its
  exception as a string, which is the right instinct, but it means a failure and
  an answer are the same type and a caller cannot tell them apart.
- **FR-14 — A timeout per child and for the subtree.**

### Observability

- **FR-15 — One trajectory record spans the tree,** each entry carrying depth and
  parent, so the call graph is reconstructable rather than inferred from
  timestamps.

## 6. Two things not to design away

- **`MaxIterations` must stay separable from depth.** A tool loop's iteration
  count and a recursion's depth bound different things; one knob covering both
  controls neither.
- **Spawning should not *require* a `%AI.Tool`.** `NestedAgents.DirectSubagentCreation()`
  already shows the programmatic path, and it is the right one: recursion is
  control flow, not a capability the model must be persuaded to invoke. Keep it
  first-class rather than tool-only — `rlm-harness` makes the same choice by
  injecting the recursive call into the execution environment.

## 7. Acceptance criteria

- **AC-1** An ObjectScript sub-agent is created with a tool attached, dispatched
  from a parent's tool loop, and returns. *(FR-1, FR-2 — the whole request.)*
- **AC-2** A three-level ObjectScript tree completes, every level holding at least
  one tool, with the leaf's result reaching the root — i.e. `DeepDelegation()`
  does what it says.
- **AC-3** A root fanning out to 50 children completes, wall-clock materially
  below the sequential sum.
- **AC-4** After AC-1–AC-3, license-slot count returns to its pre-run value; 100
  iterations of each show no monotonic growth.
- **AC-5** A ceiling of 2 stops the third level with a distinct error, and the run
  completes rather than hanging.
- **AC-6** One child of a 20-child fan-out throws; the parent gets 19 results and
  one failure, distinguishable from a successful answer.
- **AC-7** Cancelling the root returns within a bounded interval and releases every
  descendant's slot.
- **AC-8** The trajectory for AC-2 reconstructs the tree; every entry resolves to
  its parent and carries depth.
- **AC-9** Requests from depth 0 are distinguishable from depth ≥ 1 without
  inspecting prompt content.

`UnitTest.RLMAIHub.AgentProbe` in this repository reports the real signatures on
any instance without calling anything; see
[AIHUB-PROBE-RUNBOOK.md](AIHUB-PROBE-RUNBOOK.md).

## 8. What we would retire on arrival

| Ours today | On arrival |
| --- | --- |
| Sequential recursion in `RLM.Engine` | Parallel fan-out in `rlm-aihub`; `rlm-core` keeps its own for portability |
| `RLM.Budget` per-run accounting | Adopt subtree accounting; keep ours as the portable path |
| `RLM.Trace` + `^RLM.State` | Map onto the core trajectory record if it carries an extensible metric bag |
| `RLM.Slice` depth cap | Keep — it bounds a *name grammar*, not a call tree |

`rlm-core` recurses in ObjectScript regardless, because it must install on base
IRIS with no `%AI.*` dependency. This request is about `rlm-aihub` and about
customers building directly on `%AI.Agent`.

## 9. Priority

**Blocking** for recursive agent workloads on the ObjectScript binding, which is
the one IRIS customers with data that cannot leave will use — a 400M-row
`Ens.MessageHeader` under an SLA, a PHI-bearing clinical extent, an undocumented
global with no schema. The Python binding demonstrates the platform can already
do this; the asymmetry is what makes it urgent rather than speculative.

## 10. Open questions

1. **Does `ai-hub-eap#26` still reproduce?** `safe_block_on` is referenced in
   `DelegateTask`'s comment and `create_child_agent` fixed the Python side in
   Build 121, but the failure was measured on 126U and no ObjectScript sample
   enters the failing configuration.
2. **Can `%AI.Agent.SubAgent` children hold tools at all today?** If yes, FR-1 is
   a documentation and sample gap rather than a code change.
3. **What is `SubAgent.Create`'s third parameter?** Every sample passes `""` with
   the comment "No additional config for now". If it takes a toolset, most of §5
   is already satisfied and undocumented.
4. **Is `%AI.Op.Map` intended to support nested maps** — a child that itself maps
   — or only one level of fan-out?
5. **Does the planned core trajectory record carry depth or parent?** If not, is
   an extensible metric bag available?
6. **How are license slots accounted for concurrent children** — per agent
   instance, per session, or per process? AC-4 is written against instance count
   because we do not know.
7. **Is there an intended interaction between depth and `%AI.Context.Store`?** A
   child receiving a handle rather than a copy is the natural composition and
   would make deep trees far cheaper.
