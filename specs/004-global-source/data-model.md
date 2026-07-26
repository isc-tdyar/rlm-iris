# Data Model: RLM.Source.Global

No persistent entity is added. The feature reads a global it does not own and
writes nothing. What follows is the in-memory shape of the source and the
encoding rules that make a slice name round-trip.

## `RLM.Source.Global`

| Property    | Type    | Default | Notes                                                                                 |
| ----------- | ------- | ------- | ------------------------------------------------------------------------------------- |
| `Name`      | string  | —       | Inherited. The global reference, used in reports                                      |
| `GlobalRef` | string  | —       | Validated at construction. `^Name` with no subscripts                                 |
| `VisitCap`  | integer | 50000   | Nodes one walk may visit. SPEC §4 uses this figure                                    |
| `DepthCap`  | integer | 8       | Subscript levels below the root a walk may descend                                    |
| `AllowList` | list    | ""      | Permit patterns. Empty means nothing is permitted, because the default is fail-closed |
| `TopN`      | integer | 5       | Entries in `topFanout`                                                                |

The deny set is a class parameter rather than a property, so an instance cannot
widen it:

```text
DENY = ^%*, ^ISC*, ^rMAP*, ^ROUTINE*, ^odd*
```

Deny is checked after allow and wins. An allowlist of `^*` therefore still cannot
reach `^ROUTINE`, which is the property that makes the deny set worth having.

## Validation at construction

Refuse, with a reason naming what matched, when the reference:

1. does not start with `^`
2. contains `|` or `[` or `"` — an extended or cross-namespace reference
3. contains `(` — subscripts belong in a slice name, not in the source
4. matches no allow pattern
5. matches a deny pattern

Order matters: a malformed reference is refused before the allowlist is consulted,
so the refusal reason names the real problem rather than "not allowed".

## Dimension naming

One dimension per subscript level, `s1` for the first, `s2` for the second. The
label is `subscript level N`.

A path is `s1:<hex>/s2:<hex>`. `RLM.Slice`'s rule that each dimension appears at
most once per path then means each subscript level is fixed at most once. That is
the correct constraint: fixing level 1 twice cannot narrow anything.

`Dimensions(path)` walks the immediate children of the slice `path` resolves to,
so `s2`'s children under `s1:<hex of 2019-11-04>` are that date's facilities and
nothing else.

## Token encoding

A token is the subscript hex-encoded, two uppercase digits per character. The
child's `label` carries the raw subscript for the report and the prompt.

Measured in [research.md](research.md) R3: a raw subscript may contain `:` or `/`,
which are `RLM.Slice`'s separators, and Base64 cannot be used because its alphabet
contains `/`.

`Predicate(components)` decodes each token back to its subscript and returns them
as a `$LIST` of raw subscripts. `Peek` builds the reference with `$NAME` under
indirection (R1), which does the quoting.

## Invariants a test asserts

- `subNumeric + subString + subList = children`
- Children's `n` sums to the parent's `n` on an uncapped walk
- `Peek(p)` twice on a frozen store returns identical serializations
- Every subscript in the fixture round-trips: raw → hex → raw
- No path writes to the target global
