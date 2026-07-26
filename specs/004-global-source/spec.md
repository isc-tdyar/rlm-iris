# Feature Specification: RLM.Source.Global

**Feature Branch**: `004-global-source`
**Created**: 2026-07-25
**Status**: Draft
**Input**: M2 from [docs/SPEC.md](../../docs/SPEC.md) §4.1 and §7

## Why this milestone exists

SPEC §4.1 ranks four sources by what is only possible in IRIS and puts `Global`
first: "No schema exists; no external engine can enter." It shipped second
because gaia-iml needed `Table`. Everything the package claims is most true here,
because a global is the one store where there is no schema to read, no catalog to
query, and no export that fits anywhere.

The motivating case is an undocumented global nobody owns, under a decision to
archive it. The structure lives in the routine that writes it, that routine is
what is being retired, and sampling the first N nodes describes the year the
global was created rather than the decade the decision turns on.

## User Scenarios & Testing _(mandatory)_

### User Story 1 - Characterize a global with no schema (Priority: P1)

An operator points a run at `^SomeGlobal` and asks what is in it. The engine
peeks the root, gets aggregates over a bounded walk, splits on the first
subscript level, peeks each child, and produces a report naming the shape of each
region of the global. No node value ever reaches a prompt.

**Why this priority**: This is the milestone. Without it `Global` is a table row
in the README.

**Independent Test**: Build a synthetic global with known structure in
`^||RLMTest`, run a decomposition with `RLM.LLM.Null`, and assert the peek
figures equal hand-computed values and the report names every child.

**Acceptance Scenarios**:

1. **Given** a global with 4 distinct first-level subscripts, **When** the source
   is asked for `Dimensions()`, **Then** it returns one dimension whose children
   are exactly those 4 subscripts, each with a token and a label.
2. **Given** a peek of the root, **When** its figures are compared against a
   hand-counted walk of the fixture, **Then** node count, distinct subscript
   count, data-node count and pointer-node count all match exactly.
3. **Given** a slice naming one first-level subscript, **When** it is peeked,
   **Then** the count covers that subtree only and the children of all slices sum
   to the root count.
4. **Given** any peek, **When** the prompt built from it is inspected, **Then**
   no value stored at any node appears in it.

---

### User Story 2 - A walk that stopped early says so (Priority: P1)

A real global is larger than any walk that should run inside a peek. The walk
stops at a visit cap and the peek reports that it stopped, so every figure
derived from it reads as a floor rather than a total.

**Why this priority**: Constitution III, non-negotiable, and the specific failure
the SPEC cites from the published RLM walkthrough. A capped count presented as a
total corrupts every downstream claim in the report.

**Independent Test**: Set the cap below the fixture's node count and assert
`capped` is 1, the count equals the cap, and the rendered description words the
figure as a floor.

**Acceptance Scenarios**:

1. **Given** a global with 500 nodes and a visit cap of 100, **When** it is
   peeked, **Then** `capped` is 1 and `n` is 100.
2. **Given** a capped peek, **When** it is described, **Then** the text contains
   the cap disclosure and does not present `n` as a total.
3. **Given** a global with 50 nodes and a cap of 100, **When** it is peeked,
   **Then** `capped` is 0 and `n` is 50.
4. **Given** a run where any peek was capped, **When** the report is produced,
   **Then** the caveats section names the capping.

---

### User Story 3 - A refused global costs nothing (Priority: P1)

The source refuses to read a global outside a configured allowlist, and refuses
the system and structural globals by default. A refusal happens before any model
call and before any walk.

**Why this priority**: Read access to arbitrary globals is the feature's largest
liability. Fail-closed is the only defensible default, and it must be enforced at
construction rather than at peek time, so no partially-authorized run exists.

**Independent Test**: Construct the source against `^ROUTINE` and against a
global absent from the allowlist; assert both refuse, that the refusal names the
pattern that matched, and that no walk ran.

**Acceptance Scenarios**:

1. **Given** default configuration, **When** the source is constructed against
   `^%cspSession`, `^ISCLOG`, `^rMAP`, `^ROUTINE` or `^oddDEF`, **Then**
   construction fails with a reason naming the refused pattern.
2. **Given** an allowlist of `^Sales*`, **When** the source is constructed
   against `^SalesOrder`, **Then** it succeeds; against `^Inventory`, it fails.
3. **Given** a global reference naming another namespace or an implied path,
   **When** construction is attempted, **Then** it is refused.
4. **Given** any refusal, **When** a run is attempted with that source, **Then**
   the report states the refusal and the model call count is 0.

---

### User Story 4 - Fanout entropy drives the split (Priority: P2)

The policy needs a normalized 0–1 scalar to compare candidate splits. For a
subscript walk that scalar is the entropy of the child-count distribution: a
level where nodes spread evenly across many subscripts is mixed; one where a
single subscript holds almost everything is not.

**Why this priority**: `RLM.Policy.Greedy` already works over any source that
supplies the scalar, so this is what makes the existing policy work on globals
with no policy change. It is P2 only because P1 delivers a working decomposition
under `RLM.Policy.LLM` without it.

**Independent Test**: Build two fixtures, one with evenly distributed children
and one where 95% of nodes sit under one subscript, and assert the even one
scores near 1 and the skewed one near 0.

**Acceptance Scenarios**:

1. **Given** a slice whose children hold equal node counts, **When**
   `SplitMetric` is called, **Then** it returns a value above 0.9.
2. **Given** a slice where one child holds 95% of nodes, **When** `SplitMetric`
   is called, **Then** it returns a value below 0.3.
3. **Given** a slice with exactly one child, **When** `SplitMetric` is called,
   **Then** it returns 0, and `ShouldSplit` is false.
4. **Given** the same fixture peeked twice, **When** the metrics are compared,
   **Then** they are identical, because a peek is a pure function of the store.

---

### User Story 5 - Subscript shape, not subscript content (Priority: P2)

The peek reports what the subscripts and values look like without reporting what
they are: how many are canonical numeric, how many are strings, how many look
like `$LIST` structures, and the mean and standard deviation of value lengths.

**Why this priority**: This is what lets a model say "the second subscript is a
date and the third is a facility code" without being shown a date or a facility
code. It is the whole reason a schema-less store is characterizable at all.

**Independent Test**: A fixture with known type mix and known value lengths;
assert every reported figure against hand-computed values.

**Acceptance Scenarios**:

1. **Given** a fixture with 3 numeric and 2 string subscripts at a level, **When**
   it is peeked, **Then** the type mix reports exactly 3 and 2.
2. **Given** values of known lengths, **When** they are peeked, **Then** the mean
   and standard deviation match hand-computed values within 0.01.
3. **Given** a fixture holding `$LIST` values, **When** it is peeked, **Then**
   they are counted as list-shaped and their contents are not reported.
4. **Given** any peek, **When** its serialized size is measured, **Then** it is
   under 2,000 characters regardless of how many nodes the walk visited.

### Edge Cases

- A global that does not exist: peek returns `n` of 0 and the report says the
  global is empty, rather than failing.
- A global with data at the root node and no subscripts: one node, no dimension,
  nothing to split, reported as such.
- A subscript containing a comma, a quote, or a `)`: must round-trip through a
  slice token without changing which node it names, or be refused. It must never
  produce a reference that names a different node.
- A subtree deeper than the depth cap: depth reached is reported and the walk
  does not recurse further.
- Two children whose node counts sum to less than the parent's: impossible for an
  enumerated dimension, so `NullCount` stays 0 and the figures must reconcile
  exactly. A test asserts the reconciliation.
- A global mutating during a walk: out of scope for this milestone; the peek is
  documented as a point-in-time floor and evaluation uses a frozen store.

## Requirements _(mandatory)_

### Functional Requirements

- **FR-001**: `RLM.Source.Global` MUST extend `RLM.Source` and implement
  `Dimensions`, `Predicate`, `Peek`, `Describe` and `SplitMetric`.
- **FR-002**: The source MUST be constructed with a global reference and MUST
  refuse construction if that reference is not permitted by the allowlist.
- **FR-003**: The allowlist MUST be fail-closed: a reference matching no allow
  pattern is refused. `^%*`, `^ISC*`, `^rMAP`, `^ROUTINE*` and `^odd*` MUST be
  refused by default even if an allow pattern would otherwise match.
- **FR-004**: References naming another namespace, an extended global reference,
  or an implied namespace MUST be refused.
- **FR-005**: Every walk MUST be bounded by a visit cap and a depth cap, both
  configurable, with documented defaults.
- **FR-006**: `Peek` MUST set `capped` to 1 when either cap stopped the walk, and
  MUST NOT report a capped count in a way that reads as a total.
- **FR-007**: `Peek` MUST report node count, depth reached, distinct next-level
  subscript count, the top few subscripts by fanout, data-node and pointer-node
  counts, value length mean and standard deviation, and the subscript type mix.
- **FR-008**: `Peek` MUST NOT include any stored value or any full subscript
  value in its output except the next-level subscript tokens, which are the legal
  moves and are required by Principle II.
- **FR-009**: `SplitMetric` MUST return the normalized entropy of the child node
  count distribution, in [0,1], and MUST return 0 for a slice with fewer than two
  children.
- **FR-010**: All global access MUST be read-only. No code path may write, kill,
  or lock a node in the target global.
- **FR-011**: `Peek` MUST return an object with an `error` property rather than
  throwing, so a failed peek costs one call and not the report.
- **FR-012**: A slice token MUST resolve back to exactly the subscript it came
  from, for every subscript the fixture contains, or be refused at enumeration
  time.

### Key Entities

- **Global reference**: the target store, a global name with an optional
  subscript prefix, validated once at construction.
- **Visit budget**: the node cap and depth cap governing a single walk, separate
  from `RLM.Budget`, which counts model calls.
- **Peek**: the aggregate record for one slice, bounded in size independently of
  the subtree it describes.
- **Allowlist**: the set of permit patterns plus the unconditional deny set.

## Success Criteria _(mandatory)_

### Measurable Outcomes

- **SC-001**: A decomposition of a synthetic global completes with
  `RLM.LLM.Null` and produces a report naming every child slice, with no live
  model.
- **SC-002**: Peek output stays under 2,000 characters for a 50-node global and
  for a 500,000-node global, measured by multiplying a fixture and comparing
  serialized lengths.
- **SC-003**: Child node counts sum exactly to the parent count on an uncapped
  walk, asserted arithmetically rather than by eye.
- **SC-004**: Every default-denied pattern is refused, one test per pattern.
- **SC-005**: No test requires a network call or an API key; the whole suite runs
  on a base IRIS container.
- **SC-006**: A value stored at exactly one node in the fixture appears in no
  prompt and no peek, asserted by searching the built prompt for that value.

## Assumptions

- The target for this milestone is a process-private global (`^||`) in tests, and
  any allowlisted global in the current namespace at runtime. Cross-namespace
  reads are out of scope and refused.
- A walk uses `$ORDER` and `$QUERY` with indirection. `%SYS.GlobalQuery` block
  estimates are noted in SPEC §8 as possibly cheaper for the count; they are not
  relied on here, because their signatures need verifying and a capped walk is
  correct without them.
- The visit cap default is 50,000 nodes, matching the figure the SPEC uses. The
  depth cap default is 8.
- "Distinct subscripts at the next level" means the immediate children of the
  slice, not distinct values across the whole subtree.
- `RLM.Policy.Greedy`, `RLM.Slice`, `RLM.Budget`, `RLM.Trace` and `RLM.Report`
  are unchanged by this feature. If any needs a change, that is a finding worth
  recording, since the point of the seams is that a new source does not touch
  them.
