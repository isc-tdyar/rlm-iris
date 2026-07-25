# Contract: RLM.Policy

## Signature

```objectscript
Class RLM.Policy Extends %RegisteredObject [ Abstract ]
{

/// Choose how to divide the current slice.
Method ChooseSplit(
 source As RLM.Source,
 peek As %DynamicObject,
 candidates As %List,
 budget As RLM.Budget) As RLM.Decision [ Abstract ]
{
}

}
```

## What a policy receives

- `source` — for `Peek`, `Describe` and `SplitMetric` only. A policy must not
  reach past the contract to the concrete store.
- `peek` — aggregates for the slice being divided. No rows, ever (Constitution I).
- `candidates` — eligible dimension names in declaration order, computed by the
  engine. A policy must not extend this set; a policy that did would not be
  comparable with one that did not.
- `budget` — so a policy that peeks can charge for it. A policy that cannot see
  the budget cannot honour FR-008.

## What a policy must return

An `RLM.Decision`, always. Never null, never an exception.

- `Dimension` is one of `candidates`, or `""` to decline.
- `Reason` is populated in both cases.
- `Candidates` holds one record per dimension considered, including ones that
  failed to evaluate.

## Obligations

1. **Charge every peek.** Call `budget.Charge(1)` before each peek and stop when
   it refuses. A policy that peeks without charging can starve synthesis.
2. **Never consume the reserved slot.** Use `Charge`, never `ChargeSynthesis`.
3. **Report partial evidence.** A candidate scored from a subset of its children
   sets `Sampled < Children`. A decision limited by any cap sets `Capped`.
4. **Be deterministic.** Same store, same peek, same candidates, same budget →
   same decision. Ties break by position in `candidates` — that is, by the store's
   declaration order. No wall clock, no randomness. This is what makes a run
   replayable (Constitution V).
5. **Decline rather than guess.** If nothing helps, return `""` with a reason.
   Splitting for the sake of splitting spends budget to produce slices no one
   asked about.
6. **Validate anything a model said.** A policy that consults a model must check
   the returned name against `candidates` before putting it in the decision
   (Constitution II). An unrecognised name is a decline with the model's answer
   quoted in `Reason`.
7. **Never throw.** A policy failure is a declined split with the reason attached,
   because a run that produces a coarse answer beats one that produces none.

## Prohibitions

- No store contents in any field of the decision.
- No `%AI.*` or HTTP reference in `RLM.Policy` or `RLM.Policy.Greedy`.
  `RLM.Policy.LLM` depends on the abstract `RLM.LLM` and nothing more concrete.
- No state carried between invocations. A policy is asked afresh each time; a
  policy that remembers is a policy whose replay diverges.
- No mutation of `source`, `peek`, `candidates` or the report.

## Implementations

| Class               | Model calls | Determinism | Chooses by                                     |
| ------------------- | ----------- | ----------- | ---------------------------------------------- |
| `RLM.Policy.Greedy` | 0           | Total       | Size-weighted mean of child metrics            |
| `RLM.Policy.LLM`    | 1           | Model's     | Asking the model, validated against candidates |

`Greedy` is the baseline every run can be scored against, precisely because it
costs nothing to compute and cannot vary.

## Engine responsibilities

The engine, not the policy:

- computes candidate eligibility (declared, unused on this path, ≥2 children);
- writes the decision to the trace as a `decision` row with its `"d"` subtree;
- surfaces a declined split as a report caveat;
- passes the budget through and honours a refusal from it.

## Test obligations for a new policy

Any new `RLM.Policy` must have tests proving: it charges its peeks; it declines
rather than guessing on a store where nothing separates; it returns only
candidates it was offered; and two identical invocations return identical
decisions. A policy consulting a model must also prove a hallucinated dimension
becomes a decline, not a split.
