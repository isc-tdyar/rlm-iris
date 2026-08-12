# Notes on the AI Hub Python RLM sample

Review of `python/rlm/` in `ai-core` @ `994c8f1`, against the rest of what
`iris_llm` ships. Written as upstream feedback — every item is a primitive that
exists in the same package the sample already imports from.

## The shape of it

`python/rlm/` imports exactly four symbols from `iris_llm`:

```python
toolset.py:        from iris_llm import ToolSet, tool, Agent, Provider
agent.py:          from iris_llm import Agent, Provider
run_rlm_demo.py:   from iris_llm import Provider
langgraph/…:       from iris_llm.langchain import ChatIris, IrisTool
```

The package also exports `RunContext`, `ModelRetry`, `ValidationError`,
`run_structured`, `run_async`, `ModelSettings`, `Capability`, `configure`,
`get_default_model`, the three policy base classes, `iris_llm.rag`,
`iris_llm.structured`, `iris_llm.validation`, `iris_llm.content` and
`iris_llm.utils`. None are used.

Several of them close gaps the sample currently works around.

---

## 1. `search_context` is keyword matching, and `iris_llm.rag` ships the real thing

`toolset.py:248`. The docstring says *"Semantic search within the context"*. The
implementation, once the optional adapter is absent:

```python
score = sum(1 for word in query_lower.split() if word in chunk.lower())
```

Bag-of-words occurrence counting over 1000-character chunks, sorted by count.

The tell is three lines above it:

```python
try:
    from iris_vector_rag.storage import IRISVectorStore  # noqa: F401
    mode = "semantic-intended-keyword-fallback"
except ImportError:
    pass
```

`IRISVectorStore` is imported to set a *label* and then never used — `noqa: F401`
says so explicitly. The intent was semantic retrieval through an external
package that never got wired up, and `mode` strings (`semantic-intended-keyword-fallback`)
carry the apology into the tool output the model reads.

Meanwhile `iris_llm.rag` ships exactly this, in-process:

```python
from iris_llm.rag import KnowledgeBase, FastEmbedProvider, InMemoryStore
```

`FastEmbedProvider` runs AllMiniLML6V2 through the Rust bridge — 384-dimensional,
no external dependency, no API key, ~25 MB model fetched once. `InMemoryStore` or
`VectorStore` holds the vectors; `KnowledgeBase` chunks, embeds and indexes.

**This is the highest-value change in the file.** An RLM's entire claim is finding
the relevant slice of a context too large to read, and the shipped search is
`word in chunk`. On OOLONG-style tasks — one large block, answer scattered — a
keyword scorer will miss any slice that paraphrases the query, which is most of
them.

It also drops the `iris_vector_rag` dependency for one already in the package.

## 2. `context_slice` is a model-authored argument

`toolset.py:641`:

```python
def spawn_subagent(self, task: str, context_slice: str = "") -> str:
```

`context_slice` is in the LLM tool schema, so the model writes the slice content
into the tool call. Three consequences:

- **Cost and truncation.** The slice round-trips through the model's output
  tokens. A slice worth delegating is large, and a large slice is exactly what
  the completion limit truncates.
- **Fabrication.** Nothing checks that `context_slice` is a substring of the real
  context. A model that paraphrases while copying hands its child a context that
  never existed, and the child cannot tell.
- **It inverts the point.** The sub-agent exists so the parent does not have to
  hold the slice; making the parent emit it puts the slice back in the parent's
  output.

The toolset already has the fix in it. `store_var` / `peek_var` / `search_var`
give a named namespace, so the model can name a slice without authoring it:

```python
def spawn_subagent(self, task: str, context_var: str = "") -> str:
    """context_var: name of a stored variable to give the sub-agent.
       Defaults to the full context."""
    sub_context = self.session.vars[context_var] if context_var else self.session.context
```

The model chooses *which* slice; the toolset supplies its *content*. One string
either way, but one is a key into data the toolset owns and the other is data the
model wrote.

For the provider, session id and parent-agent handle currently threaded as
constructor arguments, `RunContext[T]` is the platform mechanism — its parameters
are *"excluded from the LLM tool schema"*, so they are invisible and unforgeable
rather than merely undocumented.

## 3. `finalize` returns a string; `run_structured` exists

`toolset.py:779` — `finalize(result: str)` sets `FinalAnswer` and a flag, and the
answer reaches the caller as prose to be parsed downstream. `iris_llm.structured`
(`configure_agent_for_structured_output`, `parse_structured_output`) and the
top-level `run_structured` give a typed, validated object instead.

For an RLM specifically, the useful structure is not just the answer: it is the
answer *plus* which slices supported it. A typed result carrying
`{answer, supporting_chunks, confidence}` makes the synthesis auditable, which is
the thing a long-context system is usually asked to prove.

## 4. Sub-agent answers are unvalidated

A child's return value is accepted as-is. `iris_llm.validation` provides
`ValidatedAgent` and `ModelRetry`: raise `ModelRetry("…")` from a validator and
the model retries with the failure as feedback, rather than the parent
synthesizing over a bad answer it cannot detect.

The natural check for this sample is grounding — every claim in a child's answer
should appear in the slice it was given. That is mechanical, and it is the failure
mode recursive summarization actually has.

## 5. Parallel sub-agents are available and unused

`_spawn_subagent_internal` runs children one at a time. The guide is explicit that
an `Agent` instance cannot have two runs in flight — *"a second call while one is
already running on the same instance raises an error immediately"* — and gives
`fork()` as the answer: *"Deep-copy into a new independent agent"*, plus
`run_async` and the `asyncio.gather` pattern from `advanced/async_agent_example.py`.

Fan-out matters more here than in most agents. The academic RLM budget model is
about batch shape per decision — many slices examined at once — and sequential
children turn a wide, shallow decomposition into a slow one.

`ThreadPoolExecutor` is still imported at `toolset.py:757`, and
`test_rlm_child_agent.py` asserts it appears only in `execute_python`. With
`fork()` + `run_async` the sandbox path may be the last place it is needed.

## 6. Smaller items

- **`iris_llm.utils.get_api_key`** exists; the sample resolves provider
  credentials itself. `Sample.AI.Utils.GetAPIKey()` is the documented pattern on
  the ObjectScript side and `get_api_key` is its counterpart.
- **`ModelSettings`** for temperature and token config, currently passed ad hoc.
- **`get_default_model`** rather than hardcoding `gpt-4o` in `run_rlm_demo.py`.
- **`Capability`** to check a provider supports tools before building a toolset
  around them.

## 7. What the sample gets right, and the ObjectScript side does not

Worth saying, because the ObjectScript RLM is the one that needs work:

- `max_depth` is range-validated (`MIN_MAX_DEPTH=1`, `DEFAULT=5`, `MAX=8`),
  incremented per spawn, enforced at two sites, and unit-tested. No ObjectScript
  equivalent exists anywhere in the distribution.
- `create_child_agent` is used correctly, with the tokio-runtime rationale
  documented and the thread-pool workaround removed and *asserted* removed.
- Sub-agents receive the toolset, so recursion is real. `DelegateTask` on the
  ObjectScript side gives its child no tools at all.
- Depth degrades gracefully at the ceiling rather than failing.

See [AIHUB-SURVEY.md](AIHUB-SURVEY.md) for the full parity matrix and
[ER-AIHUB-RECURSIVE-SUBAGENTS.md](ER-AIHUB-RECURSIVE-SUBAGENTS.md) for the
platform asks that follow from it.

## Suggested order

1. `iris_llm.rag` for `search_context` — biggest correctness win, removes an
   external dependency.
2. `context_var` instead of `context_slice` — small change, closes an authoring
   surface.
3. `fork()` + `run_async` for parallel children.
4. `run_structured` for `finalize`, `ModelRetry` for grounding checks on child
   answers.
5. The §6 tidying.
