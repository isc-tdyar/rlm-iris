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
Set src = ##class(RLM.Source.Global).%New("^CUST")
Set eng = ##class(RLM.Engine).%New(src, ##class(RLM.LLM.REST).%New())
Write eng.Report("What is the structure of this global, and where is it skewed?")
```

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

## Portability

Two IPM modules. `rlm-core` has no `%AI.*` dependency and talks to any
OpenAI-compatible endpoint over `%Net.HttpRequest`. `rlm-aihub` adds AI Hub
integration on IRIS versions that ship it.

Portable is the default, not the fallback — see [SPEC §3.1](docs/SPEC.md).

## Milestones

- [x] **M0** Engine + `RLM.LLM.REST` + `Table` source
- [x] **M1** `RLM.Policy` contract + `Greedy` baseline
- [ ] **M2** `Global` source (bounded walk, reported caps, allowlist)
- [ ] **M3** Replay + offline evaluation + `RLM.LLM.Null` CI
- [ ] **M4** `Interop` and `Audit` sources
- [ ] **M5** `rlm-aihub`

## License

MIT
