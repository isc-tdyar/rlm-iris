# Recursive sub-agents in AI Hub

Tom Dyar · 2026-08-12 · against `ai-core` @ `994c8f1`

We need three things from the platform: bound the recursion, trace the whole
tree, and let a tool take an argument the model can't see. Without them a
recursive sub-agent system runs, but you can't train it. Two of the three
already have answers on the Python side, so some of this is parity rather than
new work. Detail below; design is yours.

We wrote the pattern out as if it already worked, so you can read the shape
rather than our description of it. Every line marked NOT TODAY is somewhere the
platform has no equivalent, with a comment saying what we do instead:
[Delegate.cls](https://github.com/isc-tdyar/rlm-iris/blob/claude/paper-relevance-rlm-kq3l7p/docs/aihub-wanted/Delegate.cls) is the recursive tool,
[Run.cls](https://github.com/isc-tdyar/rlm-iris/blob/claude/paper-relevance-rlm-kq3l7p/docs/aihub-wanted/Run.cls) drives it and covers the trace and
fan-out. Neither compiles; both live outside `src/`.

## What we're building

Recursive decomposition of IRIS stores that can't be exported: a 400M-row
`Ens.MessageHeader` under an SLA, a PHI-bearing clinical extent, a 40 GB global
with no schema. Split the store, characterize each slice, split the interesting
ones again, and let the model reason over bounded summaries at the top and actual
records at the bottom, once the slices are small enough to read.

It works today outside `%AI.*` -- the engine is
[RLM.Engine](https://github.com/isc-tdyar/rlm-iris/blob/claude/paper-relevance-rlm-kq3l7p/src/RLM/Engine.cls), about 500 lines, and the sources it runs
over are [here](https://github.com/isc-tdyar/rlm-iris/blob/claude/paper-relevance-rlm-kq3l7p/src/RLM/Source). We want it on AI Hub so it inherits the provider,
the authorization and audit policies, and the trajectory record, and so it's a
platform capability rather than our library.

## What the platform needs to add

**Bound the recursion.** `CreateSubAgent()` returns a full agent, a full agent
takes tools, and a delegation tool is an ordinary `%AI.Tool`. So an agent can hold
the tool that spawns agents, and nothing stops it. `MaxIterations` is inherited,
`max_iterations` and `timeout_ms` live on a session the child creates fresh, and
loop detection only looks inside one conversation. Every guard is per-agent, so
recursion multiplies them instead of bounding them.

The shipped `DelegateTask` gives its child no tools, so the sample stops at one
level. Adding the documented line that gives a sub-agent a tool is all it takes:

```objectscript
Set child = ..ParentAgent.CreateSubAgent("You are a specialist. Delegate further if useful.")
Set t = ##class(MyApp.Tools.Delegate).%New()
Set t.ParentAgent = child
Do child.ToolManager.AddTool(t)        // the child can now delegate too
```

We need a depth ceiling the platform enforces, and a child that can read its own
depth without the parent putting it in a prompt. Whether the ceiling refuses or
degrades to a plain completion, we don't mind, as long as it isn't silent.

**Trace the whole tree.** This is the one we care most about. A trajectory you
can't separate by level can't be filtered, credited, or learned from. With it, a
finished run becomes a dataset you score offline instead of re-running, which the
Python-REPL agents structurally can't do, because their traces depend on code the
model wrote.

You already ship OTel for `iris-mcp-server` (`telemetry = true`, OTLP/gRPC). We
haven't seen what it emits, so these are questions rather than a request:

- Does it cover `%AI.Agent` running in-process, or only calls crossing the MCP
  boundary?
- When an agent spawns a sub-agent, is that a child span?
- Do model calls carry token counts and model id?

Three yeses and we need nothing here, because span nesting gives us the depth
dimension. If it's MCP-only, extending it to in-process agents is the ask, and
sub-agents nesting under their parent is the part that matters.

For what the trace feeds, [docs/rl-loop](https://github.com/isc-tdyar/rlm-iris/blob/claude/paper-relevance-rlm-kq3l7p/docs/rl-loop) has the other end of
the flow written out: the decomposition served to an agent as MCP tools, a
`verifiers` taskset whose reward is a query against IRIS rather than a judge
model, and the prime-rl config that trains on it. The reward is free because a
peek is a pure function of the store, so after a run finishes we can price every
dimension the run *didn't* choose. That is the payoff the depth tag unlocks.

**Let a tool take an argument the model can't see.** Python has `RunContext[T]`,
excluded from the tool schema. ObjectScript has no equivalent, so a tool that
needs a slice predicate, a tenant id or a row cap must either accept it as a
model-visible argument, where the model can rewrite it, or hold it as instance
state, which your own shell-tool docs warn is fragile behind a job pool. For us
that argument is a security boundary.

## The ObjectScript surface is behind the Python one

`iris_llm` already ships `RunContext[T]`, and `python/advanced/runcontext_example.py`
documents it as context parameters excluded from the LLM schema. That is the
hidden argument above, in Python, today.

The rest of the gap is in the RLM samples. The Python one, `python/rlm/toolset.py`,
which we contributed, has a variable namespace persisted across calls
(`store_var`, `get_var`, `peek_var`, `search_var`, `summarize_var`), a
`spawn_subagent` with a sub-call counter and a stage trace, and an
`execute_python` that runs in-process against `import iris` behind a builtins
allowlist and a timeout. The ObjectScript sample has five tools over a `%String`
searched by substring, and `RLMBridge` shells out to the Python one with
`$ZF(-100)`.

We are not asking you to port `execute_python`. It works in Python only because
`exec` is free there, and the ObjectScript equivalent is `XECUTE`, which is not
something to hand a model. The point is narrower: an ObjectScript agent has no
in-process way to do what the Python agent does, so it leaves the process to get
it.

Two questions we can't answer without a build:

- Can a `%AI.Tool` method be `[ Language = python ]` and still be discovered
  with a correct schema? No sample class in the bundle uses it and the guide
  never mentions embedded Python, so nothing shows either way.
- If it can, does `import iris` inside it see the calling process's session
  state?

Two yeses and the gap mostly closes with no new primitive, and `RLMBridge`'s
shell-out is a defect rather than a design.

## One thing to check first

`ai-hub-eap#26`, and we're paraphrasing, so please check this against the issue: a
`%AI.Tool` that spawns a child agent never returns when the parent's loop
dispatches it, and only when the child has tools attached, and it leaks license
slots. We last saw it on 2026.3.0AI Build 126U.

Build 121 fixed the equivalent Python panic and `DelegateTask` cites
`safe_block_on`, so it may already be gone. But no shipped ObjectScript sample
attaches a tool to a child, so nothing demonstrates it either way. Everything
above assumes this works, so settle it first.

## Smaller things

Fan-out is sequential. The guide says so, and `ParallelDelegation()`'s own comment
disclaims its name. Not blocking, but decomposition is about examining many slices
per decision.

We're happy to bring the ObjectScript RLM sample up to the Python one ourselves
if that's useful. It's the part we can do from outside the platform.

We also have a read-only probe that dumps the live `%AI.*` surface with full
signatures. It reads the dictionary, calls nothing, and can't hang. Say the word
and it's yours.
