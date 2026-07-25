# Contracts: Recursive decomposition

No HTTP surface. The contracts of an ObjectScript library are its method
signatures, so they are stated here as signatures with the obligations that go
with them. A change to any of these is a breaking change to a caller.

## `RLM.Engine`

```objectscript
Property MaxDepth As %Integer [ InitialExpression = 1 ];
Property ReportStyle As %String [ InitialExpression = "plain" ];

Method Run(question As %String,
           Output traceId As %Integer,
           rootPath As %String = "") As %String
```

`ReportStyle` is passed through to the `RLM.Report` the engine builds. The engine
owns that object, so a caller has no other way to reach it. The property exists
for that reason and carries no logic of its own.

Obligations:

1. `MaxDepth` = 1 reproduces the pre-feature traversal exactly: one root decision,
   children examined flat, no second decision. (SC-002)
2. `MaxDepth` = n visits a slice at depth d < n, decides it, and visits its
   children at d+1. Depth counts from `rootPath`.
3. `rootPath` is resolved through `RLM.Slice.Resolve` before any model call. On
   refusal `Run` returns a report stating the refusal and makes no call.
4. Never throws. Any exception from a source, policy or provider becomes a report
   whose caveats name the failure. (FR-016)
5. Aborts before any model call if `..Source.Ready()` is false, returning the
   reason. (FR-015)
6. Does not choose a split it cannot fund at least one child of. (FR-004)
7. Consults `..Source.ShouldSplit(peek)` before spending a decision on a slice.
   (FR-003)

```objectscript
Method Candidates(path As %String = "") As %List
```

Unchanged signature, now called with non-empty paths. Its existing exclusion of
dimensions already used on the path is what delivers FR-002 and User Story 4's
second scenario.

## `RLM.Source`

```objectscript
Method Ready(Output reason As %String) As %Boolean
```

New, concrete, returns 1 with `reason` empty. A subclass overriding it to return
0 must set `reason` to something a reader can act on. Not abstract: an existing
source must not need editing to stay ready. (FR-015)

```objectscript
Method ShouldSplit(peek As %DynamicObject, threshold As %Numeric = 0.15) As %Boolean
```

Existing, unchanged, now actually called. A source with a relative threshold, a
minimum slice size, or a cached run-scoped baseline overrides this.

## `RLM.Source.Table`

```objectscript
Method AddBucketedDimension(dimension As %String,
                            property As %String,
                            breakpoints As %List,
                            labels As %List = "") As %Status
```

Obligations:

1. Refuses if `property` is not a property of the class, if `breakpoints` is
   empty, or if the breakpoints are not strictly ascending. Refusal is a status
   at declaration time, not a broken query at peek time.
2. Declares `$ListLength(breakpoints) + 1` children, ascending, in that order.
3. Child `i` covers `[breakpoints(i-1), breakpoints(i))` — half-open,
   lower-inclusive — with the first open below and the last open above. (FR-008)
4. Tokens are `b0` … `bn`. `labels`, if given, overrides the generated range
   labels one for one; otherwise labels are derived from the edges.
5. Every edge reaches SQL as a bound parameter. (FR-008)
6. The resulting spec is indistinguishable from a categorical one to a policy.
   (FR-009)

```objectscript
Method NullCount(predicate As %String = "", dimension As %String = "") As %Integer
```

Rows within `predicate` that `dimension` covers with no child, and which therefore
appear in none of its children. Returns 0 when `dimension` is not a bucketed
dimension of this store. What the engine's disclosure of the sum gap is computed
from.

`dimension` was added during implementation. A store may bucket two columns with
different null counts, and the engine asks about the one dimension it is splitting
on, so a store-wide figure would disclose a gap that is not the gap in the split
being reported. The same signature is concrete on `RLM.Source`, returning 0: a
dimension enumerated from the data has no uncovered rows by construction.

## `RLM.Report`

```objectscript
Property Style As %String [ InitialExpression = "plain" ];

Method Heading(text As %String)                         // existing, style-aware
Method Bullet(text As %String, depth As %Integer = 0)    // new
Method Fenced(lines As %List, language As %String = "")  // new
ClassMethod RenderTrace(runId As %Integer, durable As %Boolean = 0) As %List
```

Obligations:

1. `Style` = `"plain"` produces byte-identical output to the pre-feature class for
   every existing primitive. (SC-002)
2. `Style` = `"markdown"` renders headings as `##` and emits no `-----` rule.
3. `Bullet` indents by `depth`, so a depth-2 slice sits under its parent.
   (FR-012)
4. `Fenced` emits a fence in Markdown style and an indented block in plain style;
   in both, its content is passed through unaltered.
5. `RenderTrace` returns one line per trace row naming role, depth, slice and
   outcome, and includes declined decisions with their reasons. (FR-011)
6. Neither style changes any figure or drops any caveat. (SC-004)

## `RLM.Policy`

```objectscript
Method ChooseSplit(source As RLM.Source,
                   peek As %DynamicObject,
                   candidates As %List,
                   budget As RLM.Budget,
                   path As %String = "") As RLM.Decision

ClassMethod ChildPredicate(source As RLM.Source,
                           path As %String,
                           dimension As %String,
                           token As %String) As %String
```

Planned as unchanged; widened during implementation, and the earlier claim that
it was unchanged was wrong. Before recursion the policy was only ever called at
the root, so a child predicate built from `dim:token` alone was correct. Called
on a depth-1 slice, that predicate names a store-wide child: `RLM.Policy.Greedy`
scored `size:small` when it was dividing `colour:red`. The number it reported was
real, about the wrong population, and no existing test caught it because nothing
about the output looked wrong.

Obligations:

1. `path` is the slice being divided, `""` for the whole store. A policy that peeks
   a candidate's children peeks them within `path`.
2. `ChildPredicate` is the only way to build that predicate. Shared for the same
   reason `Children` is: a policy assembling its own components peeks a different
   slice, and the difference is invisible in the score it reports.

## What is not in the contract

The number of times the policy is called. It is called once per decided slice
rather than once per run, which is the engine's business; a policy cannot tell the
difference and must not need to.
