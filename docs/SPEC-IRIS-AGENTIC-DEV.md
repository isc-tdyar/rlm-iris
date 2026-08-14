# Spec: a minimal agent layer for stock IRIS

**For:** `iris-agentic-dev`
**From:** work in `rlm-iris`
**Date:** 2026-08-12
**Status:** Draft. Written without access to the target repo, so reconcile the
layout against what is already there.

## Why

Three things block the recursive sub-agent work, and all three come from the same
place: `%AI.*` only exists on AI Hub builds, and those are WRC-gated.

- We cannot get an image. Docker Hub publishes `intersystems/iris-community`
  through 2026.2 with no AI-suffixed tag; the AI builds come from
  `containers.intersystems.com`, and a licence for one expired before we could
  test with it.
- We cannot put it in CI. Anything depending on `%AI.*` is untestable on a
  runner, which means the interesting half of the design has no regression tests.
- We cannot demonstrate the ask. `docs/ER-AIHUB-RECURSIVE-SUBAGENTS.md` asks the
  AI Hub team for bounded recursion, a tree-spanning trace, and tool arguments
  the model cannot see. A request is weaker than a working implementation.

So build the minimum on stock IRIS. Not a competitor to AI Hub, and not a fork of
it: the smallest agent layer that makes the pattern real, so we can run it today,
test it in CI, and hand the team something to look at instead of a document.

The bet is that all three asks are buildable in ObjectScript on a community
image. Nothing in them needs the Rust bridge, a provider SDK, or anything
`%Net.HttpRequest` cannot do.

## Scope

**In.** An agent that runs a bounded tool loop against an OpenAI-compatible
endpoint, tools declared as ObjectScript classes with schemas derived from class
metadata, sub-agents with a platform-enforced depth ceiling, one trace spanning
the whole tree, and tool arguments excluded from the schema the model sees.

**Out, deliberately.** RAG and vector stores, an MCP server, multimodal, token
streaming, a policy framework beyond a single authorization hook, anything
requiring the Rust bridge. AI Hub does all of these and does them better. The
value here is the recursion primitive, not a second platform.

**Also out:** matching `%AI.*` signatures. Do not shadow those names or mimic
their shapes. The point is a design that can be *compared* with AI Hub's, and
retired when AI Hub grows the same capability. Use an `Agentic.*` package and
expect to delete it.

## Dependencies

None. Do not depend on `rlm-iris`.

That is worth stating because the temptation is real: `rlm-core` already has an
LLM abstraction (`RLM.LLM`, with a REST implementation and a scripted stub), a
trajectory record (`RLM.Trace`), and call accounting (`RLM.Budget`), all with no
`%AI.*` dependency. Reusing them would save perhaps a week.

Don't. `rlm-core` carries sources, lenses, policies and an evaluation harness
that an agent layer has no business dragging in, and the coupling would run the
wrong way. Build the four small classes independently and let `rlm-iris` depend
on *this* repo later if it wants to.

## What to build

### A0 — Provider and one-shot completion

`Agentic.Provider` over `%Net.HttpRequest` to any OpenAI-compatible endpoint.
Chat completions only. Config from environment variables or a settings global,
resolved in a documented precedence order.

Small, and mostly a known quantity: `RLM.LLM.REST` in `rlm-iris` is about 150
lines and does exactly this, including the detail worth copying — it refuses a
completion whose `finish_reason` is `length`, because half a sentence accepted as
an answer becomes a finding in a report.

Ship a scripted stub alongside it from day one. Every test below should run with
no network and no key.

### A1 — Tools and the loop

The substantial one.

**Tool declaration.** A tool is a class extending `Agentic.Tool` with an
`Execute` method. Its JSON Schema is derived from the compiled method signature
and the class comment, not hand-written. `%Dictionary.CompiledMethod.FormalSpec`
carries the parameter list in the dictionary's own encoding
(`name:type=default,...`); `UnitTest.RLMAIHub.AgentProbe` in `rlm-iris` already
reads it, so the mechanism is proven even though the generator is not.

Expect this to be the fiddliest part of the milestone. Type mapping is where it
gets awkward: `%String`/`%Integer`/`%Boolean` are obvious, `%DynamicObject` is
`object` with no properties, and a class-typed parameter has no honest JSON
representation, so refuse it at registration rather than emitting something
lossy. A tool that cannot be described should fail to register, loudly.

**The loop.** Prompt, dispatch any tool calls, feed results back, repeat until
the model returns no tool call or a bound trips. Bounds:

- `MaxTurns` on the agent — the outer loop.
- `MaxToolCalls` per turn.
- `TimeoutMs` for the whole run, checked once per turn.

Copy AI Hub's loop detection if it is cheap: after each round, if the tool calls
and their results repeat without new information, nudge once and then fail with a
distinguishable error. Their guide's claim that an unbounded inner cap is safe
*because* loop detection is always on is a good design and worth having.

### A2 — Sub-agents with an enforced ceiling

The reason the repo exists.

```objectscript
Set child = parent.CreateSubAgent("You are a specialist.")
Do child.Tools.Add(##class(MyApp.Tools.Delegate).%New())   // children may hold tools
Set result = child.Run(child.NewSession(), task)
```

Requirements, and each is something AI Hub does not do today:

1. **`Depth` is set by the platform**, readable by the child, never threaded
   through a prompt. A convention that a caller can forget is not a bound.
2. **`MaxDepth` is enforced**, with a finite default. Suggest 3.
3. **Behaviour at the ceiling is selectable** — refuse with a distinguishable
   error, or degrade to a plain completion. Refuse is the default.
4. **A child inherits the *remaining* budget**, not a fresh copy. This is the one
   that matters most and the easiest to get wrong: if `TimeoutMs` and turn counts
   reset per child, then every guard multiplies with depth instead of bounding
   the tree, which is exactly the failure documented in the AI Hub request.
5. **Slot and resource release on every exit path**: completion, failure,
   cancellation, timeout, ceiling refusal.

Tests to write first, because they are the deliverable:

- A three-level tree, every level holding a tool, returns the leaf's result to the
  root.
- A self-delegating tool with `MaxDepth = 2` stops at the third level with a
  distinct error and the run completes.
- A parent with `TimeoutMs = 5000` that spawns children does not exceed 5s total.
- One child of twenty throws; the parent gets nineteen results and one failure,
  and can tell which is which.

### A3 — One trace over the tree

Every entry carries **depth** and **parent**, so the call graph reconstructs
without inferring from timestamps. Persist to a global; `%Persistent` if a
queryable trace is wanted, which it probably is.

Per entry: role, depth, parent, agent id, tool name, model, tokens in and out,
duration, error. Prompt and completion text in a sidecar rather than the row, so
the row stays a fixed shape and a reader can enumerate structure without pulling
megabytes.

**OTel export.** ObjectScript has no OTel SDK, so the pragmatic route is Embedded
Python and `opentelemetry-sdk`, emitting OTLP/gRPC. One span per agent run, one
per tool call, one per model call, with sub-agent spans nested under their
parent's — because span nesting *is* the depth dimension, and a trace you cannot
separate by level cannot be filtered or credited.

Worth checking before building: AI Hub already ships OTel for `iris-mcp-server`
(`telemetry = true`, `OTEL_EXPORTER_OTLP_ENDPOINT`, OTLP/gRPC). If that machinery
is reachable from ObjectScript, use it instead of a second exporter.

### A4 — Tool arguments the model cannot see

Python's `iris_llm` has `RunContext[T]`, whose parameters are *"excluded from the
LLM tool schema"*. ObjectScript has no equivalent, so a tool needing a slice
predicate, a tenant id or a row cap must either take it as a model-visible
argument — where the model can rewrite it — or hold it as instance state.

Mark a parameter or property as caller-supplied and omit it from the generated
schema while still passing it at dispatch. A keyword on the property is probably
the cleanest:

```objectscript
Property Scope As %String [ Agentic.Hidden ];
```

Small once A1's generator exists, and it is the difference between a scoped tool
call and a suggestion.

### A5 — Fan-out

Sibling children running concurrently, width decided at runtime. Lowest priority
of the five: everything above is correctness, this is throughput.

Non-obvious in ObjectScript, and worth timeboxing before committing. `JOB` gives
separate processes with no shared memory, so results come back through a global
and each child needs its own licence slot. Whether that is cheaper than
sequential depends on how long a child takes, and the honest answer may be that
it is not worth it below some fan-out width. Measure before building.

## Proving it

Two things, and the second is the one that changes the conversation.

**In CI.** The whole suite runs on `intersystems/iris-community:latest-em` with a
scripted provider, no network and no key. Depth, budget inheritance, schema
generation and trace shape are all testable without a model. That alone is more
regression coverage than the AI Hub path can have today.

**Against the real workload.** Point it at `rlm-iris`. `RLM.Engine` currently does
its own traversal over an explicit stack; with A2 in place it can spawn actual
sub-agents, which closes the gap between what the request asks the platform for
and what we do ourselves. Then the RL loop in
`rlm-iris/docs/rl-loop` has something to run against on a stock image.

## What this does to the AI Hub request

It reverses its posture. Today it says "we need three things." With this repo
working it says "here are the three things, built on a community image, with
tests; here is what they cost us; absorb them or tell us why the shape is wrong."

Every class here should be written expecting to be deleted. When AI Hub grows
bounded recursion, `Agentic.Agent` becomes a thin adapter and then nothing. Design
for that: keep the surface small, keep the seams where AI Hub's are, and do not
accumulate features that would make the retirement painful.

## Sizing

A0 and A1 are the bulk of it; A1's schema generator is the piece most likely to
run long. A2 is small once A1 exists and is where the value is, so an honest
sequence is A0 → A1 → A2 and then reassess, since A2 is the point at which the
request can be rewritten.

A3 is independent of A2 and could go in parallel if two people are on it. A4 is
an afternoon once A1 is done. A5 should be timeboxed and abandoned if `JOB` makes
it ugly.
