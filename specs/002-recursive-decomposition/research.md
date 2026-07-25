# Research: Recursive decomposition

Seven decisions. Each was open at the end of M1; each is closed here with the
alternative that was rejected and why.

## 1. Traversal order: depth-first pre-order

**Decision**: `Run` walks the slice tree depth-first, pre-order. A slice is
described, decided, and then its children are visited in declaration order before
its sibling is.

**Rationale**: three orders coincide under pre-order — the report's reading order,
the trace's row order, and the order budget is spent in. That is what makes a
budget-exhaustion caveat legible: "the run reached these slices and stopped" is
true of a prefix of the document. Under level order the run would spend on every
depth-1 slice before any depth-2 one, and the report would have to either
reorder against the trace or interleave depths, so a reader could not tell which
slices were skipped from where the document stops.

**Alternatives rejected**:

- _Level order (breadth-first)_: fairer under a tight budget — every branch gets
  its depth-1 look before any branch gets a depth-2 one. Rejected because the
  fairness is bought with a report whose order no longer matches the trace's, and
  because "fair" is the wrong default when the policy has already ranked the
  children: spending the last call on the most-mixed branch's grandchild beats
  spending it on the least-mixed branch's child.
- _Best-first over a priority queue keyed on split metric_: strictly better
  budget use, and a natural M3 experiment. Rejected now because it makes the
  report order depend on the metric, so SC-002's byte-identity at depth 1 would
  hold only by accident.

## 2. Recursion via an explicit stack, not a recursive method

**Decision**: an iterative walk over a stack of `(path, depth)` pairs held in a
local array.

**Rationale**: `Run` already holds the report, the trace, the budget, the caveat
list and the notes list. A recursive `Descend()` would need all five threaded
through its signature or promoted to properties, and promoting them makes the
engine stateful across runs, which is how a second run inherits the first's
caveats. The tree is at most `MAXDEPTH` = 3 deep, so nothing is gained from the
call stack.

**Alternative rejected**: a private recursive method taking a context object.
That context object is `Run`'s locals with a class around it; the class would
exist only to satisfy the recursion.

## 3. "Worth splitting" is the existing `ShouldSplit` hook, finally called

**Decision**: `RLM.Engine` calls `..Source.ShouldSplit(peek)` before spending a
decision on a slice. No new API.

**Rationale**: `RLM.Source.ShouldSplit(peek, threshold=0.15)` already exists and
has never been called — `Run` decides at the root unconditionally and never
considers a child at all. It is the right hook: whether a slice still mixes
populations is a question about the store's own measure, so the store answers it.
A source that wants a relative threshold, a minimum slice size, or a run-scoped
baseline overrides the method and caches whatever it likes on itself, because a
source is an instance.

**Alternatives rejected**:

- _A `RelativeThreshold` property on `RLM.Source`_: encodes one store's rule
  (`sd >= 1.0 x baseline`) in the base class, where the next store's rule will not
  fit. Overriding one method is smaller than parameterizing a rule nobody else
  shares.
- _Asking the policy_: a policy already declines when nothing separates. But it
  declines having spent peeks — the point of this gate is to not spend them on a
  slice that is already one population.

## 4. A root scope is a starting path, not a new mechanism

**Decision**: `Run(question, .traceId, rootPath)`. `rootPath` is a slice path in
the existing grammar. The traversal starts there instead of at `""`.

**Rationale**: the recursion of decision 1 already threads a path down each
branch, resolves it through `RLM.Slice`, and computes candidates from it. Starting
that machinery at `colour:red` instead of `""` delivers all four of User Story 4's
scenarios with no code that exists for scoping:

- every peek is confined to the scope, since every peek's path is prefixed by it;
- the scoping dimension is excluded from candidates, because `Candidates(path)`
  already excludes dimensions used on the path;
- an unresolvable scope is refused before any model call, because
  `RLM.Slice.Resolve` refuses it, as it refuses any other bad path;
- the scope's label is the label `Resolve` returns, which the store description
  then carries.

**Alternatives rejected**:

- _A `RootWhere` string property on the source_ (what the prototype does): raw SQL
  travelling past `RLM.Slice`. The caller is trusted, but the mechanism is then
  available to anything that can set a property, and Principle II's value comes
  from there being no such path at all.
- _A `Scope` %List on the source that `Predicate()` prepends_: works, but splits
  path handling across two places, and `Peek("")` would still mean "whole store"
  in the engine while meaning "the scope" in the source.

**Consequence**: the depth limit counts from the scope, and the scope's own
components count against `MAXDEPTH`. A depth-2 run scoped one level deep reaches
grammar depth 3.

## 5. Buckets are a second kind of dimension on `RLM.Source.Table`

**Decision**: `AddBucketedDimension(dimension, property, breakpoints)` on
`RLM.Source.Table`. Terms in the predicate encoding grow an operator field, and
one bucket contributes up to two terms.

**Rationale**: FR-009 and User Story 2's fourth scenario require one store to
carry both kinds, so the two cannot be sibling subclasses. The predicate encoding
(`property<C2>token`, split on `<C1>`) is private between `Predicate` and `Peek`
in one class, so widening it to `property<C2>operator<C2>value` costs nothing
outside — no caller, no test and no other source reads it.

Open-ended buckets emit one term. `n` breakpoints yield `n+1` buckets: below the
first, between each pair, and at or above the last.

**Alternatives rejected**:

- _`RLM.Source.Bucketed extends RLM.Source.Table`_: a store then has bucketed
  dimensions or categorical ones, never both.
- _Splicing the edges into the SQL text_: the edges are the developer's numbers,
  not the model's, so it would be safe. Rejected because "this string is safe
  because of where it came from" is the reasoning that stops being true after a
  refactor, and because FR-008 makes the rule checkable instead.
- _Deriving the breakpoints from the data (quantiles)_: attractive, and wrong for
  the prototype, whose labels are domain thresholds a reader recognizes
  (`5-20% rejected`). A quantile source is a later, separate thing.

**Null handling**: a row whose bucketed property is null belongs to no bucket, so
the buckets do not sum to the parent. The source counts the nulls and the engine
discloses the gap (FR-005's sibling case), rather than either silently losing
them or inventing an "unknown" bucket the grammar would then have to name.

## 6. Report style is a property, and the trace renderer lives on the report

**Decision**: `RLM.Report.Style` ("plain" default, "markdown"), consulted by
`Heading()` and by a new `Bullet(text, depth)` and `Fenced(lines, language)`.
`RLM.Report.RenderTrace(runId, durable)` walks the trace global and returns the
block.

**Rationale**: style is a rendering concern and every figure is computed before
rendering, which is what makes SC-004 checkable rather than aspirational. Keeping
the default `"plain"` and branching only inside the heading and bullet primitives
is what makes SC-002's byte-identity a one-line assertion instead of a
re-derivation.

The renderer belongs to `RLM.Report` rather than `RLM.Trace` because a trace is
a record and a report is a rendering; putting a renderer on the record would give
the record a presentation format, and the next presentation format then argues
about which one is canonical. `RLM.Report` already depends on nothing outside the
portable set, and `RLM.Trace` is inside it.

**Alternative rejected**: a separate `RLM.Report.Markdown` subclass. Rejected
because the two styles differ in three primitives out of nine, and a subclass
would inherit the other six only to be a different class for no reason.

## 7. `Run` never throws

**Decision**: the body of `Run` is wrapped, and a failure returns a report saying
the analysis was unavailable, with the reason.

**Rationale**: FR-016. A decomposition is a step inside a larger pipeline in both
of the prototype's entry points; an exception there takes down the pipeline over
a report nobody would have blocked on. The reserved synthesis slot already exists
so a degraded run can still answer.

**Platform note**: `Quit <value>` is not allowed inside a `Catch` block in
ObjectScript, so the handler sets a variable that the single exit point returns.
This is noted here because it is the reason the method has one exit rather than
the two the shape suggests.

**Alternative rejected**: returning a `%Status` alongside the text. Rejected
because every caller would then have two things to check and the interesting one
is already in the document — a caveat naming the failure is read by the person
who needs it, and a status is checked by nobody.
