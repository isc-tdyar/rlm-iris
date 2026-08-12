# Feature Specification: the action space as a seam

**Feature Branch**: `009-action-space`
**Created**: 2026-08-12
**Status**: Draft
**Input**: M7 — the companion to [008](../008-lenses-and-state/spec.md). 008 made
what the model *sees* pluggable; this makes what the model *may do* pluggable.

## Why this milestone exists

`docs/SPEC.md` §5 states the package's central bargain: the model never authors
code, so a peek is a pure function of the store, so replay and counterfactual
scoring are free. "The constraint buys the evaluation story."

That is true, and it bundles four separate requirements into one rule:

| Property | Why it is needed | What actually delivers it |
| --- | --- | --- |
| **Determinism** | `RLM.Replay` | the operation is a reproducible function of stored state |
| **Enumerable moves** | `RLM.Eval.Arms` | a finite, listable set of legal moves |
| **Boundedness** | the context claim | a cap, not a ban |
| **Authorizability** | governance | something a DBA can approve in advance |

Picking a dimension from a menu satisfies all four at once, which is why it has
never been necessary to separate them. Separating them shows the bundle is
conservative in a specific, measurable way:

**Model-authored SQL is still a pure function of the store.** Record the query,
re-run it against a frozen store, get the same rows. Replay survives it. §5's
sentence — *"arbitrary `execute_python` would make replay non-deterministic"* —
is exactly right, and the word carrying the weight is **arbitrary**, not
`execute_python`. What breaks replay is side effects and non-determinism, not
authorship.

**`Eval.Arms` breaks for an unrelated reason.** Free counterfactual scoring works
because at every decision there is a finite set of dimensions the run did not
take, each re-scorable with one peek. If the model composes a query, there is no
set of arms not taken — it could have composed unboundedly many. Enumerability,
not determinism, is what `Arms` rests on.

So the two guarantees come apart, and they come apart cleanly:

> **Determinism → replay. Enumerable moves → counterfactuals.**
> A wider action space can keep the first while losing the second.

Today nothing in the package can express that distinction. `RLM.Eval.Arms` and
`RLM.Replay` both assume the enumerated action space silently, and
`RLM.Eval.Scorecard` will compare two runs without recording what either was
allowed to do. Widening the action space without first making the distinction
explicit would produce numbers that look like the current ones and mean something
different — the failure this package exists to avoid.

## What the action space is today

Not one thing, which is why it has no seam. It is spread across four places:

- `RLM.Source.Dimensions(path)` — the whitelist of moves
- `RLM.Slice` — the `dim:token[/dim:token]` grammar and the resolver that refuses
  anything not in the whitelist
- `RLM.Source.Predicate(components)` — resolved move → store predicate
- `RLM.Engine.Candidates(path)` — which moves are eligible here

`RLM.Policy` is **not** the action space. A policy answers *who chooses*; these
four answer *what may be chosen*. That distinction is the whole feature.

## Scope

In scope: **Mode 1/2** (enumerated, today's behaviour, unchanged and default) and
**Mode 3** (a structured, validated query grammar).

Out of scope, deliberately: **Mode 4**, arbitrary code execution. It forfeits
determinism and therefore replay, which is the property that distinguishes this
package from every other RLM implementation. If it is ever built it belongs in a
separate module with separate guarantees, so that nobody forfeits replay by
accident. This spec exists partly to make that boundary explicit rather than
implicit.

## User Scenarios & Testing _(mandatory)_

### User Story 1 — an existing run is unchanged (Priority: P1)

Every run that works today produces byte-identical output, spends identical
budget, and yields identical `Arms` and `Scorecard` figures.

**Why this priority**: The seam is worthless if adopting it costs the guarantees
it exists to protect. Same obligation `RLM.Lens.Stats` carried in 008.

### User Story 2 — an analyst asks something the dimensions do not express (Priority: P1)

The declared dimensions are `region` and `channel`. The question is "what drives
order value for EMEA orders above £1,000 placed in Q3?" — a conjunction over a
declared column, a range, and a date window that no single dimension offers. The
run answers it without anyone adding a dimension and recompiling.

**Why this priority**: This is the capability. Every novel decomposition today
requires a code change, which is the friction a REPL-based RLM does not have.

### User Story 3 — the evaluator refuses what it cannot honestly compute (Priority: P1)

A run under the query grammar is passed to `RLM.Eval.Arms`. It returns no scores
and a reason naming the grammar, rather than a number.

**Why this priority**: The load-bearing story. A counterfactual over an infinite
move set is not a smaller measurement, it is a different one, and silently
returning something plausible is worse than refusing.

### User Story 4 — replay still works under the wider grammar (Priority: P1)

A run under the query grammar replays against an unchanged store with zero model
calls and reproduces its report.

**Why this priority**: The claim that determinism and enumerability are separable
is only worth making if it is demonstrated.

### User Story 5 — a governed store cannot opt in by accident (Priority: P1)

A source that declares no query surface refuses the query grammar at construction,
with a reason. A PHI-bearing extent stays on enumerated moves because nobody
declared otherwise.

**Why this priority**: Same fail-closed posture as `RLM.Source.Global`'s
allowlist. An empty surface permits nothing.

### User Story 6 — a scorecard cannot silently compare across grammars (Priority: P2)

Two runs under different grammars appear in one scorecard with the grammar in a
column, and their objectives are not presented as directly comparable.

**Why this priority**: Valuable, but a reader can already be misled by other
differences; this makes one more of them visible.

## Requirements _(mandatory)_

### The seam

- **FR-001** `RLM.Grammar` is an abstract class with `Moves`, `Resolve`,
  `Enumerable`, `Deterministic` and `Kind`.
- **FR-002** `RLM.Grammar.Enumerated` reproduces today's behaviour exactly by
  delegating to `RLM.Slice`, and is the engine's default.
- **FR-003** `RLM.Slice` is **not** replaced. It remains the resolver and the
  security boundary for enumerated moves; the grammar wraps it. A second
  implementation of the refusal logic is how a name gets refused in one place and
  accepted in another.
- **FR-004** `Moves(source, path)` returns what the model is shown as its legal
  options — an enumeration for Mode 1, a *shape* (permitted columns, operators,
  bucket rules) for Mode 3.
- **FR-005** `Resolve(source, move, Output predicate, Output label)` validates and
  translates, or refuses with a reason and the grammar attached, exactly as
  `RLM.Slice.Refuse` does today.

### Honesty about what survives

- **FR-006** `Enumerable()` and `Deterministic()` are declared per grammar and
  recorded in the trace at `Begin()`.
- **FR-007** `RLM.Eval.Arms` refuses a run whose grammar is not enumerable,
  returning its existing `error` field with a reason naming the grammar. It does
  not return partial or sampled scores presented as arms.
- **FR-008** `RLM.Replay` refuses a run whose grammar is not deterministic.
- **FR-009** `RLM.Eval.Scorecard` records the grammar per row and does not merge
  objectives across grammars into a ranking.
- **FR-010** A report names the grammar when it is not the default, in the same
  place caps and budget are disclosed.

### The query grammar

- **FR-011** A move under `RLM.Grammar.Query` is a **structured object**, not
  text: a group-by target plus zero or more predicate terms, each naming a
  declared column, an operator from a fixed set, and a value.
- **FR-012** The source declares a **query surface** — permitted columns, per
  column the permitted operators, and any value domain. Absent surface means the
  grammar refuses at construction (User Story 5).
- **FR-013** Values are bound as parameters. No text a model produced reaches SQL.
- **FR-014** Operators come from a fixed set the grammar owns, never from the
  move. This is the same rule `RLM.Source.Table.Predicate` already follows for
  bucketed dimensions, widened.
- **FR-015** A composed move is subject to the same row caps, `NullCount`
  disclosure and `capped` reporting as a dimension-derived predicate. The
  widening changes which slices can be named, not what a peek may hide.
- **FR-016** A move that resolves to a slice with no rows is refused before it
  costs a model call, with the count in the reason.

### Compatibility

- **FR-017** `RLM.Source` gains **concrete** `QuerySurface()` returning empty, so
  a source written before this milestone runs unchanged and refuses the query
  grammar by construction.
- **FR-018** The lens seam is orthogonal. Any grammar composes with any lens:
  observation space and action space are independent choices.

## Why a structured move rather than raw SQL

Raw SQL was the obvious design and is rejected for three reasons, in order of
weight:

1. **It reintroduces the injection surface for no additional expressiveness that
   matters here.** Decomposition needs "group by X where Y" — a small, closed
   shape. A structured move covers it, and a validator over a closed shape is
   something one can actually reason about, where a validator over SQL text is a
   parser and a denylist.
2. **It is not translatable.** `RLM.Source.Global` and `RLM.Source.Interop` are
   not SQL underneath in the same way; a structured move can be compiled by each
   source into whatever it uses, which is the property that makes `RLM.Source` a
   contract rather than a SQL interface.
3. **A structured move is diffable.** Two moves can be compared, and a
   neighbourhood of a move can be generated mechanically — which is what leaves
   the door open to partial counterfactuals (see below) where a SQL string does
   not.

The trade accepted: a model that wants a window function or a join cannot ask for
one. That is Mode 4's problem, and Mode 4 is out of scope.

## Open questions

- **Neighbourhood counterfactuals.** `Arms` is impossible over an infinite move
  set, but *"every move differing from the chosen one in exactly one term"* is
  finite and mechanically generable. That would restore a weaker, honestly-named
  form of counterfactual for Mode 3. Worth doing only if the weaker figure can be
  labelled clearly enough that nobody reads it as the Mode 1 number.
- **Cost of validation.** Resolving a structured move may need a peek to know
  whether the slice is empty (FR-016). Whether that is charged to the peek pool or
  is free like `Dimensions()` is undecided; it depends on whether a policy can
  propose many moves per decision.
- **What the model is shown.** `RLM.Slice.Menu` enumerates. The Mode 3 analogue is
  a schema, and a schema is a much larger prompt for a wide table. It may need the
  same `TopN` treatment `RLM.Source.Global` gives fanout.
- **Does the LLM beat Greedy in a wider space?** SPEC §5 calls the Mode 1 version
  the open empirical question and the fixture answers "no". Mode 3 is where a
  model plausibly *should* win, because composing a good predicate is a
  judgement a size-weighted mean cannot make. That is the experiment this
  milestone exists to make possible — and `Scorecard` can run it the day the
  grammar lands, which is the argument for doing this before Mode 4 rather than
  after.
