# Enhancement Request: bounded recursive sub-agent fan-out in AI Hub

**To:** InterSystems AI Hub team
**From:** Thomas Dyar
**Date:** 2026-08-09 · **Revised** 2026-08-12 against `ai-core` @ `994c8f1`
**Target:** `%AI.*` core, post-2026.3AI
**Related:** `ai-hub-eap#26` · [`docs/SPEC.md` §6](SPEC.md) · `rlm-aihub`

**Evidence:** `objectscript/USER_GUIDE.md` §Sub-Agents · `Sample.AI.Examples.NestedAgents` ·
`Sample.AI.Tools.DelegateTask` · `Sample.AI.Tools.RLM` · `Sample.AI.Examples.RLMBridge` ·
`python/rlm/toolset.py` · `tests/test_rlm_child_agent.py`

---

## 1. The ask

AI Hub can already do recursive sub-agents in ObjectScript, and **nothing bounds
the recursion**. `CreateSubAgent()` exists, a sub-agent can be given tools, and a
sub-agent can therefore be given the tool that creates sub-agents — with no depth
ceiling anywhere in the platform. The guidance is prose: *"Keep nesting shallow —
2-3 levels max in most cases."*

So the primary request is a safety one: **make depth a platform-enforced
quantity.** Secondary to it, three parity gaps between the Python and ObjectScript
bindings, and one unresolved defect.

Two earlier drafts of this document were wrong in the same direction — they asked
for capability that already ships. The evidence below is why the ask is now
narrower and, I think, more urgent.

## 2. What already exists

**Sub-agents, and they can hold tools.** `USER_GUIDE.md` §Sub-Agents, Method 2:

```objectscript
Set poetAgent = parentAgent.CreateSubAgent("You are a creative poet...")
Do poetAgent.ToolManager.AddTool("iris:MyApp.PoemTools")   // child holds a tool
Set session  = poetAgent.CreateSession()
Set response = poetAgent.Run(session, "Write a haiku about the ocean")
```

Children inherit provider, model, temperature, `MaxIterations`,
`AutoCompactOnTokenLimit`, and the tool-access policies (`AuthPolicy`,
`AuditPolicy`, `DiscoveryPolicy`), with a rationale worth quoting because it is
exactly right:

> a sub-agent is an implementation detail of a tool the parent chose to use, not
> something separately configured, so a policy restricting the parent's tool
> access extends to its sub-agents too.

**A tool-dispatched path.** `Sample.AI.Tools.DelegateTask` is a `%AI.Tool` calling
`%AI.Agent.SubAgent.Create(..ParentAgent, systemPrompt, "")` from inside a
parent's loop, noting it *"will use `safe_block_on` internally to handle nested
runtime contexts."*

**Automatic compaction.** `agent.AutoCompactOnTokenLimit = 1`, inherited by
children.

**Four independent guards on a single agent's loop** — this matters for §3:

| Guard | Scope | Default |
|---|---|---|
| `%AI.Agent.MaxIterations` | outer `Run()` turns | 10 |
| `max_iterations` in `CreateSession` | inner tool rounds per `Chat()` | 10, `0` disables |
| `timeout_ms` in `CreateSession` | wall clock for the agentic loop | none |
| Loop detection | always on; strategy nudge, then `LoopDetected` | n/a |

Loop detection is genuinely good: it notices tool calls that stop producing new
information, nudges first, and errors second, which is why the guide can say
*"setting `max_iterations = 0` is safe precisely because loop detection is always
active."*

**Iteration callbacks.** `OnIterationStart(iteration, maxIter, session)` /
`OnIterationComplete`, with `session.GetStats()` exposing
`current_context_tokens` — enough to build a budget on top.

**Persistent sessions.** `%AI.Agent.Session` is `%Persistent` with incremental
`%Save()`.

**A governance surface that already fits this package's needs.**
`ToolManager.SetAuthPolicy` / `SetAuditPolicy`, a `%AI.Policy.Discovery` whose
`%Resolve()` filters the catalog *before the LLM sees it*, a `REQUIRESAUTH` class
parameter, and tools addressed by URI (`iris:`, `rust:`, `mcp:stdio:`,
`mcp:remote:`). Nothing is requested here; it is recorded so it is not asked for.

**Caps already reported, not hidden.** Every `<Query>` tool returns:

```json
{"rows": [...], "row_count": 25, "truncated": false, "elapsed_ms": 12}
```

> `truncated: true` means the result was capped by the row limit. The LLM can use
> this as a signal to narrow the query.

That is `rlm-core`'s Constitution II — *caps are reported, never hidden* —
arrived at independently. The two designs agree on the invariant, which is worth
saying because the rest of this document is about a disagreement.

**Python has the full RLM shape.** `create_child_agent(model, provider)` shares
the parent's tokio runtime (Build 121+, fixing the `cannot call block_on inside a
runtime` panic), and `toolset.py:533` gives the child the toolset —
`sub_agent.add_tool_set(toolset)` — so the child holds `spawn_subagent` and
recursion is genuine. `tests/test_rlm_child_agent.py` covers it at unit,
integration and E2E levels, and `current_depth`/`max_depth` degrade gracefully at
the ceiling.

That is a lot, and most of this request's original content is already met.

## 3. Gap 1 — recursion is unbounded (the safety issue)

`grep -niE 'max.?depth|depth limit|recursion (limit|depth)'` over
`USER_GUIDE.md` returns **nothing**. There is no depth parameter, no ceiling, no
error. The only control is advice in a Best Practices list.

Combine that with §2 and the exposure is concrete: `CreateSubAgent()` returns a
full agent, a full agent accepts `ToolManager.AddTool`, and `DelegateTask` is a
tool. Handing a sub-agent a `DelegateTask` — which the guide's own Method 2
pattern makes a two-line change — produces unbounded recursion, and each level
holds a license slot and spends tokens. Nothing in the platform stops it.

**The four guards in §2 do not bound a tree, and recursion makes each of them
weaker rather than stronger.** Every one is scoped to a single agent's loop:

- `MaxIterations` is *inherited* by a child, so each level gets a fresh
  allowance of the same size. Ten levels is ten times the turns, not ten of them.
- `max_iterations` and `timeout_ms` live on a **session**, and a child calls
  `CreateSession()` for its own. A parent's 60-second deadline does not constrain
  a child that starts its own clock.
- Loop detection watches for repeated tool calls **within** a conversation. Each
  level of a recursion is a distinct agent with a distinct session issuing a
  legitimately different call, so there is no repetition for it to see.

That is the shape of the gap: the platform is carefully guarded along the
iteration axis and entirely unguarded along the depth axis, and the guards it has
multiply with depth instead of composing. A recursion that is well-behaved at
every individual level can still consume the instance.

Python bounds this in `RLMToolSet` rather than in `%AI.*`, which means the bound
is per-example: every caller reimplements it, and every reimplementation is a
chance to omit it. In ObjectScript nobody has implemented it at all.

- **FR-1** A depth ceiling settable on an agent and enforced by `%AI.*`, defaulting
  to something finite — the depth-axis counterpart to `MaxIterations`, and ideally
  a subtree-wide `timeout_ms` and token budget that a child inherits a *remaining*
  share of rather than a fresh copy of.
- **FR-2** Depth readable by a child without the caller threading it through a
  prompt. Threading by convention means any entry point that forgets recurses
  unbounded.
- **FR-3** Behaviour at the ceiling selectable: refuse with a distinguishable
  error (safer default), or degrade to a plain completion the way Python's
  toolset truncates.

## 4. Gap 2 — the ObjectScript RLM toolset is not recursive

Compare the two shipped RLM toolsets:

| | Python `RLMToolSet` | ObjectScript `Sample.AI.Tools.RLM` |
|---|---|---|
| Inspect | `peek_context` | `inspect_context` |
| Search | `search_context` | `search_context` |
| Named variables | `store_var`, `peek_var`, `search_var` | — (`store_note` appends to a list) |
| **Recursion** | **`spawn_subagent`** | **absent** |
| Finalize | `finalize` | `finalize` |

The ObjectScript version is context search with a notes list. It is not an RLM:
there is no sub-call and no variable namespace, which are two of the four
primitives the formulation needs.

`Sample.AI.Examples.RLMBridge` is the acknowledgement of this. Its entire method
is:

```objectscript
Set rc = $ZF(-100, "/bin/sh", "-lc", "cd ... && python python/rlm/run_rlm_demo.py ...")
```

The sanctioned route to a real RLM from ObjectScript is to shell out to the
Python one.

- **FR-4** `Sample.AI.Tools.RLM` gains `spawn_subagent` and a named-variable
  namespace, so the two bindings demonstrate the same pattern.
- **FR-4b** An ObjectScript equivalent of Python's `RunContext[T]`. A tool
  parameter typed as `RunContext` carries per-request data and is *"excluded from
  the LLM tool schema"* — the model can neither see nor author it. That is this
  package's Constitution II at the platform level, and ObjectScript has nothing
  like it: a tool needing a slice predicate, a source handle or a tenant id must
  take it as a model-visible argument or hold it as instance state. Python has 40
  references to `RunContext` and 54 to `deps`; the ObjectScript tree has zero.
  `ModelRetry` and structured output are absent on the same side.

## 5. Gap 3 — fan-out is sequential

`USER_GUIDE.md` is explicit — *"**Latency**: Nested calls are sequential"* — and
`NestedAgents.ParallelDelegation()` is named for something its own comment
disclaims: *"Tasks are executed sequentially but represent logically parallel
concerns."* No fan-out or map operator appears in the guide at all.

For decomposition this is the difference between usable and not. The academic
budget model is about choosing batch shape per decision — `llm_query_batched`
over N slices — which is meaningless if N children run one after another.

- **FR-5** Concurrent execution of sibling children, width decided at runtime.
  We asked for a parallel map operator in our own harness spec; nothing by that
  description appears in this distribution, so this is a request rather than a
  reminder.

## 6. Gap 4 — depth is invisible downstream

- **FR-6** One trajectory record spanning the tree, each entry carrying depth and
  parent. `session.GetStats()` gives `total_interactions` and `total_tool_calls`
  for one session; a parent cannot learn its subtree's total.
- **FR-7** Depth visible on outbound provider traffic. `rlm-harness` sets
  `X-RLM-Depth` on every request so a proxy can separate root from sub-agent
  calls — the property that makes recursive runs trainable and auditable.
- **FR-8** License slots released on every exit path: completion, failure,
  cancellation, timeout, ceiling refusal.
- **FR-9** Cancellation propagates to descendants.
- **FR-10** A failed child is distinguishable from an answer. `DelegateTask`
  returns `"Error in delegation: " _ ex.DisplayString()` as its result string, so
  a failure and a successful answer have the same type.

## 7. The unresolved defect

`ai-hub-eap#26`, recorded in SPEC §6 and re-confirmed on Build 126U during M5:

> A `%AI.Tool` that spawns a child agent never returns when the parent's own loop
> dispatches it — **and only when the child has tools attached**. It also leaks
> license slots.

Build 121 fixed the equivalent Python panic via `create_child_agent`, and
`DelegateTask` cites `safe_block_on`, so the ObjectScript path may be fixed too.
**No shipped ObjectScript sample enters the failing configuration**, so nothing
demonstrates either way: `DelegateTask` creates its child with `""` and never adds
a tool.

Two visible consequences of that gap:

- `DelegateTask`'s docstring says the sub-agent *"can use the same tools as the
  parent."* It has none.
- `NestedAgents.DeepDelegation()` advertises "Parent → Sub-agent → Sub-sub-agent"
  and can reach two levels. Its child has no `delegate_task` tool, so there is
  nothing to delegate with. It is also the one example `RunAll()` skips,
  attributed to cost.

- **FR-11** A sample that gives a child a tool and dispatches it from a parent's
  loop — proving the case, or reproducing the defect.
- **FR-12** `DelegateTask`'s docstring and behaviour agree, either way.

## 8. Acceptance criteria

- **AC-1** A tool-bearing ObjectScript child, dispatched from a parent's tool loop,
  returns. *(§7)*
- **AC-2** A three-level tree completes with every level holding a tool — i.e.
  `DeepDelegation()` does what it documents.
- **AC-3** A ceiling of 2 stops the third level with a distinct error, and the run
  completes rather than hanging. *(FR-1)*
- **AC-4** With no ceiling configured, a self-delegating sub-agent terminates on a
  platform default rather than running until the license pool is exhausted.
- **AC-4b** A parent with `timeout_ms = 60000` that spawns children does not exceed
  60s of wall clock in total — i.e. a child inherits the remaining budget rather
  than starting a fresh one. *(The current behaviour is believed to be the
  opposite; this AC is written to make that explicit either way.)*
- **AC-5** A root fanning out to 50 children completes, wall-clock materially below
  the sequential sum. *(FR-5)*
- **AC-6** After AC-1–AC-5, license-slot count returns to its pre-run value; 100
  iterations show no monotonic growth. *(FR-8)*
- **AC-7** One child of a 20-child fan-out throws; the parent receives 19 results
  and one failure, distinguishable from an answer. *(FR-10)*
- **AC-8** Cancelling the root returns within a bounded interval and releases every
  descendant's slot. *(FR-9)*
- **AC-9** The trajectory for AC-2 reconstructs the tree; every entry resolves to
  its parent and carries depth. *(FR-6)*
- **AC-10** Requests from depth 0 are distinguishable from depth ≥ 1 without
  inspecting prompt content. *(FR-7)*

`UnitTest.RLMAIHub.AgentProbe` in this repository reports the real signatures on
any instance without calling anything — see
[AIHUB-PROBE-RUNBOOK.md](AIHUB-PROBE-RUNBOOK.md).

## 9. One observation, offered rather than requested

`Sample.AI.Tools.RLM` holds its context as `Property Context As %String(MAXLEN = "")`,
and Python's holds it in process memory. Both therefore bound the context by RAM,
which is the same ceiling every published RLM has — the MIT reference library
reads its context into a REPL variable too.

IRIS does not have to. A context that is a global, a table or a result set, with
the model's slicing running against the database, removes that ceiling entirely,
and is the one thing this platform can do that no Python RLM can. It is not part
of this request — `rlm-core` already works this way — but it is where context
offloading and a recursive agent would compose into something genuinely
differentiated.

## 10. Open questions

1. **Does `ai-hub-eap#26` still reproduce?** The single most valuable answer here.
2. **Is there any depth guard we have missed** — in `%AI.Agent`, `ToolManager`, or
   the runtime — that `USER_GUIDE.md` does not document?
3. **What is `%AI.Agent.SubAgent.Create`'s third parameter?** Every sample passes
   `""` with "No additional config for now". If it takes a toolset, FR-4 is
   already satisfied and undocumented.
4. **`CreateSubAgent()` vs `%AI.Agent.SubAgent.Create()`** — two spellings appear
   across the guide and the samples. Are both supported, and is one preferred?
5. **Is a parallel map / fan-out operator planned, and would it support nesting** —
   a child that itself maps? We proposed one in our own harness spec; nothing by
   that description appears in the shipped distribution, so we do not know whether
   it was taken up or under what name.
6. **Does the planned core trajectory record carry depth or parent?**
7. **How are license slots accounted for concurrent children** — per agent
   instance, per session, or per process? AC-6 is written against instance count
   because we do not know.
8. **Is context offloading planned, and would it interact with depth?** A child
   receiving a handle rather than a copy would make deep trees far cheaper.
