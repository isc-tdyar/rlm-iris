# Upgrade plan: the AI Hub Python RLM sample

Review of `python/rlm/` in `ai-core` @ `994c8f1`, ranked by impact against effort.

The finding that organizes everything below: **`python/rlm/` imports four symbols
from `iris_llm`** — `Agent`, `Provider`, `ToolSet`, `tool` — while the package also
exports `RunContext`, `ModelRetry`, `ValidationError`, `run_structured`,
`run_async`, `ModelSettings`, `Capability`, `configure`, `get_default_model`, three
policy base classes, and the `rag`, `structured`, `validation`, `content` and
`utils` submodules. Most items here replace something hand-rolled with something
already in the box.

Credit where due, and it matters for reading the rest: the sample is the only
place in the whole distribution with a real depth model (range-validated 1–8,
incremented per spawn, enforced at two sites, unit-tested), it uses
`create_child_agent` correctly with the tokio rationale documented, it gives
children the toolset so recursion is genuine, and it removed the thread-pool
workaround *and asserts it stays removed*. The ObjectScript RLM sample has none of
that. Several items below are marked non-production in the README already; they
are listed because "what production needs" is a useful thing to have written down,
not because the labelling is wrong.

## Ranking

| # | Change | Impact | Effort | Risk |
|---|---|---|---|---|
| 1 | Semantic `search_context` via `iris_llm.rag` | **High** | S–M | Low |
| 2 | Stop swallowing persistence failures | **High** | XS | None |
| 3 | `context_slice` → `context_var` | **High** | S | Low |
| 4 | Policy-based de-identification | **High** | M | Med |
| 5 | `run_structured` for `finalize` | Med–High | M | Low |
| 6 | Grounding validation via `ModelRetry` | Med–High | M | Low |
| 7 | Parallel children via `fork()` + `run_async` | Med | M | Med |
| 8 | Replace `^RLM.Session` with `%AI.Agent.Session` | Med | M–L | Med |
| 9 | Replace the heuristic scorers | Med | M | Low |
| 10 | Un-monkey-patch the four helpers | Low | XS | None |
| 11 | `RunContext` for plumbing | Low–Med | S | Low |
| 12 | `get_api_key`, `get_default_model`, `ModelSettings`, `Capability` | Low | XS | None |

Items 1–3 are the ones I would do first: together they are perhaps half a day and
they fix the sample's single largest correctness gap, a silent-failure class, and
an authoring surface.

---

## 1. `search_context` is keyword matching — `iris_llm.rag` ships the real thing

`toolset.py:248`. The docstring says *"Semantic search within the context."* Once
the optional adapter is absent, the implementation is:

```python
score = sum(1 for word in query_lower.split() if word in chunk.lower())
```

Bag-of-words occurrence counting over 1000-character chunks, sorted by count. The
tell is three lines above:

```python
try:
    from iris_vector_rag.storage import IRISVectorStore  # noqa: F401
    mode = "semantic-intended-keyword-fallback"
except ImportError:
    pass
```

`IRISVectorStore` is imported to set a *label* and never used — the `noqa: F401`
says so — and the mode string carries the apology into the tool output the model
reads.

`iris_llm.rag` ships this in-process, no API key, no external dependency:

```python
from iris_llm.rag import KnowledgeBase, FastEmbedProvider, InMemoryStore

self._kb = KnowledgeBase(
    embedding=FastEmbedProvider(),      # AllMiniLML6V2, 384-dim, Rust bridge
    store=InMemoryStore(),
)
self._kb.add_documents(self._chunk_context(1000))
...
hits = self._kb.search(query, top_k=top_k)
```

**Why first.** An RLM's entire claim is finding the relevant slice of a context too
large to read. On OOLONG-style tasks — one large block, answer scattered, heavy
paraphrase — a keyword scorer misses any slice that does not reuse the query's
words, which is most of them. Every downstream stage inherits that miss, and no
amount of good decomposition recovers a slice that was never retrieved.

Keep the `semantic_search_fn` adapter hook; make the *default* semantic instead of
the fallback. Drop `iris_vector_rag`.

**Effort** S–M. Index once per context load, invalidate on `_persist_context`.
Watch first-use model download (~25 MB) in the demo path.

## 2. Persistence failures are silently discarded

`toolset.py:103–133`, three times:

```python
except (ImportError, AttributeError, Exception):
    pass  # IRIS not available or not connected, use in-memory only
```

`Exception` subsumes the other two, so the tuple is redundant — but the real
problem is that this catches a genuine write failure (permissions, a bad global
reference, a full database) and discards it identically to "not running inside
IRIS". `load_session_snapshot` and `RLMAgent.resume` both depend on those writes
having happened, so a resumed session can silently be missing state that the run
believed it saved.

Separate "not in IRIS" — knowable once, at construction — from "the write failed":

```python
def __init__(self, ...):
    try:
        import iris
        self._iris = iris
    except ImportError:
        self._iris = None
        logger.info("IRIS not available; RLM session state is in-memory only")

def _persist_var(self, name: str, value: str) -> bool:
    if self._iris is None:
        return False
    try:
        self._iris.gset("^RLM.Session", self.session.session_id, "vars", name, value)
        return True
    except Exception:
        logger.warning("failed to persist var %r for session %s",
                       name, self.session.session_id, exc_info=True)
        return False
```

**Effort** XS. **Risk** none — strictly more information than today.

## 3. `context_slice` is a model-authored argument

`toolset.py:641`:

```python
def spawn_subagent(self, task: str, context_slice: str = "") -> str:
```

It is in the LLM tool schema, so the model writes slice *content* into the call.

- **Cost and truncation.** The slice round-trips through the parent's output
  tokens, and a slice worth delegating is large — exactly what a completion limit
  truncates.
- **Fabrication.** Nothing checks `context_slice` against the real context. A model
  that paraphrases while copying hands its child a context that never existed, and
  the child has no way to tell.
- **It inverts the point.** The sub-agent exists so the parent need not hold the
  slice; making the parent emit it puts the slice back in the parent's output.

The fix is already in the file — `store_var` / `peek_var` / `search_var` give a
named namespace:

```python
def spawn_subagent(self, task: str, context_var: str = "") -> str:
    """context_var: name of a stored variable to hand the sub-agent.
       Omit for the full context. Use store_var to create one."""
    if context_var and context_var not in self.session.vars:
        return f"ERROR: no variable named {context_var!r}. Use list_vars."
    sub_context = self.session.vars[context_var] if context_var else self.session.context
```

One string either way — but one is a key into data the toolset owns, and the other
is data the model wrote. It also makes the natural workflow explicit:
`search_context` → `store_var` → `spawn_subagent(task, context_var=…)`.

**Effort** S. **Migration** accept both for a release, warn on `context_slice`.

## 4. De-identification is a keyword sniff plus two regexes

`toolset.py:910–923`:

```python
def _rlm_looks_healthcare_payload(self, payload):
    lowered = payload.lower()
    return any(t in lowered for t in ["patient", "encounter", "medication", "claim", "fhir"])

def _rlm_deidentify_healthcare_payload(self, payload):
    payload = re.sub(r"(?i)patient\s+name\s*[:=]\s*[^,\n]+", "Patient Name=[REDACTED]", payload)
    payload = re.sub(r"(?i)\b(name|mrn|ssn|dob)\s*[:=]\s*[^,\n]+", r"\1=[REDACTED]", payload)
    return payload
```

The README already labels this deferred, and the fail-closed behaviour on exception
is the right instinct. Two properties are worth stating anyway:

- Detection is a five-word substring check. A discharge summary that never says
  "patient" is not treated as healthcare and passes through unredacted.
- Redaction only matches `key: value`. Names in free-text clinical notes — the
  common case — are untouched.

The platform's answer is a policy. `BaseAuditPolicy` / `BaseAuthorizationPolicy`
run at the tool boundary, are configured rather than compiled in, and — per the
ObjectScript guide's rationale — extend to sub-agents automatically, which
hand-rolled redaction inside one toolset does not.

```python
from iris_llm import BaseAuditPolicy

class PHIRedactionPolicy(BaseAuditPolicy):
    def on_tool_result(self, tool_name, result): ...
```

That also removes the monkey-patching (item 10) and makes the behaviour testable
without driving a whole run.

**Effort** M. **Risk** Med — changing redaction changes what reaches the model;
keep fail-closed and add fixtures for the two gaps above before switching.

## 5. `finalize` returns prose; `run_structured` exists

`toolset.py:779` — `finalize(result: str)` sets a string and a flag, and the caller
parses prose. `iris_llm.structured` (`configure_agent_for_structured_output`,
`parse_structured_output`) and top-level `run_structured` give a typed object.

For an RLM the valuable structure is not just the answer but *what supported it*:

```python
class RLMAnswer(BaseModel):
    answer: str
    supporting_chunks: list[str]   # var names or chunk ids consulted
    unresolved: list[str]          # what the context did not settle
```

That makes synthesis auditable, which is what a long-context system is usually
asked to prove, and it gives items 6 and 9 something real to check.

**Effort** M.

## 6. Sub-agent answers are unvalidated

A child's return value is accepted as-is. `iris_llm.validation` provides
`ValidatedAgent` and `ModelRetry` — raise from a validator and the model retries
with the failure as feedback.

The right check here is grounding, and it is mechanical: every claim in a child's
answer should trace to the slice the child was given. Combined with item 5's
`supporting_chunks`, a validator can verify the cited chunks exist and that the
answer does not assert beyond them.

```python
def validate_grounded(result: RLMAnswer, ctx) -> RLMAnswer:
    unknown = [c for c in result.supporting_chunks if c not in ctx.deps.available_chunks]
    if unknown:
        raise ModelRetry(f"cited chunks that do not exist: {unknown}")
    return result
```

**Effort** M — depends on item 5.

## 7. Children run one at a time

`_spawn_subagent_internal` is sequential. The guide is explicit that an `Agent`
cannot have two runs in flight — *"a second call while one is already running on
the same instance raises an error immediately"* — and gives `fork()` as the answer
(*"deep-copy into a new independent agent"*), with `run_async` and the
`asyncio.gather` pattern in `advanced/async_agent_example.py`.

This matters more for RLM than for most agents: the academic budget model is about
batch shape per decision — many slices examined at once — and sequential children
turn a wide, shallow decomposition into a slow one. A `spawn_subagents(tasks: list)`
tool would let the model express the fan-out it already wants.

`ThreadPoolExecutor` is still imported at `toolset.py:757`, and
`test_rlm_child_agent.py` asserts it appears only in `execute_python`. With
`fork()` + `run_async` the sandbox may be the last place it is needed.

**Effort** M. **Risk** Med — concurrent children multiply token spend; keep depth
and add a width cap.

## 8. Session persistence is hand-rolled

The sample writes `^RLM.Session` globals directly. `%AI.Agent.Session` is
`%Persistent` with incremental `%Save()` (only new messages appended) and a
checkpoint API — `AddCheckpoint`, `RestoreCheckpoint`, `ListCheckpoints`,
`RemoveCheckpoint`.

Checkpoints in particular map onto something RLM wants anyway: a checkpoint before
each `spawn_subagent` gives a clean rollback when a child returns something
unusable, which is currently unrecoverable.

**Effort** M–L — the global layout is load-bearing for `load_session_snapshot`,
`resume` and `cleanup_expired_sessions`. Worth doing after items 1–3, and it
subsumes item 2 if it lands.

## 9. The quality and confidence scores are length heuristics

`agent.py:73` — `_score_answer_quality` awards points for a non-empty answer,
length ≥ 40, query-token overlap, and non-empty context. `dspy_program.py:224` —
`_confidence_score` returns 0.75 for any answer over 60 characters, 0.4 below,
0.2 if it contains "No relevant sections".

Both are honestly labelled ("simple deterministic quality scorer used by parity
gate tests"), so this is not a correctness complaint. But they feed
`evaluate_parity_gate`, and they reward exactly the failure mode you would want to
catch: a long, query-echoing, ungrounded answer scores well.

With item 5 in place the honest replacement is cheap — confidence becomes a
function of how much of the answer is grounded in cited chunks, which is
computable rather than guessed. An LLM judge is the heavier alternative.

**Effort** M — depends on item 5.

## 10. Four helpers are monkey-patched onto the class

`toolset.py:870–951` defines `_rlm_emit_stage_trace`, `_rlm_classify_payload_size`,
`_rlm_deidentify_healthcare_payload`, `_rlm_prepare_payload_for_reasoning` as
module functions taking `self`, then attaches them at import:

```python
RLMToolSet.emit_stage_trace = _rlm_emit_stage_trace
RLMToolSet.classify_payload_size = _rlm_classify_payload_size
```

They are invisible to `help(RLMToolSet)`, to IDE navigation, and to anyone reading
the class body. Unless something depends on patching them at runtime, they should
be methods. Item 4 removes two of them anyway.

**Effort** XS.

## 11. `RunContext` for the plumbing

Provider, session id and parent-agent handle are threaded as constructor arguments
and instance state. `RunContext[T]` is the platform mechanism, and its parameters
are *"excluded from the LLM tool schema"* — invisible and unforgeable rather than
merely undocumented. Worth adopting once item 3 has moved slice selection to a
variable name, since together they mean nothing the model writes reaches a tool as
data.

**Effort** S.

## 12. Small helpers already in the package

- `iris_llm.utils.get_api_key` — the sample resolves credentials itself.
- `get_default_model` — `run_rlm_demo.py` hardcodes `gpt-4o`.
- `ModelSettings` — temperature and token config, currently ad hoc.
- `Capability` — check a provider supports tools before building a toolset on them.

**Effort** XS each.

---

## Suggested sequencing

**First pass (~half a day):** 2, 3, 12 — a silent-failure class, an authoring
surface, and four one-line helper swaps. No behavioural risk.

**Second (1–2 days):** 1, then 10 — the retrieval fix is the biggest single
improvement, and the monkey-patch cleanup is free once you are in the file.

**Third:** 5 → 6 → 9 as one chain. Structured output makes grounding validation
possible, which makes an honest confidence score possible. Doing them out of order
means doing 9 twice.

**Then, as separate pieces of work:** 4 (policy-based redaction — real design, and
the README already scopes it as deferred), 7 (parallel children), 8 (session
persistence).

Cross-references: [AIHUB-SURVEY.md](AIHUB-SURVEY.md) for the full Python/ObjectScript
parity matrix, [ER-AIHUB-RECURSIVE-SUBAGENTS.md](ER-AIHUB-RECURSIVE-SUBAGENTS.md)
for the platform asks that follow from the gaps this sample works around.
