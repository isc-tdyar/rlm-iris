# Spec 075: Recursive Decomposition Tools

> Drafted in `rlm-iris` for `intersystems-community/iris-agentic-dev`. Move to
> `specs/075-recursive-decomposition/spec.md` and renumber if 075 is taken.

## Problem

Some IRIS stores cannot be handed to an agent at all. A 400M-row
`Ens.MessageHeader` under an SLA, a PHI-bearing clinical extent, a 40 GB global
whose schema lives in a routine nobody owns. An agent asked "what is in here?"
has three options today and all of them are bad: read a sample and generalize
from it, run an aggregate it guessed at, or give up.

Sampling is the one that looks like it works. The first 50,000 nodes of a global
written to since 2009 describe 2009, and the archiving decision turns on the
decade after.

The technique that does work is recursive decomposition: split the store, look at
aggregate statistics for each slice, split the ones that are still mixed, and read
actual records only once a slice is small enough that reading it is bounded. This
is the Recursive Language Model pattern (Zhang, Kraska and Khattab,
[arXiv:2512.24601](https://arxiv.org/abs/2512.24601)), and it is what
[`rlm-iris`](https://github.com/isc-tdyar/rlm-iris) implements in ObjectScript.

`iris-agentic-dev` is a better host for it than a library is, for three reasons
that are already true of this repo:

1. **The agent already exists.** Copilot and Claude Code are the agent. There is
   no agent runtime to build, no LLM provider to wire, and no tool loop to write.
2. **It runs on stock IRIS.** 2023.1+ over `/api/atelier`. The ObjectScript
   library needs the same, but the AI-Hub-hosted version of this pattern needs a
   WRC-gated image nobody outside InterSystems can get.
3. **The governance is built.** `dispatch_gate()` already blocks bulk-PHI tools,
   matches per-global PHI name patterns, and enforces a system blocklist. A
   decomposition tool is a read against a scoped slice, which is exactly the shape
   those gates already reason about.

## Goal

Three tools that let an agent decompose a store it cannot read, plus the depth
field the telemetry already has a slot for.

## Non-goals

- No agent, sub-agent, or LLM provider in this repo. The recursion is the client
  agent calling tools; we serve the store, not the reasoning.
- No new store access. `iris_global`, `iris_query` and the interop tools already
  reach the data. This adds a *bounded aggregate* view over what they reach.
- No replacement for `iris_query`. An agent that can already write the right
  `GROUP BY` should keep doing that. These tools are for the case where it cannot,
  because it does not know the shape yet.

## User stories

**US1**: As a developer facing an undocumented 40 GB global, I want the agent to
tell me what is in it without reading it, so I can decide whether it can be
archived.

**US2**: As an SRE, I want the agent to find why interop throughput dropped on
Tuesday by narrowing from 400M messages to the failing route, without exporting
message bodies.

**US3**: As a DBA on a PHI extent, I want the agent to characterize the data while
the existing PHI gates still apply per slice, so nothing crosses a boundary the
policy would have blocked.

**US4**: As someone measuring agents, I want the trace to say which tool call
happened inside which, so a decomposition run can be scored after the fact.

## Tools

### `iris_peek`

Aggregate statistics for one slice. Never rows.

```
iris_peek(source, slice?) -> {
  n, capped, metrics: {...}, describe: "..."
}
```

`capped: true` when the count stopped at a limit, and `describe` words it as a
floor rather than a total. This is the same contract as the existing `<Query>`
envelope's `truncated` flag, and for the same reason: a model that reads a
truncated count as a total inherits the error into every downstream claim.

Cost is bounded by the walk, not the store. A 400-node global and a 400M-node one
produce a peek of about the same size.

### `iris_moves`

The complete set of legal ways to split a slice.

```
iris_moves(source, slice?) -> {
  dimensions: [ {name, label, children: [{token, label}]} ]
}
```

The agent picks a dimension from this list. It does not compose a predicate, which
is what makes US4 scoreable: at every decision there is a finite set of
alternatives, so a run can be priced against the moves it did not make.

### `iris_slice_read`

The records of a slice, once it is small enough.

```
iris_slice_read(source, slice, limit=20) -> {
  rows: [...], row_count, truncated, refused?: "reason"
}
```

Refuses a slice above the cap, and refuses one whose peek came back `capped` —
a floor of five may be five million. The refusal carries the statistics instead,
so the agent is told it is looking at a summary rather than quietly handed one.

### Sources

A source is a named, configured decomposition target: a class extent with declared
dimensions, or a global with an allowlist and a visit cap. Configured in
`.iris-agentic-dev.toml` rather than discovered, because a dimension is something
an operator chose to expose:

```toml
[[decompose.source]]
name       = "orders"
kind       = "table"
class      = "Sales.Order"
measure    = "Amount"
dimensions = ["Region", "Channel"]

[[decompose.source]]
name       = "jrnaud"
kind       = "global"
global     = "^JRNAUD"
visit_cap  = 50000
depth_cap  = 8
```

Declared rather than open is the whole security model. The agent can only name a
source someone configured and a dimension someone listed, so `dispatch_gate()` has
a finite surface to reason about instead of an arbitrary query.

## Policy

These are read tools, so tier 1. But two things need saying:

- **`iris_slice_read` is PHI-capable** and belongs on the bulk-PHI tool list.
  `iris_peek` and `iris_moves` are not: they return counts, entropies and value-
  length moments, never a field value.
- **A source is subject to the existing global blocklist.** A `kind = "global"`
  source naming `^%SYS` should fail at config load, not at call time.

That split is worth keeping. The point of the pattern is that the expensive,
sensitive call happens only at the bottom of a recursion, after the cheap ones
have narrowed it. A policy that treats all three the same throws that away.

## Telemetry

`telemetry/trace_export.rs` already emits `{from, to, via, count, ts}` and already
has this comment:

> Sentinel `from` value for a top-level tool invocation with no calling tool
> context — this feature only has tool-level granularity, not method-level
> dispatch data.

`NO_CALLER_SENTINEL` exists because there is nothing to put in `from`. A
decomposition run is exactly the thing that would populate it: `iris_slice_read`
on `region:emea/channel:web` happened *because* of an `iris_moves` on
`region:emea`, which happened because of a peek at the root.

Add to `ToolCallRecord`:

- `depth` — how deep the slice path is.
- `parent_call_id` — the call this one narrowed from.

Then `from` carries a real caller and a decomposition trace reconstructs as a
tree. That is a small change to a record that already exists, and it turns a flat
list of tool calls into something that can be scored per level.

## Why this matters beyond the tools

With the tree in the trace, a finished decomposition is a dataset. Because the
agent picked from an enumerated move list rather than composing a predicate, every
alternative it did not take can be scored afterwards by peeking it — zero model
calls, no judge, no human label. That makes this one of the cheapest RL
environments available for agentic work, and the reward is a query rather than a
model.

`rlm-iris/docs/rl-loop` has the other end written out against `verifiers` and
`prime-rl`. It is not part of this spec, but it is the reason the `depth` field is
worth more than it looks.

## Relationship to AI Hub

None, and that is the point. AI Hub has `%AI.Agent` with sub-agents, and a request
open against it for bounded recursion and a depth-tagged trace. Everything here
runs on IRIS 2023.1 with no `%AI.*` at all, because the agent is the MCP client.

If AI Hub grows in-process recursion, the two do not collide — that serves agents
running inside the database, this serves agents outside it. Some sites will want
both, and neither has to wait for the other.

## Open questions

1. **Does the `[[decompose.source]]` config belong in this repo or in IRIS?**
   Configured here is simpler and matches how connections work. Configured in IRIS
   would let a DBA own it, which is the more defensible answer for a PHI extent.
2. **Should `iris_peek` reuse `rlm-iris`'s ObjectScript sources over `/api/atelier`,
   or reimplement the walks in Rust?** Reusing means a dependency on a package
   installed in the namespace. Reimplementing means the bounded-walk and cap logic
   exists twice and can disagree.
3. **What is the smallest useful set of statistics?** `rlm-iris` returns node and
   child counts, the data/pointer split, subscript type mix, value-length moments
   and top fanout for globals; count plus min/max/mean of a measure for tables.
   That may be more than an agent needs, and each one costs walk time.
