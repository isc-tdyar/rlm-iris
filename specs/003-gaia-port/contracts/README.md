# Contracts: Port the gaia-iml prototype onto rlm-iris

No HTTP surface. The contracts are method signatures, stated with the obligations
that go with them. Three sections: what the prototype must implement, what the
library must gain, and what the prototype must no longer contain.

## What `gaia-iml` implements

### `Gaia.Source Extends RLM.Source.Table`

```objectscript
Method %OnNew() As %Status
Method Dimensions() As %DynamicObject
Method Peek(predicate As %String = "") As %DynamicObject
Method Describe(label As %String, peek As %DynamicObject) As %String
Method SplitMetric(peek As %DynamicObject) As %Numeric
Method ShouldSplit(peek As %DynamicObject, threshold As %Numeric = 0.15) As %Boolean
Method Ready(Output reason As %String) As %Boolean
Property Baseline As %Numeric [ InitialExpression = -1 ]
```

Obligations:

1. `%OnNew` takes no arguments and declares all six dimensions, calling
   `##super("SQLUser.GaiaQualityScored", "reject_fraction")` first. A caller that
   could pass a different table could point the Gaia dimensions at a table with
   none of those columns.
2. Every declaration is `AddBucketedDimension` with an explicit `labels` list, and
   every returned `%Status` is checked. A silently-dropped dimension makes the
   report describe a store the reader thinks was divided six ways.
3. `Dimensions()` calls `##super()` and then overwrites each dimension's `label`
   with the prototype's descriptive sentence. Children are untouched.
4. `Peek` returns the sixteen aggregates of data-model.md plus `capped: 0`. It
   returns `{"error": …}` on SQL failure rather than throwing, and `{"n": 0}` for
   an empty slice.
5. `Peek` calls `..Where(predicate, .args)` and binds every value as a parameter.
   It must not assemble a `WHERE` clause from `predicate` as text — that is the
   inherited method's job and sharing it is what stops `Peek` and `NullCount`
   from disagreeing about which rows a predicate names.
6. `Describe` emits the prototype's eleven lines verbatim, including both
   warnings, and says "This slice contains no sources." for `n = 0`.
7. `SplitMetric` returns `min(1, sd_rej / Baseline)`, computing `Baseline` on
   first call and caching it in the instance. Returns 0 on an error peek or a
   zero baseline.
8. `ShouldSplit` ignores `threshold` and returns
   `(SplitMetric(peek) >= 1) && (peek.n >= 400)`. The argument stays in the
   signature because the parent declares it; ignoring it is deliberate and
   commented at the site.
9. `Ready` distinguishes an empty table from a partially-scored one, with a
   reason naming both counts and the routine to run. It uses its own `COUNT`
   query, not a peek: the engine calls it before the root peek precisely because
   that peek is the expensive call on a store mid-load.

### `Gaia.LLM.AIHub Extends RLM.LLM`

```objectscript
Method Complete(instructions As %String, prompt As %String,
                Output sc As %Status) As %String
```

Obligations:

1. Never throws. Any failure — no API key, no provider, a refused completion —
   returns `""` with `sc` set. The prototype's contract is that the report is a
   bonus deliverable whose absence must not disturb `result.csv`.
2. Sets `..Model` to the model that answered, so the trace records it.
3. `%AI.*` is named here and nowhere else in the ported path. SC-005 enforces the
   other half of that by grepping `RLM.Engine.cls`.
4. One `Chat` round trip per call. No tool loop — that is what makes
   `LoopDetected` structurally impossible, and it is the prototype's existing
   guarantee.

### `Gaia.RLM`

```objectscript
ClassMethod Audit(outPath As %String = "") As %Status
ClassMethod Triage(outPath As %String = "") As %Status
```

Obligations:

1. Unchanged signatures. `^RLMAudit` and `^RLMTriage` call these and are not
   edited.
2. Each builds an `RLM.Source`, an `RLM.LLM`, an `RLM.Budget` and an
   `RLM.Engine`, calls `Run`, and writes the result. Nothing else.
3. `Triage` passes `"detection:b1"` as `Run`'s third argument. No SQL string
   crosses into the engine.
4. Both return a `%Status`. A failed run is a bad status with a written report,
   not an exception.

## What `rlm-iris` must gain

Both are defects the port exposed, so under FR-014 they are fixed here with tests
and are part of this feature rather than a follow-up.

### `RLM.Report.WriteTextToFile`

```objectscript
ClassMethod WriteTextToFile(text As %String, path As %String) As %Status
```

`RLM.Engine.Run` returns report text, and the `RLM.Report` it wrote is private to
the run. So a caller who wants the report on disk has no way to reach
`WriteToFile` — the existing instance method is unreachable from outside the
engine. Every consumer would re-implement it, and the first one to forget
`TranslateTable = "UTF8"` gets a file where every em dash is a question mark,
which is indistinguishable from a wrong report at a glance.

`WriteToFile(path)` becomes a one-line call to this. Obligations:

1. UTF-8, for the reason above.
2. Returns a status; a bad path is not an exception.
3. The instance method's behaviour is unchanged, asserted against the existing
   test.

### `RLM.Engine.MinSliceRows` — rejected, recorded

The obvious reading of the prototype's 400-row floor is that it belongs on the
engine. It does not: what counts as too small to be worth a call is a property of
the store, not of the traversal, and `ShouldSplit` is already the seam that asks
the store. Written down because it is the change a reader expects to find here.

## What `gaia-iml` must no longer contain

`Gaia/Slice.cls` is deleted outright. From `Gaia/RLM.cls`, all of:

| Removed                                      | Replaced by                                        |
| -------------------------------------------- | -------------------------------------------------- |
| `CallCount()`                                | `RLM.Budget`                                       |
| `Ask(instructions, prompt, reserved)`        | `RLM.LLM.Complete` via the engine                  |
| `Recurse(label, where, depth, used, .trace)` | `RLM.Engine`'s frontier                            |
| `ChooseDimension(desc, exclude, default)`    | `RLM.Policy.LLM`                                   |
| `ShouldRecurse(peek, depth)`                 | `Gaia.Source.ShouldSplit` plus `MaxDepth`          |
| `BaselineSpread()`                           | `Gaia.Source.Baseline`                             |
| `Indent(text)`                               | `RLM.Report.Bullet(text, depth)`                   |
| `Report(outPath, …)`                         | `RLM.Engine.Run` plus `RLM.Report.WriteTextToFile` |
| the trace strings                            | `RLM.Trace` and `RLM.Report.RenderTrace`           |
| `Parameter MAXDEPTH`                         | `RLM.Engine.MaxDepth`                              |
| `Parameter MAXCALLS`                         | `RLM.Budget`                                       |
| `Parameter SPLITRATIO`                       | the `>= 1` in `ShouldSplit`                        |
| `Parameter SPLITMINROWS`                     | the `>= 400` in `ShouldSplit`                      |
| `Extends %AI.Agent`                          | `Gaia.LLM.AIHub`                                   |

From `Gaia/RLM2.cls`, only the `Gaia.Slice` references. Its budget, trace and
delegation stay: it is not an `RLM.Engine` run — the model owns the recursion
there — so the library has nothing to lend it, and it exists to be compared
against the engine, which requires it to still exist.

## What is not in the contract

The number of model calls the ported `Audit()` makes. The prototype's ceiling was
18 with one reserved; the engine's budget expresses the same shape, but the
traversal is the engine's business and the count will differ. What must hold is
that the count is bounded before the first call and that whatever the run did not
reach is named in the report — not that it matches a number the prototype
happened to produce.
