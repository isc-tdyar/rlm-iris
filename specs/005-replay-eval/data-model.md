# Data model: replay and offline evaluation

## Trace format v2

Additive. The positional `$LIST` row is unchanged, so every existing reader keeps
working and no existing test changes.

```text
^RLM.Trace(runId)              = <next seq counter>        ; unchanged
^RLM.Trace(runId, "v")         = 2                          ; NEW format version
^RLM.Trace(runId, "fp")        = <crc32 chain>              ; NEW store fingerprint
^RLM.Trace(runId, "q")         = <question>                 ; NEW, so a replay
                                                            ; needs only the runId
^RLM.Trace(runId, seq)         = $LB(role, depth, sourceClass, sliceKey,
                                     splitMetric, capped, tokensIn, tokensOut,
                                     model, note)           ; unchanged
^RLM.Trace(runId, seq, "t")    = <model output>             ; NEW, model text
^RLM.Trace(runId, seq, "d")    = $LB(dimension, reason, metricBefore,
                                     metricAfter, policyClass, peeksSpent,
                                     capped)                ; unchanged
^RLM.Trace(runId, seq, "d", "cand", i)      = ...           ; unchanged
^RLM.Trace(runId, seq, "d", "cand", i, "m") = ...           ; unchanged
```

A trace with no `"v"` node is version 1. `RLM.Replay` refuses it with a reason
naming the version, because a v1 trace has no `"t"` nodes and replaying it would
produce a report that differs from the original while claiming to reproduce it.

`"v"`, `"fp"` and `"q"` are written once, by `RLM.Engine` at the start of a run,
and only when the trace is durable — a process-private trace cannot be replayed
across sessions, so paying for a fingerprint on it buys nothing.

## Store fingerprint

```objectscript
Set fp = 0
Set fp = $ZCRC(fp_$ZCRC(source.Peek("").%ToJSON(), 7), 7)
// then, for each first-level slice, in the store's own declaration order:
Set fp = $ZCRC(fp_$ZCRC(source.Peek(childPredicate).%ToJSON(), 7), 7)
```

CRC-32 (`$ZCRC(s, 7)`), chained so order matters. Costs one peek per first-level
slice, which the run was about to spend anyway.

**What it detects**: any change that moves any aggregate of the root or of any
first-level slice — a row added, a value's length changed, a subscript appearing
or vanishing.

**What it does not detect**: a mutation that leaves every aggregate identical,
such as swapping two equal-length values between slices. This is a fingerprint
over the peeks, not over the data, and it is named and documented as such. It is
also exactly the right granularity for the claim being made: if no peek figure
moved, no decision could have moved, so the replay is sound.

## Arm

One candidate dimension at one recorded decision that the run did not choose.

| Field       | Type       | Meaning                                            |
| ----------- | ---------- | -------------------------------------------------- |
| `seq`       | `%Integer` | the trace row the decision came from               |
| `path`      | `%String`  | the slice path that decision was made at           |
| `dimension` | `%String`  | the candidate not chosen                           |
| `chosen`    | `%String`  | what the run chose instead, or "" if it declined   |
| `score`     | `%Numeric` | what this arm would have scored, or "" if unscored |
| `peeks`     | `%Integer` | peeks this arm cost                                |
| `error`     | `%String`  | why it could not be scored; "" when it was scored  |

An arm is never dropped and never scored 0 in place of an error (FR-005): 0 is a
legitimate score meaning "divides nothing", and conflating it with "could not
tell" would make the enumeration unreadable exactly where it matters.

## Enumeration result

| Field    | Type         | Meaning                                       |
| -------- | ------------ | --------------------------------------------- |
| `arms`   | array of Arm | every unchosen candidate at every decision    |
| `peeks`  | `%Integer`   | total peeks spent                             |
| `capped` | `%Boolean`   | the peek budget stopped the enumeration early |
| `calls`  | `%Integer`   | model calls spent. Asserted to be 0           |

`calls` is carried and asserted rather than assumed. A future change that made an
arm consult a model would be a Principle V violation, and a field that is always
0 is the cheapest place to catch it.

## Scorecard row

One policy over one store and one question.

| Field       | Type       | Meaning                                                       |
| ----------- | ---------- | ------------------------------------------------------------- |
| `policy`    | `%String`  | policy class name                                             |
| `calls`     | `%Integer` | model calls spent                                             |
| `peeks`     | `%Integer` | peeks spent                                                   |
| `slices`    | `%Integer` | slices examined                                               |
| `objective` | `%Numeric` | mean `SplitMetric` over the leaves examined; lower is better  |
| `chose`     | `%String`  | the dimension chosen at the root                              |
| `error`     | `%String`  | why this row has no objective; "" on success                  |
| `runId`     | `%Integer` | the durable trace, so any row can be replayed or drilled into |

Cost and objective stay separate columns (FR-009). Netting them into one ranking
number requires a price per call, that price is the caller's business and not the
package's, and a single number cannot be decomposed back into the two facts a
reader needs.

## Scorecard

| Field      | Type         | Meaning                             |
| ---------- | ------------ | ----------------------------------- |
| `store`    | `%String`    | source class and name               |
| `question` | `%String`    | the one question every row answered |
| `rows`     | array of row | one per policy, in the order given  |

Scoped to one store deliberately. `SplitMetric` is normalized per source class by
constitutional constraint, so `objective` compares policies over one store and
means nothing across two — the scope is a field rather than a convention so a
caller cannot accidentally build the meaningless comparison.
