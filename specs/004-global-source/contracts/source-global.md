# Contract: the `RLM.Source.Global` peek object

`Peek(predicate)` returns a `%DynamicObject`. Two properties are required by the
`RLM.Source` contract; the rest is this store's metric bag, which the trace
carries and `Describe` renders.

## Required by `RLM.Source`

| Property | Type    | Meaning                                                                                                      |
| -------- | ------- | ------------------------------------------------------------------------------------------------------------ |
| `n`      | integer | Nodes visited in this subtree. A **floor** when `capped` is 1, never a total                                 |
| `capped` | 0 or 1  | 1 if the visit cap or the depth cap stopped the walk                                                         |
| `error`  | string  | Present only on failure. When present, every other property is absent and the caller charges one failed peek |

## This store's metrics

| Property       | Type    | Meaning                                                                                        |
| -------------- | ------- | ---------------------------------------------------------------------------------------------- |
| `depth`        | integer | Deepest subscript level reached, relative to the global root                                   |
| `children`     | integer | Distinct immediate subscripts below this slice                                                 |
| `topFanout`    | array   | At most 5 `{token, label, n}`, descending by `n`. `token` is hex; `label` is the raw subscript |
| `dataNodes`    | integer | Visited nodes holding a value (`$DATA#10`)                                                     |
| `pointerNodes` | integer | Visited nodes with descendants but no value                                                    |
| `valueLenMean` | numeric | Mean `$LENGTH` of visited values. 0 when `dataNodes` is 0                                      |
| `valueLenSd`   | numeric | Population standard deviation of the same. 0 when `dataNodes` is under 2                       |
| `subNumeric`   | integer | Immediate subscripts where `$ISVALIDNUM` is 1                                                  |
| `subString`    | integer | Immediate subscripts that are neither numeric nor list-shaped                                  |
| `subList`      | integer | Immediate subscripts that parse as a `$LIST`                                                   |

`subNumeric + subString + subList` equals `children`. A test asserts it, because
a classifier that double-counts produces a type mix that reads as authoritative
and is wrong.

## What is deliberately absent

No stored value, and no subscript except the immediate children's.
Constitution I allows those through only because Principle II needs a
legal-move list; everything deeper than one level is reported as a count, never
as a name.

Nothing derived from the clock, the process, or a random source. A peek is a pure
function of `(store, predicate)` — Constitution V — so two peeks of a frozen
store are byte-identical, and a test asserts exactly that.

## Size bound

Serialized peek stays under 2,000 characters for any subtree. `topFanout` is the
only variable-length member and it is capped at 5 entries. This is what makes
context grow with slices inspected rather than with store size, so it is asserted
against a fixture and its 100x multiple rather than left as a design intention.

## `Describe` output

Self-labelling metric lines, one per figure, so the model quotes a number under
the name it received it under. A capped peek words the count as a floor:

```text
^JRNAUD("2019-11-04")
  nodes: 50000 (capped; the subtree is larger)
  depth reached: 4
  immediate children: 61
  busiest children: BOS-GEN (18332), NYC-MEM (11905), ...
  node kind: 71% data, 29% pointer
  value length: mean 214, sd 890
  subscript types: 0 numeric, 61 string, 0 list
```

An uncapped peek says `nodes: 412` with no parenthetical. The presence of the
disclosure is asserted, not its wording.
