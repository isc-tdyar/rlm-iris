# Phase 1 Data Model: Split-choice policy

## RLM.Decision

One policy invocation, in full. Consumed by the engine (to act on), the trace (to
record) and the report (to disclose), which is why it is a class rather than a
handful of output parameters.

| Property       | Type                             | Meaning                                                                     |
| -------------- | -------------------------------- | --------------------------------------------------------------------------- |
| `Dimension`    | `%String`                        | Dimension chosen, or `""` for a declined split                              |
| `Reason`       | `%String`                        | Why declined, or why this dimension won. Always populated.                  |
| `MetricBefore` | `%Numeric`                       | Split metric of the slice being divided                                     |
| `MetricAfter`  | `%Numeric`                       | Weighted score of the chosen dimension, `""` if declined                    |
| `PolicyClass`  | `%String`                        | Which policy decided. Two runs differing only in policy are not comparable. |
| `PeeksSpent`   | `%Integer`                       | Peeks consumed reaching this decision                                       |
| `Capped`       | `%Boolean`                       | 1 if a cap limited what was evaluated                                       |
| `Candidates`   | list of `RLM.Decision.Candidate` | Every dimension considered, in declaration order                            |

`Reason` is never empty, including on success. A record that explains only its
failures is a record that has to be reverse-engineered on every other read.

## RLM.Decision.Candidate

| Property       | Type       | Meaning                                                          |
| -------------- | ---------- | ---------------------------------------------------------------- |
| `Dimension`    | `%String`  | Dimension name                                                   |
| `Score`        | `%Numeric` | Size-weighted mean of child metrics, `""` if unavailable         |
| `ChildMetrics` | `%List`    | `token:n:metric` per evaluated child, in declaration order       |
| `Children`     | `%Integer` | Children the dimension has                                       |
| `Sampled`      | `%Integer` | Children actually evaluated; `< Children` means partial evidence |
| `Error`        | `%String`  | Why this candidate was unavailable, `""` if fine                 |

`Sampled` and `Children` are stored separately rather than as one "partial" flag,
because an evaluator needs to know how partial: 8 of 10 and 8 of 400 warrant
different confidence in the same score.

`ChildMetrics` keeps the raw per-child figures because any single scalar loses the
shape of the split (research §1). It is a delimited `%List` rather than nested
objects since it is written once and read whole.

## Extended trace layout

The `$LIST` row is unchanged — ten fields, same positions, same meanings. A new
`"d"` subtree hangs off a decision-bearing row.

```objectscript
^||RLM.Trace(runId, seq) = $LB(role, depth, sourceClass, sliceKey, splitMetric,
                               capped, tokensIn, tokensOut, model, note)

^||RLM.Trace(runId, seq, "d") = $LB(dimension, reason, metricBefore,
                                    metricAfter, policyClass, peeksSpent, capped)

^||RLM.Trace(runId, seq, "d", "cand", n) = $LB(dimension, score, children,
                                               sampled, error)

^||RLM.Trace(runId, seq, "d", "cand", n, "m") = childMetrics   ; %List
```

A row with no `"d"` subtree made no decision — true of every sub-call and every
synthesis, so absence carries meaning rather than being a gap.

`role` gains one value: `decision`. Existing values (`plan`, `subcall`,
`refused`, `capped`, `synthesis`) keep their meanings, so the ordering assertions
in the current tests hold for runs that use the LLM policy.

Offline re-scoring is `$ORDER` over `..., "d", "cand", n`: each candidate's score
is already there, and its slices are re-peekable from the store because a peek is
a pure function of the store and the predicate.

## Candidate eligibility

A dimension is a candidate for the current slice when all hold:

1. It is declared by the store's `Dimensions()`.
2. It is not already used on the current path — splitting twice on one dimension
   narrows nothing (already enforced by `RLM.Slice`).
3. It has at least two children (FR-011). One child yields a slice identical to
   its parent.

Eligibility is computed by the engine, not the policy. A policy that had to
derive its own candidate set could derive a different one, and then two policies
would not be comparable — which defeats the reason for having the seam.
