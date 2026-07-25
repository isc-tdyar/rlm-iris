# Implementation Plan: Split-choice policy

**Branch**: `001-split-policy` | **Date**: 2026-07-25 |
**Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/001-split-policy/spec.md`

## Summary

Introduce `RLM.Policy` as the seam that decides how to divide a slice, and give
it two implementations: `Greedy`, which chooses from peek statistics and costs no
model call, and `LLM`, which preserves today's behaviour behind the same
interface. The engine takes a policy, defaults to `LLM`, and records each split
decision — chosen dimension, candidates, metric before and after — so a run can
be re-scored against the roads not taken without a model call.

The one design decision worth stating: a policy returns a **dimension**, not a
list of slices. Today the model returns slice names, which conflates "how should
this be divided" with "which pieces are worth looking at". Separating them is
what lets a statistics-only policy exist at all, because a store can score a
dimension without any judgement about relevance.

## Technical Context

**Language/Version**: ObjectScript, IRIS 2026.1 community (floor)
**Primary Dependencies**: None beyond base IRIS. `RLM.Engine` may not gain a
`%AI.*` or HTTP reference (Constitution VI).
**Storage**: `^||RLM.Trace` process-private by default, `^RLM.Trace` when durable
**Testing**: `%UnitTest` under `src/UnitTest/RLM`, run in the `rlm-iris`
container
**Target Platform**: Linux container, `intersystems/iris-community:latest-em`
**Project Type**: ObjectScript library, IPM module `rlm-core`
**Performance Goals**: Model calls are the cost that matters. A two-dimension
decomposition must cost one fewer model call than today (SC-001). Peek count may
rise; it is bounded by the candidate cap.
**Constraints**: Candidate evaluation is charged to the budget and can never
consume the reserved synthesis slot (FR-008). No prompt may grow with store size
(Constitution I).
**Scale/Scope**: Five new classes, ~20 new tests. No change to `RLM.Source`,
`RLM.Slice`, `RLM.Budget`, `RLM.Report` or `RLM.LLM` contracts.

## Constitution Check

_GATE: Must pass before Phase 0 research. Re-check after Phase 1 design._

| Principle                        | Assessment                                                                                                                                                                                                                                                      |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| I. No store contents to model    | PASS. A policy receives peeks and dimension names only. `Greedy` never touches a prompt. Gate test: the plan prompt stays byte-identical when rows multiply.                                                                                                    |
| II. Model never authors an input | PASS, and strengthened. `Policy.LLM` returns a dimension name that is checked against the candidate set before use — a narrower surface than today's slice path, since a dimension name has no structure to smuggle anything through.                           |
| III. Caps reported               | PASS. A declined split, an excluded candidate whose peek failed, and a candidate cap all reach the report. Adds a case today's engine cannot express: "not decomposed because nothing separated it."                                                            |
| IV. Test-first, deterministic    | PASS. `Greedy` is deterministic by construction, so its tests are exact. The fixture's metrics were already shaped so one dimension wins — that shaping was put there for this feature.                                                                         |
| V. Replayable                    | PASS, and this is the point. Recording candidates alongside the choice is what makes alternative arms enumerable. `Greedy` introduces no model call and so nothing unreplayable. Requires: no wall-clock or random tie-break — ties break by declaration order. |
| VI. Portable by default          | PASS. `RLM.Policy` and `.Greedy` depend on nothing. `.LLM` depends on the abstract `RLM.LLM` only.                                                                                                                                                              |

No violations. Nothing to record in Complexity Tracking.

One risk the gate does surface: `Policy.Greedy` must peek every candidate's
children to score it, which is `sum(children)` peeks per decision. On a store
with a high-fanout dimension that is a lot of SQL for one decision. Mitigation is
a candidate cap plus child sampling, both reported when they bite — designed in
Phase 1, not deferred.

## Project Structure

### Documentation (this feature)

```text
specs/001-split-policy/
├── plan.md              # This file
├── spec.md              # Feature specification
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── policy.md        # RLM.Policy contract
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (repository root)

```text
src/
├── RLM/
│   ├── Policy.cls              # NEW abstract: ChooseSplit -> decision
│   ├── Policy/
│   │   ├── Greedy.cls          # NEW statistics-only, no model call
│   │   └── LLM.cls             # NEW current behaviour behind the seam
│   ├── Decision.cls            # NEW value object: choice + candidates + metrics
│   ├── Engine.cls              # MODIFIED: takes a Policy, delegates the choice
│   ├── Trace.cls               # MODIFIED: additive fields for the decision
│   ├── Source.cls              # unchanged
│   ├── Source/Table.cls        # unchanged
│   ├── Slice.cls               # unchanged
│   ├── Budget.cls              # unchanged
│   ├── Report.cls              # MODIFIED: declined-split caveat
│   └── LLM/{Null,REST}.cls     # unchanged
└── UnitTest/RLM/
    ├── Policy.cls              # NEW unit tests for the contract + Greedy
    ├── PolicyLLM.cls           # NEW unit tests for the LLM policy
    ├── Decision.cls            # NEW unit tests for the value object
    ├── EndToEnd.cls            # MODIFIED: greedy run as the phase gate
    ├── Fixture.cls             # MODIFIED: a third dimension, and a flat store
    └── {Slice,Budget,Engine,LLMNull,LLMRest,SourceTable,Widget}.cls
```

**Structure Decision**: The existing single-module layout. `RLM.Policy.*`
mirrors `RLM.LLM.*` and `RLM.Source.*` — an abstract class plus a subpackage of
implementations — so a reader who has understood one understands all three.
`RLM.Decision` sits at the top level rather than under `RLM.Policy` because the
trace and the report both consume it; nesting it would imply only policies care.

## Phase 0 — Research

Three questions the spec leaves open at the implementation level. Answers in
[research.md](./research.md).

1. **How does Greedy score a dimension?** The children's metrics have to be
   reduced to one number. Weighted mean, worst child, and best child all give
   different answers on a skewed split, and the choice determines whether Greedy
   prefers dimensions that isolate a small anomaly or ones that halve cleanly.
2. **What bounds candidate evaluation?** `sum(children)` peeks per decision is
   unbounded in the fanout. Needs a cap that is reported when it bites.
3. **Does the trace row shape extend or gain a sidecar?** `RLM.Trace.Add` takes
   positional arguments; a candidate list is variable-length. Extending the
   `$LIST` row versus a subscripted sidecar changes how replay reads it.

## Phase 1 — Design

**Prerequisites**: research.md complete

- [data-model.md](./data-model.md) — `RLM.Decision` shape, the extended trace
  row, and the candidate record.
- [contracts/policy.md](./contracts/policy.md) — the `RLM.Policy` contract: what
  a policy may see, what it must return, what it may not do.
- [quickstart.md](./quickstart.md) — swapping a policy in three lines, and how to
  read a decision out of a trace.

### Post-design constitution re-check

Re-checked against data-model.md, contracts/policy.md and quickstart.md.

**Principle V — the item flagged for re-examination.** PASS. The arbiter was
whether the alternative arms can be enumerated from the trace plus the store.
They can: `$Order` over `^||RLM.Trace(runId, seq, "d", "cand", n)` yields one
record per dimension considered, each carrying its score, its per-child metrics,
and how many of its children were actually evaluated. Re-examining an unchosen
arm more deeply needs no stored rows either, because a peek is a pure function of
the store and the predicate — quickstart.md shows both walks. The representation
would have failed this check had the candidates been packed into one field:
`$List(row, 11)`
on a pre-feature row returns "" rather than erroring, so a reader would silently
enumerate nothing and conclude there were no alternatives.

**Principle III.** PASS, and Phase 1 widened its reach. The two caps that answer
the `sum(children)` risk are both on the decision record (`Capped`, and `Sampled`
against `Children` per candidate) and both surface in the report, so a score
computed from 8 of 400 children is never presented as a measurement.

**Principle II.** PASS. The contract makes validation an obligation rather than
a convention: a policy that consults a model checks the returned name against the
engine-supplied candidate set, and an unrecognised name becomes a decline with the
model's answer quoted.

**Principles I, IV, VI.** Unchanged by the design. `RLM.Policy.Greedy` touches no
prompt, the contract forbids wall-clock and randomness outright, and neither
`RLM.Policy` nor `.Greedy` names anything outside base IRIS.

One deliberate asymmetry to note rather than justify away: eligibility is computed
by the engine, not the policy. That constrains what a policy can do, and it is the
constraint that makes two policies comparable on the same store — which is the
reason the seam exists.

## Complexity Tracking

> Fill ONLY if Constitution Check has violations that must be justified

No violations. This feature removes a responsibility from the engine rather than
adding one.
