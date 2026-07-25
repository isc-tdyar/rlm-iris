# rlm-iris

Recursive-LM decomposition over **live** InterSystems IRIS stores. The model
reasons about a store it never receives a copy of.

> Status: early. The [spec](docs/SPEC.md) is settled; code lands per the
> milestones below. Not yet on OpenExchange.

## What it does

Ask a question about a store too large, too live, or too regulated to export.
`rlm-iris` decomposes it into slices, computes aggregate statistics for each
slice **inside IRIS**, and shows the model only those statistics — never rows,
never nodes, never values. Context grows with the number of slices inspected,
not with the size of the store, so a 400M-node global and a 400-node one cost
the same to characterize.

```objectscript
Set src = ##class(RLM.Source.Table).%New("Sales.Order", "Amount")
Do src.AddDimension("region", "Region")
Set eng = ##class(RLM.Engine).%New(src, ##class(RLM.LLM.REST).%New())
Write eng.Run("What drives order value, and where is it skewed?", .traceId)
```

`Run` returns the report text and sets `traceId`, which identifies the trace rows
the run wrote.

## Why not an existing RLM library

`rlms`, `dspy.RLM`, the Google ADK port and friends all start by loading the
context into their own process as a Python REPL variable. That works for a
Markdown dump. It does not work for the stores that actually need it:

|                       | REPL-based RLM             | rlm-iris                         |
| --------------------- | -------------------------- | -------------------------------- |
| Extract step          | Required                   | None — queries run in place      |
| Per-slice cost        | Full scan of a copy        | Index-answered aggregate         |
| Undocumented globals  | No schema, no entry        | First-class source               |
| Governance            | Data is a process variable | A slice is an authorizable query |
| Model's action space  | Any Python string          | Enumerated legal moves           |
| Replayable evaluation | Stateful REPL, expensive   | Pure function of the store, free |

## Choosing how to split

A policy answers one question — **which dimension divides this slice?** — and
returns a dimension name, never a list of slices. The engine computes which
dimensions are eligible and expands the chosen one into one slice per child, so
a policy never authors a name and every name resolves by construction.

That seam is what lets a statistics-only policy exist:

| Policy              | Model calls per decision | Cost instead     | Determinism |
| ------------------- | ------------------------ | ---------------- | ----------- |
| `RLM.Policy.LLM`    | 1                        | —                | Model's     |
| `RLM.Policy.Greedy` | 0                        | 1 peek per child | Total       |

`Greedy` scores each candidate as the size-weighted mean of its children's split
metrics — "if I split here, how mixed is what I am left with?" — and declines
when nothing clears a margin. Peeks are a separate budget pool from model calls,
because charging an aggregate the database answers against the same pool as a
round trip to a provider would make the cheap policy look expensive.

Measured on the two-dimension test store: **4 model calls under `LLM`, 3 under
`Greedy`**, the same slices reached and the same report structure produced. The
saved call goes back to the sub-call pool.

```objectscript
Set engine = ##class(RLM.Engine).%New(source, llm)
Set engine.Policy = ##class(RLM.Policy.Greedy).%New()   ; or omit for LLM
```

Every candidate is recorded whichever policy ran, including the arms that lost
and the ones that could not be evaluated, so a finished run can be re-scored
against the road not taken with no model call at all:

```objectscript
Set d = ##class(RLM.Trace).Decisions(traceId).GetAt(1)
Write d.Dimension, " beat ", d.Candidates.Count() - 1, " alternative(s)"
```

## How deep to go

`MaxDepth` is how many levels below the run's starting point to decompose. 1 — the
default — decides once at the root and describes each child, which is what the
engine did before recursion existed. Raise the call budget along with it: each
level multiplies the slices that want describing.

```objectscript
Set engine.MaxDepth = 2
Set engine.Budget = ##class(RLM.Budget).%New(24)
```

A slice is only divided further if the store says it is still mixed
(`ShouldSplit`), if a dimension is left that no ancestor already used, and if at
least one child can be funded. Anything the traversal did not reach is named in
the report's caveats rather than silently absent.

## Asking about part of a store

`Run` takes a third argument that confines the whole run to one slice:

```objectscript
Write engine.Run("What drives order value in EMEA?", .traceId, "region:emea")
```

It is a slice name in the ordinary grammar, not a WHERE clause. It is resolved
before any model call — a name the store does not offer returns a report stating
the refusal and costs nothing — and the scope's label follows into every heading
that names the store, so no figure in the document reads as the whole store's.

## Splitting a continuous column

A numeric column becomes a dimension by declaring its breakpoints:

```objectscript
Do src.AddBucketedDimension("amount", "Amount", $ListBuild(100, 1000))
```

Three children — `Amount < 100`, `Amount [100,1000)`, `Amount >= 1000` — with
half-open, lower-inclusive boundaries, and one range query per child rather than
one per row. Breakpoints are validated when declared, not when queried, and every
edge reaches SQL as a bound parameter.

Rows whose value is null fall in no bucket, so the children do not sum to the
parent. The report says so:

```text
- 812 row(s) of 'EMEA' fall in no bucket of 'amount' and are counted in none of
  its children.
```

To a policy the result is indistinguishable from a categorical dimension, which
is what keeps the two comparable.

## Plain or Markdown

```objectscript
Set engine.ReportStyle = "markdown"   ; or "plain", the default
```

Both carry the same figures and the same caveats; they differ only in punctuation.
A run's trace renders for a human separately, from a run id and a database, with
no live engine:

```objectscript
Do report.Fenced(##class(RLM.Report).RenderTrace(traceId))
```

Declined decisions appear with their reasons — a trace where "not decomposed" has
no reason attached is the row a reader of a short report came looking for.

## A store that is not ready to be reported on

`RLM.Source.Ready(.reason)` is concrete and returns 1, so no existing source needs
editing. A store mid-load overrides it:

```objectscript
Method Ready(Output reason As %String) As %Boolean
{
    Set reason = "the nightly load has not finished; 3 of 12 partitions are absent"
    Quit 0
}
```

The engine checks it before any model call **and before the root peek**, and returns
the reason as the report. The alternative is averaging over whichever rows happen
to be present, which produces a document that is both confident and wrong — and
a reader cannot tell it from a correct one.

## Design invariants

- **The model never authors a predicate.** Peeks enumerate the children; the
  model picks a token from that enumeration; anything else is refused. No
  injection surface.
- **Caps are reported, never hidden.** A bounded walk says
  `counted 50,000 nodes (capped); subtree is larger`. A silent truncation is
  worse than no number, because the model treats it as a total.
- **No model-authored code.** That is what keeps a peek a pure function of the
  store, which is what makes replay and offline evaluation free.
- **At most one bounded LLM round-trip per decision.** No tool loop, so no loop
  detection, no runaway budget — and with `Greedy`, no round-trip at all.
- **A synthesis slot is reserved.** A run that explores and then cannot afford to
  answer is worse than a coarse answer, so neither pool may spend the last call.
- **`Run` never throws.** An exception from a source, a policy or a provider
  becomes a report whose caveats name the failure, keeping whatever was already
  established. A caller that asked for a document gets a document.

## Portability

Two IPM modules. `rlm-core` has no `%AI.*` dependency and talks to any
OpenAI-compatible endpoint over `%Net.HttpRequest`. `rlm-aihub` adds AI Hub
integration on IRIS versions that ship it.

Portable is the default, not the fallback — see [SPEC §3.1](docs/SPEC.md).

## Milestones

- [x] **M0** Engine + `RLM.LLM.REST` + `Table` source
- [x] **M1** `RLM.Policy` contract + `Greedy` baseline
- [x] **M1.5** Recursion below the root, bucketed dimensions, Markdown reports,
      scoped runs, readiness refusal
- [ ] **M2** `Global` source (bounded walk, reported caps, allowlist)
- [ ] **M3** Replay + offline evaluation + `RLM.LLM.Null` CI
- [ ] **M4** `Interop` and `Audit` sources
- [ ] **M5** `rlm-aihub`

## License

MIT
