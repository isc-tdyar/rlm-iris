# AI Hub surface survey

Read exhaustively from the `ai-core` sample distribution @ `994c8f1` (2026-08-07):
96 files, 21,300 lines — `MCP_SERVER_GUIDE.md` (1,452), `objectscript/USER_GUIDE.md`
(4,380), `python/PYTHON_USER_GUIDE.md` (3,618), 40 `.cls`, 32 `.py`, and the test tree.

Written down because three separate drafts of
[ER-AIHUB-RECURSIVE-SUBAGENTS.md](ER-AIHUB-RECURSIVE-SUBAGENTS.md) each asked for
something that already shipped. The corpus is small enough to read completely, so
this records what is actually there.

Everything below is from the distribution, not from a running instance.
`UnitTest.RLMAIHub.AgentProbe` reports the live surface — see
[AIHUB-PROBE-RUNBOOK.md](AIHUB-PROBE-RUNBOOK.md).

## 1. Complete `%AI.*` inventory

Every symbol appearing anywhere in the corpus, by mention count:

| Class | n | Class | n |
|---|---|---|---|
| `%AI.Agent` | 75 | `%AI.RAG.Embedding` | 7 |
| `%AI.Provider` | 67 | `%AI.RAG.Embedding.FastEmbed` | 7 |
| `%AI.ToolSet` | 32 | `%AI.Policy.ConsoleAudit` | 7 |
| `%AI.Tool` | 27 | `%AI.LLM.Response` | 7 |
| `%AI.LLM.ContentPart` | 26 | `%AI.Catalog` | 7 |
| `%AI.System` | 22 | `%AI.RAG.Embedding.OpenAI` | 6 |
| `%AI.Tools.SQL` | 20 | `%AI.Policy.Audit` | 6 |
| `%AI.MCP.Service` | 14 | `%AI.Agent.SubAgent` | 6 |
| `%AI.Agent.Session` | 14 | `%AI.ToolMgr` | 5 |
| `%AI.Policy.Authorization` | 11 | `%AI.Policy.ConsoleAuth` | 4 |
| `%AI.RAG.KnowledgeBase` | 10 | `%AI.Tool.Schema` | 3 |
| `%AI.RAG.VectorStore.IRIS` | 9 | `%AI.System.StreamRenderer` | 3 |
| `%AI.Agent.Skill` | 9 | `%AI.Shell.ConsoleAgent` | 2 |
| `%AI.Skills.Planning` | 8 | `%AI.Utils.SettingStore` | 1 |
| `%AI.Policy.Discovery` | 8 | `%AI.LLM.CompletionOptions` | 1 |
| `%AI.Tools.FileSystem` | 7 | `%AI.Shell.Console` | 1 |

## 2. Three names with no provenance in this distribution

`rg` over the entire corpus returns **zero** mentions of `%AI.Op` / `%AI.Op.Map`,
`%AI.Env`, or `%AI.Context.Store`.

Where they came from matters, because an earlier draft of this file described
them as an "announced surface", which was unsupported. They entered in `7465e3c`
(2026-07-25, the scaffold commit) alongside a reference to an "AI Hub harness
spec" that no one has been able to produce — so the names are best read as
**our own proposals**, never adopted by anyone, rather than as anything
InterSystems published. Both references have since been removed from SPEC.

This is therefore not evidence that AI Hub is missing something. It is evidence
that a wish list was written down as though it were a schedule. SPEC §6 is now
grouped by what is verifiable, and the probe's `Interesting()` list still carries
the three names so that a live run records their absence as an observation — and
resolves it immediately if one of them does turn out to exist.

## 3. Python / ObjectScript parity

Mention counts across each tree, then verified by reading.

| Capability | Python | ObjectScript | Note |
|---|---:|---:|---|
| Sub-agent creation | ✅ `create_child_agent` | ✅ `CreateSubAgent` | Both real |
| Child may hold tools | ✅ | ✅ | OS documented at USER_GUIDE §Sub-Agents Method 2 |
| Recursion in the RLM toolset | ✅ `spawn_subagent` | ❌ | See §4 |
| `max_depth` | ✅ validated, tested | ❌ | See §5 |
| **`RunContext[T]` / `deps`** | ✅ 40/54 refs | ❌ **0** | See §6 |
| **`ModelRetry`** | ✅ 36 refs | ❌ **0** | Output validation with retry |
| **Structured output** | ✅ 41 refs | ❌ **0** | Typed/validated returns |
| Retry generally | 81 refs | 1 ref | |
| `fork()` | ✅ agent-level | ⚠️ session-level only | Different objects |
| Checkpoints | ✅ | ✅ | `AddCheckpoint`/`Restore`/`List`/`Remove` |
| Concurrency | ✅ `fork()` + `asyncio.gather` | ❌ | "Nested calls are sequential" |

An `Agent` instance cannot have two runs in flight — *"a second call while one is
already running on the same instance raises an error immediately"* — so Python's
concurrency story is `fork()` per task. ObjectScript's `Fork()` is on
`%AI.Agent.Session`, a deep copy of conversation state, not an agent.

## 4. The two RLM toolsets are not the same thing

| | Python `RLMToolSet` | ObjectScript `Sample.AI.Tools.RLM` |
|---|---|---|
| Inspect | `peek_context` | `inspect_context` |
| Search | `search_context` | `search_context` |
| Variables | `store_var`, `peek_var`, `search_var` | — (`store_note` appends to a list) |
| **Recursion** | **`spawn_subagent`** | **absent** |
| Finalize | `finalize` | `finalize` |

The ObjectScript one is context search with a notes list — no sub-call, no
variable namespace, which are two of the four primitives the RLM formulation
needs. `Sample.AI.Examples.RLMBridge` is the acknowledgement: its whole body is
`$ZF(-100, "/bin/sh", "-lc", "... python python/rlm/run_rlm_demo.py ...")`.

Both bind context by RAM — `Property Context As %String(MAXLEN = "")` on one side,
process memory on the other.

## 5. Depth is bounded in an example, not in the platform

`python/rlm/` has a complete depth model: `DEFAULT_MAX_DEPTH = 5`,
`MIN_MAX_DEPTH = 1`, `MAX_MAX_DEPTH = 8`, range-validated on construction,
`current_depth` incremented per spawn, enforced at two sites (`toolset.py:542`
truncates, `:654` errors), covered by `test_max_depth_prevents_spawn`.

`grep -niE 'max.?depth|depth limit|recursion limit'` over `objectscript/` returns
**nothing** — the only "depth" hits anywhere in the ObjectScript tree are
"defence-in-depth" security phrasing.

The platform has four guards, all scoped to a single agent's loop:

| Guard | Scope | Default |
|---|---|---|
| `%AI.Agent.MaxIterations` | outer `Run()` turns | 10 |
| `max_iterations` (session) | inner tool rounds per `Chat()` | 10, `0` disables |
| `timeout_ms` (session) | wall clock for the loop | none |
| Loop detection | always on; nudge, then `LoopDetected` | n/a |

Under recursion each one gets *weaker*: `MaxIterations` is inherited so every
level gets a fresh allowance; `max_iterations` and `timeout_ms` live on a session
and a child calls `CreateSession()` for its own; loop detection watches for
repetition within one conversation, and each level is a distinct agent making a
legitimately different call. This is the ER's primary ask.

## 6. `RunContext` is the one absence that matters most here

Python tools may take a `RunContext[T]` parameter carrying per-request data, and
*"`RunContext[T]` parameters are **excluded** from the LLM tool schema"* — the
model cannot see it and cannot author it. That is `rlm-core`'s Constitution II
implemented at the platform level.

It has no ObjectScript equivalent. Any ObjectScript tool needing a slice
predicate, a source handle or a tenant id must either accept it as a model-visible
argument or hold it as instance state on a stateful tool. Worth adding to the ER.

## 7. What already agrees with `rlm-core`

Recorded so it is not asked for.

**Caps reported, never hidden.** Every `<Query>` tool returns
`{"rows": [...], "row_count": 25, "truncated": false, "elapsed_ms": 12}`, and the
guide says *"`truncated: true` means the result was capped by the row limit. The
LLM can use this as a signal to narrow the query."* Row caps come from `MaxRows`
per query or `QUERYMAXROWS` per class (default 100). This is Constitution II,
independently derived, and it maps directly onto `RLM.Source.Materialize`'s
`truncated` output.

**Policy inheritance to children**, with a rationale worth quoting: *"a sub-agent
is an implementation detail of a tool the parent chose to use, not something
separately configured, so a policy restricting the parent's tool access extends to
its sub-agents too."*

**A governance surface**: `SetAuthPolicy`, `SetAuditPolicy`, `REQUIRESAUTH`,
URI-addressed tools (`iris:`, `rust:`, `mcp:stdio:`, `mcp:remote:`), and a
`%AI.Policy.Discovery` whose `%Resolve()` filters the catalog before the LLM sees
it — though that one is flagged **"currently experimental and may change or be
removed without a deprecation period"** (`MCP_SERVER_GUIDE.md:611`), so it is not
something to build on yet.

**Compaction** (`AutoCompactOnTokenLimit`), **persistent sessions**
(`%AI.Agent.Session` is `%Persistent`, incremental `%Save()`), **checkpoints**, and
**iteration callbacks** exposing `current_context_tokens`.

## 8. Two capabilities worth a second look for `rlm-iris`

**`%AI.RAG.VectorStore.IRIS` persists vectors in an IRIS SQL table**, with
`%AI.RAG.Embedding.FastEmbed` running AllMiniLML6V2 in-process through the Rust
bridge — 384-dimensional, no external dependency, no API key. A vector store that
lives in IRIS is a candidate `RLM.Source`: `Dimensions()` over metadata,
`Peek()` over cluster statistics, and `Materialize()` returning nearest neighbours.

**`%AI.MCP.Service` plus `iris-mcp-server` publishes IRIS tools over MCP**, with
per-endpoint tool namespacing (`/mcp/myapp` → `mcp_myapp_GetCustomer`), a
background refresh loop (default 5m, 304-aware, per-tool hash diffing, emitting
`tools/list_changed`), and optional smart discovery — fastembed cosine similarity
over tool descriptions rather than exact-name matching.

That is a route this repository has not considered: publishing an `RLM.Source` as
MCP tools so an *external* agent — Claude Code, Prime Agent, anything speaking MCP
— decomposes an IRIS store it cannot see, with authorization and audit still
enforced by IRIS. The bounded-peek contract and the `truncated` envelope both
already fit.

## 9. Consequences for this repository

1. **SPEC §6 needs a caveat** — three of its planned arrivals are absent here.
2. **The ER gains a requirement**: a `RunContext` equivalent for ObjectScript (§6).
3. **The ER's §7 list grows**: `%AI.Policy.Discovery` is experimental, so the
   governance story should not lean on it.
4. **`Materialize()` and the `<Query>` envelope agree** — if `Table.Materialize`
   ever delegates to a `<Query>` tool, `truncated` maps one-to-one.
5. **An MCP-published source is a real option**, and cheaper than the
   `prime-agent-iris` port considered earlier.
