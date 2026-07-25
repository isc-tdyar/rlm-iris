# Phase 0 Research: Split-choice policy

Three implementation questions the spec deliberately left open.

## 1. How does Greedy reduce a dimension's children to one score?

**Decision**: Size-weighted mean of the children's metrics, with the raw child
metrics kept on the decision record.

**Rationale**: The score has to answer "if I split here, how mixed is what I'm
left with?" Weighting by child size answers that: a dimension that leaves 95% of
the store in one still-mixed child has barely helped, and the weighted mean says
so, while an unweighted mean would be flattered by a tiny clean child.

On the `Widget` fixture, `Colour` scores near zero (red 9–12 and blue 96–104 are
each tight) and `Size` scores near the root (both halves still span 9–104). That
is the discrimination the whole feature depends on, and the weighted mean
produces it.

Keeping the raw child metrics on the record matters more than the aggregation
choice. Any single scalar loses the shape of the split, and an evaluator asking
"did this dimension isolate an outlier or halve the population?" needs the
children, not the summary. Storing both means the aggregation can be changed later
without invalidating existing traces.

**Alternatives considered**:

- _Worst child_ (max of children): prefers dimensions that leave no mixed
  residue. Attractive, but on a high-fanout dimension one stubborn child vetoes
  an otherwise excellent split, and high-fanout dimensions are exactly where
  decomposition pays off.
- _Best child_ (min): prefers dimensions that isolate one clean group. This is the
  right objective for anomaly-hunting and the wrong one for characterization, and
  characterization is the current use case. Worth revisiting when an
  anomaly-injection reward exists.
- _Unweighted mean_: simpler, and wrong in the specific way described above.
- _Entropy or variance reduction_: the textbook answer, and it presumes the metric
  is a variance. `SplitMetric` is normalized 0–1 per store precisely because a
  subscript walk's metric is not a variance, so a formula that assumes one cannot
  be the cross-store default.

## 2. What bounds candidate evaluation?

**Decision**: Two bounds, both reported when they bite. A per-decision peek cap
(`MaxPeeksPerDecision`, default 12), and within a dimension, evaluate at most the
first `MaxChildrenSampled` children (default 8) in declaration order,
extrapolating the remainder from the sampled ones.

**Rationale**: Scoring a dimension costs one peek per child, so cost is
`sum(children)` per decision — unbounded in a store's fanout. A `Colour` column
with 400 distinct values would spend 400 SQL aggregates on one decision. Peeks
are far cheaper than model calls, but "cheaper" is not "free", and an unbounded
loop inside a decision is a latency cliff waiting for a wide column.

Sampling in declaration order rather than randomly keeps the decision
deterministic, which Principle V requires — a random sample would make two runs
over the same store choose differently and destroy replay.

The reporting is the non-negotiable part. A dimension scored from 8 of 400
children is a dimension scored on partial evidence, and a decision record that
does not say so invites an evaluator to treat an estimate as a measurement. This
is Principle III applied to the policy rather than to a peek: same failure, same
remedy.

**Alternatives considered**:

- _No cap_: correct results, unbounded latency. Rejected on the wide-column case.
- _Cap the candidate dimensions instead of the children_: does not help. One wide
  dimension blows the budget even as the sole candidate.
- _Random sampling_: better statistically, breaks determinism. Rejected under
  Principle V.
- _Ask the store for its own fanout first and skip wide dimensions entirely_:
  tempting, and it silently removes the store's most informative dimension from
  consideration. A high-cardinality column is often the one that separates best.

## 3. Does the trace row extend, or gain a sidecar?

**Decision**: A sidecar. The `$LIST` row keeps its current ten fields and gains
nothing; the decision detail goes to `^||RLM.Trace(runId, seq, "d", ...)` with the
candidate records under `^||RLM.Trace(runId, seq, "d", "cand", n)`.

**Rationale**: A candidate list is variable-length and a `$LIST` row is
positional. Packing a nested list into field eleven means every reader has to
know that field eleven is itself a list of lists, and `$LIST` gives no help if
that assumption is wrong — it returns a garbage string rather than an error.

Subscripts also make replay natural. Enumerating alternative arms is
`$ORDER` over the candidate subscript, which is the operation the data shape
should make easy, since it is the operation User Story 3 exists for.

And it is additive in the strict sense the spec's last assumption requires: every
existing trace reader keeps working untouched, because no existing field changes
position or meaning. A row without a `"d"` subtree is a step that made no
decision, which is exactly true of a sub-call or a synthesis.

**Alternatives considered**:

- _Extend the `$LIST` row_: no schema migration, but couples every reader to a
  nested-positional layout, and `$List(row, 11)` on an old row returns "" rather
  than failing — a silent wrong answer.
- _A separate `^RLM.Decision` global keyed by run and seq_: same shape as the
  sidecar with an extra global to keep in sync, and two globals that must be
  deleted together is a leak waiting to happen.
- _JSON blob in one field_: readable, and it makes `$ORDER`-based enumeration
  impossible without parsing every row. The whole point of the subscript tree is
  that IRIS can walk it.

## Consequences for the design

- `RLM.Decision` carries: chosen dimension (or ""), decline reason, metric
  before, per-candidate records (dimension, score, child metrics, sampled flag,
  error), the policy class, and the peek count spent.
- `RLM.Policy` gets `ChooseSplit(source, peek, candidates, budget)` — the budget
  is a parameter because a policy that peeks must charge for it, and a policy that
  cannot see the budget cannot respect FR-008.
- Ties break by declaration order, documented in the contract as part of the
  determinism guarantee rather than as an implementation detail.
