# Recursive sub-agents in AI Hub

Tom Dyar · 2026-08-12 · against `ai-core` @ `994c8f1`

## What we're building

Recursive decomposition of IRIS stores that can't be exported — a 400M-row
`Ens.MessageHeader` under an SLA, a PHI-bearing clinical extent, a 40 GB global
with no schema. Split the store, characterize each slice, split the interesting
ones again, and let the model reason over bounded summaries at the top and actual
records at the bottom, once the slices are small enough to read.

It works today outside `%AI.*`. We want it on AI Hub so it inherits the provider,
the authorization and audit policies, and the trajectory record — and so it's a
platform capability rather than our library.

## What the platform needs to add

**Bound the recursion.** `CreateSubAgent()` returns a full agent, a full agent
takes tools, and a delegation tool is an ordinary `%AI.Tool`. So an agent can
hold the tool that spawns agents, and nothing stops it. `MaxIterations` is
inherited, `max_iterations` and `timeout_ms` live on a session the child creates
fresh, and loop detection only looks inside one conversation — every guard is
per-agent, so recursion multiplies them instead of being bounded by them.

The shipped `DelegateTask` gives its child no tools, so the sample stops at one
level. Adding the documented line that gives a sub-agent a tool is all it takes:

```objectscript
Set child = ..ParentAgent.CreateSubAgent("You are a specialist. Delegate further if useful.")
Set t = ##class(MyApp.Tools.Delegate).%New()
Set t.ParentAgent = child
Do child.ToolManager.AddTool(t)        // the child can now delegate too
```

We need a depth ceiling the platform enforces and a child that can read its own
depth without the parent putting it in a prompt. Whether the ceiling refuses or
degrades to a plain completion, we don't mind — as long as it isn't silent.

**Put depth on the trajectory and on outbound calls.** This is the one we care
most about. A trajectory you can't separate by level can't be filtered, credited,
or trained on. Sessions are already `%Persistent` with per-iteration token counts;
depth is the missing dimension. `rlm-harness` sets `X-RLM-Depth` on every request
for exactly this reason.

With it, a finished run is a dataset you can score offline instead of re-running.
That's a real advantage over the Python-REPL agents — their trajectories depend on
code the model wrote, which is why `verifiers` has no offline training path at
all. A tool-call trajectory over replayable operations doesn't have that problem,
and AI Hub is a few fields away from it.

**Let a tool take an argument the model can't see.** Python has `RunContext[T]`,
excluded from the tool schema. ObjectScript has no equivalent, so a tool that
needs a slice predicate, a tenant id or a row cap must either accept it as a
model-visible argument — where the model can rewrite it — or hold it as instance
state, which your own shell-tool docs warn is fragile behind a job pool. For us
that argument is a security boundary, not a convenience.

## One thing to check first

`ai-hub-eap#26` — paraphrasing, so please check it against the issue: a `%AI.Tool`
that spawns a child agent never returns when the parent's loop dispatches it, and
only when the child has tools attached, and it leaks license slots. We last saw it
on 2026.3.0AI Build 126U.

Build 121 fixed the equivalent Python panic and `DelegateTask` cites
`safe_block_on`, so it may already be gone. But no shipped ObjectScript sample
attaches a tool to a child, so nothing demonstrates it either way. Everything
above assumes this works, so it's worth settling before the rest is worth
discussing.

## Two smaller things

Fan-out is sequential — the guide says so, and `ParallelDelegation()`'s own
comment disclaims its name. Not blocking, but the whole point of decomposition is
examining many slices per decision.

The ObjectScript RLM sample isn't recursive: no sub-call, no variable namespace,
and `RLMBridge` shells out to the Python one. We're happy to fix that sample
ourselves if it's useful — it's the part we can do from outside the platform.

## Offer

We have a read-only probe that dumps the live `%AI.*` surface with full
signatures — reads the dictionary, calls nothing, can't hang. Say the word and
it's yours.

Design is yours. We've been living with this pattern long enough to know what
we need it to do, not what it should look like.
