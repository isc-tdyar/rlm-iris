# Quickstart: Recursive decomposition

Every snippet below is verified against the test suite before this document is
marked done. The figures quoted are measured, not illustrative.

## Going deeper than one level

Recursion is opt-in. A run with no `MaxDepth` set behaves exactly as it did
before this feature:

```objectscript
Set engine = ##class(RLM.Engine).%New(source, llm)
Set report = engine.Run("what drives price?", .traceId)
```

One property changes that:

```objectscript
Set engine = ##class(RLM.Engine).%New(source, llm, ##class(RLM.Budget).%New(16))
Set engine.MaxDepth = 2
Set report = engine.Run("what drives price?", .traceId)
```

Raise the budget with the depth. A depth-2 run makes one root decision, one
decision per depth-1 slice it still considers mixed, a sub-call per leaf, and the
synthesis. Over the two-by-two nested fixture that is 6 calls under
`RLM.Policy.LLM` — the default budget of 8 covers it — but the count grows with
the product of the fanouts, and a wider store exhausts 8 partway down. Whatever
the run does not reach is named in the caveats rather than quietly missing.

Each branch splits on a dimension no ancestor used, so a store with two dimensions
is exhausted at depth 2 whatever `MaxDepth` says.

## Reading the depth back out

Depth was always field 2 of a trace row. It was always 0 or 1 because there was
only ever one level:

```objectscript
Set seq = ""
For {
    Set seq = $Order(^||RLM.Trace(traceId, seq), 1, row)
    Quit:seq=""
    Write !, $Justify("", $List(row, 2) * 2), $List(row, 1), " ", $List(row, 4)
}
```

## Splitting a continuous column

A column of 75,000 distinct doubles has no useful `SELECT DISTINCT`. Declare the
buckets instead:

```objectscript
Set src = ##class(RLM.Source.Table).%New("UnitTest.RLM.Widget", "Price")
Do src.AddDimension("colour", "Colour")
Do src.AddBucketedDimension("price", "Price", $ListBuild(10, 50, 100))
```

Three breakpoints, four children, ascending, half-open lower-inclusive. The derived
labels name the column and the range:

```text
price:b0  Price < 10
price:b1  Price [10,50)
price:b2  Price [50,100)
price:b3  Price >= 100
```

The tokens are ordinals so a reworded label does not invalidate a trace. Pass
`labels` to name them in domain terms:

```objectscript
Do src.AddBucketedDimension("reject", "RejectFraction",
    $ListBuild(0.05, 0.20, 0.50),
    $ListBuild("clean (<5% rejected)", "moderate (5-20%)",
        "high (20-50%)", "severe (50%+)"))
```

A policy comparing `colour` against `price` cannot tell which is which, which is
the point: nothing in the dimension spec says how the children were derived.

Rows whose bucketed property is null belong to no bucket, so the bucket counts do
not sum to the parent's. That gap is disclosed in the report rather than absorbed:

```text
- 2 row(s) of 'UnitTest.RLM.Widget by Price' fall in no bucket of 'rating' and are
  counted in none of its children.
```

The slice is named because the gap is a gap in that slice: the same dimension over
a different parent misses a different number of rows.

## A report someone reads on GitHub

```objectscript
Set engine.ReportStyle = "markdown"
Set report = engine.Run("what drives price?", .traceId)
```

The two styles differ in formatting and in nothing else — every figure and every
caveat in one is in the other. Plain style is byte-identical to the pre-feature
output, which is asserted rather than assumed.

To render the trace a human never saw:

```objectscript
Set r = ##class(RLM.Report).%New()
Set r.Style = "markdown"
Do r.Fenced(##class(RLM.Report).RenderTrace(traceId), "text")
Write r.Text
```

A depth-2 run over the nested test fixture, verbatim:

```text
  1  decision   d0  (whole store)  -- split on color (lowest size-weighted child
     metric of 2 candidate(s): 0.900 -> 0.520)
  2  decision   d1  color:red  -- split on size (lowest size-weighted child metric
     of 1 candidate(s): 0.800 -> 0.055)
  3  subcall    d2  color:red/size:small
  4  subcall    d2  color:red/size:large
  5  decision   d1  color:blue  -- not decomposed (the store reports this slice is
     already one population)
  6  subcall    d1  color:blue
  7  synthesis  d0  (whole store)
```

A declined decision appears with its reason. A trace where the declines are
invisible cannot be told from a trace that failed to write.

Row 2 is also SC-001, readable off the trace: the depth-1 decision leaves 0.055
where its parent's decision left 0.520, so going a level deeper measurably tightened
the slice rather than just producing more rows.

## Asking about part of a store

The third argument is a slice path in the ordinary grammar, not a `WHERE` clause:

```objectscript
Set report = engine.Run("what drives price within red?", .traceId, "colour:red")
```

Every peek in the run is confined to red, including the root's. `colour` is not
offered as a way to split, because the recursion already excludes dimensions used
on the path. The report says which subset it describes, since a reader shown red's
figures as the store's would draw the wrong conclusion.

A path the store does not offer is refused before any model call — the same
refusal, from the same code, that a bad slice name has always got:

```objectscript
Set report = engine.Run("q", .traceId, "shape:round")
```

```text
The analysis was not run: ERROR #5001: 'shape:round' is not a slice this store offers
```

`llm.Calls` is 0. The status text is carried through as it stands, error number
included: the alternative is re-wording another layer's message, and a reader
grepping a log wants the number.

Note the ceiling. The scope's components count against `RLM.Slice.MAXDEPTH` (3),
so a one-component scope leaves two levels of decomposition.

## Refusing to report on a store that is not ready

Override one method:

```objectscript
Method Ready(Output reason As %String) As %Boolean
{
    Set loaded = ##class(Load.Status).PartitionsLoaded()
    If loaded < 12 {
        Set reason = "the nightly load has not finished; "_(12 - loaded)
            _" of 12 partitions are absent"
        Quit 0
    }
    Set reason = ""
    Quit 1
}
```

Whatever it consults, it must not be the store's own aggregates: the engine checks
`Ready` **before** the root peek, precisely because on a store mid-load that peek
is the expensive call and the one most likely to fail.

A run over it costs zero model calls and zero peeks, and returns the reason as the
report. The alternative — averaging over whichever rows happen to be usable —
produces a document that is both confident and wrong, which is worse than no
document.

Readiness is opt-in. A source that does not override this is ready, so nothing
existing changes behaviour.

## Nothing takes down the caller

`Run` does not throw. A source that raises, a policy that faults, a provider that
disappears — each becomes a report saying the analysis was unavailable and why.
A decomposition embedded in a pipeline cannot take the pipeline down over a
report nobody would have blocked on.

## Verifying it yourself

```bash
docker exec rlm-iris iris session IRIS -U USER
```

```objectscript
Do $system.OBJ.LoadDir("/home/irisowner/dev/src", "ck", , 1)
Set ^UnitTestRoot = "/home/irisowner/dev/src/UnitTest"
Do ##class(%UnitTest.Manager).RunTest("RLM", "/noload/nodelete/norecursive")
```

The `"ck"` qualifier is mandatory. Without it the classes import without compiling
and `%UnitTest` skips them while still printing "All PASSED".
