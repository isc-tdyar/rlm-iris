# Enhancement Request: bounded recursive sub-agents in AI Hub

**To:** InterSystems AI Hub team
**From:** Thomas Dyar
**Date:** 2026-08-09 · **Revised** 2026-08-12
**Target:** `%AI.*` core, post-2026.3AI
**Related defect:** `ai-hub-eap#26`

**Every claim below is cited from the `ai-core` distribution @ `994c8f1`
(2026-08-07)** — `objectscript/USER_GUIDE.md`, `python/PYTHON_USER_GUIDE.md`,
`Sample.AI.Examples.NestedAgents`, `Sample.AI.Tools.DelegateTask`,
`Sample.AI.Tools.RLM`, `Sample.AI.Examples.RLMBridge`, `python/rlm/toolset.py`,
`tests/test_rlm_child_agent.py`. No prior context is assumed; this document
stands on its own.

---

## 1. The ask

AI Hub can already do recursive sub-agents in ObjectScript, and **nothing bounds
the recursion**. `CreateSubAgent()` returns a full agent, a full agent accepts
`ToolManager.AddTool`, and a delegation tool is an ordinary `%AI.Tool` — so an
agent can hold the tool that creates agents, with no depth ceiling anywhere in
the platform. §3 gives a runnable reproduction. The only control today is prose
in a Best Practices list: *"Keep nesting shallow — 2-3 levels max in most cases."*

So the immediate request is a safety one: **make depth a platform-enforced
quantity.** Alongside it, three parity gaps between the Python and ObjectScript
bindings, and one unresolved defect.

Two earlier drafts of this document asked for capability that already ships. The
evidence in §2 is why the ask is now narrower — and, because §1.1 explains what
it unlocks, why it is worth more than a bug fix.

## 1.1 Why this is worth more than a guard rail

Recursive decomposition is the dominant scaffold for long-context and
long-horizon agent work — the Recursive Language Model formulation (Zhang, Kraska
and Khattab, MIT CSAIL, [arXiv:2512.24601](https://arxiv.org/abs/2512.24601)),
Prime Intellect's `rlm-harness`, and their Prime Agent product all converge on the
same structure, and AI Hub's own `python/rlm/` example implements it. The platform
has already accepted the premise.

The part worth noticing is what recursion plus a trajectory record makes possible.
**An agent platform becomes a *trainable harness* when it can (a) run the
recursive pattern — depth-bounded sub-agents with runtime-decided fan-out — and
(b) emit a depth-tagged trajectory whose reward is computable offline.**

AI Hub is unusually close to (b) already: sessions are `%Persistent` with
incremental save, `GetStats()` exposes per-iteration token counts, and iteration
callbacks give a hook per turn. What is missing is the **depth dimension** — a
trajectory that cannot be separated by level cannot be filtered, credited, or
trained on. `rlm-harness` treats this as non-negotiable and sets `X-RLM-Depth` on
every outbound request precisely so a proxy can tell a root call from a
sub-agent call.

And AI Hub has a structural advantage over every published RLM here, which is
worth stating because it is not obvious. Prime Agent and `rlm-harness` put the
model in a Python REPL, so a trajectory depends on code the model wrote and cannot
be re-scored without re-running against a live model — which is exactly why
`verifiers` has no offline training path and `prime-rl` requires the live policy's
own sampling logprobs. A tool-call trajectory over enumerated, replayable
operations does not have that problem: a finished run is a *dataset*. Offline
policy comparison and imitation learning become possible where those systems need
online rollouts.

That is the strategic case. FR-1 to FR-3 are the safety floor; **FR-8 (depth on
the trajectory and on outbound requests) is the one that turns AI Hub into
something trainable**, and it is cheap.

## 1.2 Requirements at a glance

Listed in priority order, not numeric order.

| FR | Ask | Why | Priority |
| --- | --- | --- | --- |
| 12 | A sample giving a child a tool, dispatched from a parent loop | Settles whether `eap#26` still reproduces; unblocks everything else | **P0** |
| 1 | Depth ceiling enforced by `%AI.*`, finite default | Recursion is currently unbounded (§3) | **P0 — safety** |
| 2 | Depth readable by a child without prompt threading | Convention-threading fails open | **P0 — safety** |
| 9 | License slots released on every exit path | The half of `eap#26` that outlives the run | **P0 — safety** |
| 8 | Depth on the trajectory record and on outbound requests | **Makes recursive runs trainable and auditable** | **P0 — strategic** |
| 3 | Ceiling behaviour selectable: refuse or degrade | Refuse is the safe default | P1 |
| 7 | One trajectory spanning the tree, entries carrying parent | Call graph must be reconstructable | P1 |
| 13 | `DelegateTask` docstring and behaviour agree | It claims tools the child does not have | P1 — trivial |
| 4 | ObjectScript RLM toolset gains sub-calls and a variable namespace | Python has both; ObjectScript has neither | P1 |
| 5 | A `RunContext` equivalent for ObjectScript | Model-invisible tool arguments; Python-only today | P1 |
| 6 | Concurrent sibling children, runtime-decided width | Nested calls are documented as sequential | P2 |
| 10 | Cancellation propagates to descendants | | P2 |
| 11 | A failed child distinguishable from an answer | Errors return as ordinary result strings | P2 |

If only three things are done: **FR-12** (settle the defect), **FR-1** (bound the
recursion), **FR-8** (tag the depth).

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
`%Save()`, plus `AddCheckpoint` / `RestoreCheckpoint` / `ListCheckpoints`.

**A governance surface that already fits what decomposition needs.**
`ToolManager.SetAuthPolicy` / `SetAuditPolicy`, a `%AI.Policy.Discovery` whose
`%Resolve()` filters the catalog *before the LLM sees it*, a `REQUIRESAUTH` class
parameter, and tools addressed by URI (`iris:`, `rust:`, `mcp:stdio:`,
`mcp:remote:`). Nothing is requested here; it is recorded so it is not asked for.
(Noting only that `MCP_SERVER_GUIDE.md:611` marks the Discovery policy
*"experimental and may change or be removed without a deprecation period"*, which
makes it hard to build on.)

**Caps already reported, not hidden.** Every `<Query>` tool returns:

```json
{"rows": [...], "row_count": 25, "truncated": false, "elapsed_ms": 12}
```

> `truncated: true` means the result was capped by the row limit. The LLM can use
> this as a signal to narrow the query.

We hold the same rule as a design invariant in our own decomposition engine —
*caps are reported, never hidden*, because a model that reads a truncated count as
a total inherits the error into every downstream claim. Arriving at it
independently is a good sign, and worth saying because the rest of this document
is about disagreements.

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
`objectscript/` returns **nothing**. No depth parameter, no ceiling, no error —
the only hits anywhere in that tree are "defence-in-depth" security phrasing.

To be precise about what does and does not recurse today: the shipped
`Sample.AI.Tools.DelegateTask` creates its child with `SubAgent.Create(..., "")`
and adds no tools, so that child cannot delegate and the sample stops at one
level. Nothing in the platform makes that the only option. Combining it with the
Method 2 pattern above — **one line** — produces a tool that recurses forever:

```objectscript
Class MyApp.Tools.Delegate Extends %AI.Tool
{
Parameter DESCRIPTION = "Delegate a subtask to a specialist sub-agent.";
Property ParentAgent As %AI.Agent;

Method Execute(task As %String) As %String [ WebMethod ]
{
    Set child = ..ParentAgent.CreateSubAgent("You are a specialist. Delegate further if useful.")

    // The only line that differs from Sample.AI.Tools.DelegateTask:
    Set t = ##class(MyApp.Tools.Delegate).%New()
    Set t.ParentAgent = child
    Do child.ToolManager.AddTool(t)        // the child can now delegate too

    Set session = child.CreateSession()
    Quit child.Run(session, task).Content
}
}
```

Each level holds a license slot and spends tokens, and nothing stops it. This is
not an exotic construction — it is the shipped sample plus the documented way to
give a sub-agent a tool.

**The four guards in §2 do not bound a tree, and recursion makes each of them
weaker rather than stronger.** Every one is scoped to a single agent's loop:

- `MaxIterations` is *inherited* by a child, so each level gets a fresh allowance
  of the same size. Ten levels is ten times the turns, not ten of them.
- `max_iterations` and `timeout_ms` live on a **session**, and a child calls
  `CreateSession()` for its own. A parent's 60-second deadline does not constrain
  a child that starts its own clock.
- Loop detection watches for repeated tool calls **within** a conversation. Each
  level is a distinct agent with a distinct session issuing a legitimately
  different call, so there is no repetition for it to see.

That is the shape of the gap: the platform is carefully guarded along the
iteration axis and entirely unguarded along the depth axis, and the guards it has
multiply with depth instead of composing. A recursion that is well-behaved at
every individual level can still consume the instance.

Python bounds this in `RLMToolSet` rather than in `%AI.*` — `DEFAULT_MAX_DEPTH=5`,
`MIN=1`, `MAX=8`, range-validated, incremented per spawn, enforced at two sites,
unit-tested. That is the right model; the problem is that it lives in an example,
so every caller reimplements it and every reimplementation is a chance to omit
it. In ObjectScript nobody has implemented it at all.

- **FR-1** A depth ceiling settable on an agent and enforced by `%AI.*`, with a
  finite default — the depth-axis counterpart to `MaxIterations`, and ideally a
  subtree-wide `timeout_ms` and token budget that a child inherits a *remaining*
  share of rather than a fresh copy of.
- **FR-2** Depth readable by a child without the caller threading it through a
  prompt. Threading by convention means any entry point that forgets recurses
  unbounded.
- **FR-3** Behaviour at the ceiling selectable: refuse with a distinguishable
  error (safer default), or degrade to a plain completion the way Python's
  toolset truncates.

## 4. Gap 2 — the ObjectScript RLM toolset is not recursive

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

`Sample.AI.Examples.RLMBridge` is the acknowledgement. Its entire method is:

```objectscript
Set rc = $ZF(-100, "/bin/sh", "-lc", "cd ... && python python/rlm/run_rlm_demo.py ...")
```

The sanctioned route to a real RLM from ObjectScript is to shell out to the
Python one.

- **FR-4** `Sample.AI.Tools.RLM` gains `spawn_subagent` and a named-variable
  namespace, so the two bindings demonstrate the same pattern.

## 5. Gap 3 — no way to pass a tool an argument the model cannot see

Python tools may take a `RunContext[T]` parameter carrying per-request data, and
*"`RunContext[T]` parameters are **excluded** from the LLM tool schema"* — the
model can neither see it nor author it. Python has 40 references to `RunContext`
and 54 to `deps`; the ObjectScript tree has **zero**. `ModelRetry` (36 refs) and
structured output (41 refs) are absent on the same side.

This matters more than a convenience gap. An ObjectScript tool that needs a slice
predicate, a source handle, a tenant id or a row cap must either accept it as a
model-visible argument — where the model can rewrite it — or hold it as instance
state on a stateful tool, which the shell tool's documentation already warns is
fragile behind a CSP job pool. There is no supported way to say *"this argument
is the caller's, not the model's."*

For any workload where a tool argument is a security boundary, that is the
difference between a scoped call and a suggestion.

- **FR-5** An ObjectScript equivalent of `RunContext[T]`: tool parameters that
  carry caller-supplied data and are excluded from the generated tool schema.

## 6. Gap 4 — fan-out is sequential

`USER_GUIDE.md` is explicit — *"**Latency**: Nested calls are sequential"* — and
`NestedAgents.ParallelDelegation()` is named for something its own comment
disclaims: *"Tasks are executed sequentially but represent logically parallel
concerns."* No fan-out or map operator appears in the guide at all.

For decomposition this is the difference between usable and not. The RLM budget
model is about choosing batch shape per decision — many slices examined at once —
which is meaningless if N children run one after another.

- **FR-6** Concurrent execution of sibling children, width decided at runtime.

## 7. Gap 5 — depth is invisible downstream

- **FR-7** One trajectory record spanning the tree, each entry carrying depth and
  parent, so the call graph is reconstructable rather than inferred from
  timestamps. `session.GetStats()` gives `total_interactions` and
  `total_tool_calls` for one session; a parent cannot learn its subtree's total.
- **FR-8** Depth visible on outbound provider traffic. `rlm-harness` sets
  `X-RLM-Depth` on every request so a proxy can separate root from sub-agent
  calls — the property that makes recursive runs trainable and auditable, and the
  cheapest item in this document.

## 8. Gap 6 — subtree lifecycle

- **FR-9** License slots released on every exit path: completion, failure,
  cancellation, timeout, ceiling refusal.
- **FR-10** Cancellation propagates to descendants.
- **FR-11** A failed child is distinguishable from an answer. `DelegateTask`
  returns `"Error in delegation: " _ ex.DisplayString()` as its result string, so
  a failure and a successful answer have the same type and a caller cannot branch
  on which it got.

## 9. The unresolved defect

`ai-hub-eap#26`. Our summary of the behaviour, last reproduced on **2026.3.0AI
Build 126U** — please check this against the issue text, which we are
paraphrasing:

> A `%AI.Tool` that spawns a child agent never returns when the parent's own loop
> dispatches it — **and only when the child has tools attached**. It also leaks
> license slots.

Build 121 fixed the equivalent Python panic via `create_child_agent`, and
`DelegateTask` cites `safe_block_on`, so the ObjectScript path may be fixed too.
**No shipped ObjectScript sample enters the failing configuration**, so nothing
demonstrates it either way: `DelegateTask` creates its child with `""` and never
adds a tool.

Two visible consequences of that gap:

- `DelegateTask`'s docstring says the sub-agent *"can use the same tools as the
  parent."* It has none.
- `NestedAgents.DeepDelegation()` advertises "Parent → Sub-agent → Sub-sub-agent"
  and can reach two levels, because its child has no `delegate_task` tool and so
  has nothing to delegate with. It is also the one example `RunAll()` skips,
  attributed to cost.

- **FR-12** A sample that gives a child a tool and dispatches it from a parent's
  loop — proving the case, or reproducing the defect.
- **FR-13** `DelegateTask`'s docstring and behaviour agree, either way.

## 10. Acceptance criteria

Every FR has at least one. Reproducible without any of our code.

| AC | Criterion | Covers |
|---|---|---|
| 1 | A tool-bearing ObjectScript child, dispatched from a parent's tool loop, returns | FR-12 |
| 2 | A three-level tree completes, every level holding a tool — i.e. `DeepDelegation()` does what it documents | FR-12, FR-13 |
| 3 | A ceiling of 2 stops the third level with a distinct error, and the run completes rather than hanging | FR-1, FR-3 |
| 4 | With no ceiling configured, the §3 recursion terminates on a platform default rather than exhausting the license pool | FR-1 |
| 5 | A child can read its own depth without the parent putting it in a prompt | FR-2 |
| 6 | A parent with `timeout_ms = 60000` that spawns children does not exceed 60s of wall clock in total — a child inherits the remaining budget, not a fresh one | FR-1 |
| 7 | With the ceiling set to degrade rather than refuse, the run completes with a plain completion at the deepest level | FR-3 |
| 8 | An ObjectScript RLM toolset run performs a sub-call and stores and retrieves a named variable | FR-4 |
| 9 | A tool declares a caller-supplied parameter; the generated tool schema sent to the model does not contain it | FR-5 |
| 10 | A root fanning out to 50 children completes, wall-clock materially below the sequential sum | FR-6 |
| 11 | The trajectory for AC-2 reconstructs the tree; every entry resolves to its parent and carries depth | FR-7 |
| 12 | Requests from depth 0 are distinguishable from depth ≥ 1 without inspecting prompt content | FR-8 |
| 13 | After AC-1–AC-12, license-slot count returns to its pre-run value; 100 iterations show no monotonic growth | FR-9 |
| 14 | Cancelling the root returns within a bounded interval and releases every descendant's slot | FR-10 |
| 15 | One child of a 20-child fan-out throws; the parent receives 19 results and one failure, distinguishable from an answer | FR-11 |

**A probe is available on request.** We have a read-only ObjectScript class that
reports every `%AI.*` class on a live instance with full method signatures, read
from `%Dictionary.CompiledClass`/`CompiledMethod` — it calls nothing, spends no
license slot, and cannot hang, which matters because the defect in §9 is a hang.
Happy to hand it over if it would speed up settling AC-1 and the open questions
below.

## 11. One observation, offered rather than requested

`Sample.AI.Tools.RLM` holds its context as `Property Context As %String(MAXLEN = "")`,
and Python's holds it in process memory. Both therefore bound the context by RAM,
which is the same ceiling every published RLM has — the MIT reference library
reads its context into a REPL variable too.

IRIS does not have to. A context that is a global, a table or a result set, with
the model's slicing running against the database, removes that ceiling entirely,
and is the one thing this platform can do that no Python RLM can.

We have this working outside `%AI.*` today, over SQL extents and schema-less
globals, which is what makes us confident it is worth building into the platform
rather than around it. Not part of this request; noted because a recursive agent
plus a context that lives in the database is a combination nobody else can ship.

## 12. Open questions

1. **Does `ai-hub-eap#26` still reproduce?** The single most valuable answer here,
   and AC-1 settles it.
2. **Is there any depth guard we have missed** — in `%AI.Agent`, `ToolManager`, or
   the runtime — that `USER_GUIDE.md` does not document?
3. **What is `%AI.Agent.SubAgent.Create`'s third parameter?** Every sample passes
   `""` with "No additional config for now". If it takes a toolset, part of §9 is
   already satisfied and undocumented.
4. **`CreateSubAgent()` vs `%AI.Agent.SubAgent.Create()`** — two spellings appear
   across the guide and the samples. Are both supported, and is one preferred?
5. **Is a parallel map / fan-out operator planned, and would it support nesting** —
   a child that itself maps? Nothing by that description appears in the shipped
   distribution.
6. **Does the planned core trajectory record carry depth or parent?**
7. **How are license slots accounted for concurrent children** — per agent
   instance, per session, or per process? AC-13 is written against instance count
   because we do not know.
8. **Is context offloading planned, and would it interact with depth?** A child
   receiving a handle rather than a copy would make deep trees far cheaper.

## 13. What we are asking for

Not a commitment to all thirteen. Concretely, and in order:

1. **Confirm or refute §9** by running AC-1 on a current build. That is one
   afternoon and it decides whether the rest of this is a design conversation or a
   bug fix plus a design conversation.
2. **Tell us whether FR-1 and FR-2 are already possible** under names or
   mechanisms `USER_GUIDE.md` does not cover. Two of our three P0s may be
   documentation rather than code.
3. **A view on FR-8.** It is the cheapest item here and the one with the largest
   downstream consequence, and we would like to know whether it is contentious
   before arguing for it further.

We are happy to write and contribute the ObjectScript samples in FR-4, FR-12 and
FR-13 if that is useful — they are the parts we can do from outside the platform.
