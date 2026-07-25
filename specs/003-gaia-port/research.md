# Research: Port the gaia-iml prototype onto rlm-iris

Every figure below was measured in `gaia-iml-iris` against
`SQLUser.GaiaQualityScored` (74,998 rows) on 2026-07-25, not estimated.

## Decision 1: how the library reaches the prototype — git submodule

**Decision**: `gaia-iml` gains a submodule at `lib/rlm-core` pinned to a commit
of `isc-tdyar/rlm-iris`. `iris.script` adds one `LoadDir` over
`lib/rlm-core/src`, and `module.xml` declares `rlm-core` under `<Dependencies>`
for anyone installing through IPM.

**Rationale**: `%ZPM.PackageManager` does not exist in the AI-preview image the
prototype builds on — checked, `<CLASS DOES NOT EXIST>` — so IPM cannot be the
delivery mechanism for the container that actually runs. The `Dockerfile` does
`COPY . .`, so anything inside the repository tree arrives; a submodule is inside
the tree when cloned with `--recursive` and is a pinned reference rather than a
copy, which is what FR-013 asks for. The manifest dependency still exists for the
IPM path, so both routes name the same version.

**Alternatives considered**:

- _Copy `src/RLM/` into `gaia-iml`._ Rejected by FR-013. Two copies of a library
  under active development diverge, and the divergence is silent: the prototype
  would keep passing against a stale engine.
- _Mount `../rlm-iris/src` as a second compose volume._ Works on this laptop and
  nowhere else. The prototype is a contest submission that a judge clones and
  builds; a compose file referencing a sibling directory outside the repository
  fails on the first `docker compose up` anyone else runs.
- _Install through IPM at build time._ Blocked by the missing package manager.

## Decision 2: the provider is an AI Hub adapter, not `RLM.LLM.REST`

**Decision**: `Gaia.LLM.AIHub Extends RLM.LLM` holds a private
`Gaia.LLM.Agent Extends %AI.Agent` carrying the prototype's existing `PROVIDER`,
`MODEL` and `APIKEY` parameters. `Complete()` does `%Init` / `CreateSession` /
`Chat` inside a `Try`/`Catch` and returns `""` with a status on any failure.

**Rationale**: `RLM.LLM.REST` against `OPENAI_API_KEY` would work — the key is
present in the container — and would need no new class at all. It is the wrong
choice anyway: the whole claim under test is that `RLM.Engine` depends on no
`%AI.*` class, and that claim is only exercised by a run whose provider _is_ an
`%AI.*` class. Using REST would prove the engine works with the transport it
was written against, which nobody doubted.

**Alternatives considered**:

- _`RLM.LLM.REST`._ See above. Also loses the prototype's model pinning, which
  its reports quote.
- _Make `Gaia.RLM` itself the provider_ (it currently `Extends %AI.Agent`).
  Rejected: `Gaia.RLM` becomes the entry point that owns an engine, and an entry
  point that is also a provider cannot be handed a scripted provider for tests.

**Consequence**: `%AI.Agent.Chat` exposes no temperature, so this provider is not
deterministic. Determinism (SC-003) is asserted with `RLM.LLM.Null` only. That
was already true of the prototype and is recorded in the spec's assumptions.

## Decision 3: `Triage`'s scope needs a sixth dimension, and that is the finding

**Measured**: `pct_change > 100` selects 57,099 rows. `pct_change >= 100` selects
the same 57,099 — no row sits exactly on 100, nor on 1,000, nor on 100,000, so the
prototype's `>` boundaries and the library's half-open `>=` buckets select
identical populations. The bucket populations are 17,899 / 17,204 / 31,224 / 8,671,
summing to 74,998 with a null count of 0.

**The problem**: `Triage`'s scope is the union of the top three `variability`
buckets. `RLM.Slice` names one child per dimension by design — that is what makes
every name resolve by construction — so a union of siblings is not expressible,
and must not be made expressible.

**Decision**: declare a sixth dimension, `detection`, over the same column with
a single breakpoint at 100: two children, `pct_change < 100` (17,899) and
`pct_change >= 100` (57,099). `Triage` scopes to `detection:b1`, which is exactly
the population it has always described. `variability` stays as it is.

**Rationale**: this is not a workaround, it is the defect the port exposed in the
prototype. The challenge asks a binary question — is this source variable? — and
the prototype answered it with a magnitude dimension, which is why its own
`Triage` had to reach around the grammar with a raw SQL string. Two dimensions
over one column is legal and useful: inside `detection:b1` the engine can still
offer `variability` to subdivide the detections by swing size.

**Alternatives considered**:

- _Retarget `Triage` at `variability:b2`_ (31,224 rows, the largest single child).
  Rejected: it silently changes which population the report describes, and a
  report that quietly narrows its own subject is the failure mode this library
  exists to prevent.
- _Let `rootPath` accept a predicate._ Rejected: it puts a SQL string back on the
  engine's public surface and breaks constitution principle II.
- _Let a path name several siblings._ Rejected: every downstream label, trace row
  and child-predicate computation assumes one child per dimension.

**Consequence**: inside `detection:b1`, splitting on `variability` yields an empty
`b0`. That is the empty-slice edge case the spec already names, now with a
concrete instance to test against.

## Decision 4: the slice count is 20 children over 5 dimensions, not 21

**Measured**: three breakpoints per dimension yield four children;
5 × 4 = 20. The "21 slices" figure carried into the spec from the earlier survey
does not reconcile with the prototype's own `Dimensions()`, which declares five
dimensions of four children each.

**Decision**: SC-001 asserts the count computed from `Dimensions()` and reports
it, rather than asserting a constant. After the `detection` dimension lands the
figure is 6 dimensions and 22 children. `spec.md` is corrected rather than
left to be reconciled later.

**Rationale**: an assertion against a remembered number is how a wrong number
survives. This is the same rule T056 established in the previous feature —
success criteria print measured figures.

## Decision 5: `SplitMetric` needs a run-scoped baseline

**Prototype behaviour**: `BaselineSpread()` computes the survey-wide
reject-fraction standard deviation once and caches it in a class variable for the
life of the process. `ShouldRecurse` compares a slice's spread against it and
also requires the slice to hold at least 400 rows.

**Decision**: `Gaia.Source` computes the baseline lazily on first use and caches
it in an instance property. The engine holds one source for the life of a run, so
instance scope is run scope, and two concurrent runs cannot see each other's
figure.

**Rationale**: the class-variable version leaks across runs in a process that
serves more than one, and the cached value would be silently stale after an
ingest. Instance scope needs no library change, which is the point — the seam was
already right.

**Alternatives considered**:

- _Recompute per slice._ One extra full-table aggregate per decision, against a
  75,000-row table, for a figure that cannot change during a run.
- _Add a run-scoped cache to `RLM.Source`._ Rejected: nothing outside Gaia has
  asked for one, and a source that wants one already has instance properties.

## Decision 6: what the tests are, and where they run

**Decision**: three new `%UnitTest` classes in `gaia-iml` under
`src/UnitTest/Gaia/` — `Source.cls`, `LLM.cls`, `Port.cls` — run in
`gaia-iml-iris` with the same `"ck"` load qualifier the library's suite uses:

```bash
printf 'do $system.OBJ.LoadDir("/home/irisowner/dev/lib/rlm-core/src","ck",,1)
do $system.OBJ.LoadDir("/home/irisowner/dev/src","ck",,1)
set ^UnitTestRoot="/home/irisowner/dev/src/UnitTest"
do ##class(%%UnitTest.Manager).RunTest("Gaia","/noload/nodelete/norecursive")
halt
' | docker exec -i gaia-iml-iris iris session IRIS -U USER
```

**Rationale**: the `"ck"` qualifier is mandatory for the same reason it is in
`rlm-iris` — without it classes import without compiling and `%UnitTest` skips
them while printing "All PASSED". The library directory loads first because the
prototype's classes extend its classes. The existing `UnitTest.Gaia.RLM2` suite
stays in place and must keep passing, which is what proves US4 did not break the
delegating variant.

**Alternatives considered**:

- _Run the port's tests in `rlm-iris`._ Impossible: the table is in the other
  container, and crossing containers is forbidden.

## Decision 7: `SplitMetric`'s clamp, and the two metrics that must not be confused

**Prototype behaviour**: the recursion test is `slice_spread >= survey_spread`,
i.e. a ratio at or above 1.0 (`SPLITRATIO = 1.0`), with a 400-row floor.
`RLM.Source.ShouldSplit`'s default is `SplitMetric(peek) > 0.15` on a 0-1 scale.

**Decision**: `SplitMetric()` returns `min(1, slice_spread / survey_spread)` and
`ShouldSplit()` is overridden to `(SplitMetric(peek) >= 1) && (peek.n >= 400)`,
ignoring the inherited threshold argument.

**Rationale**: the two are different questions and collapsing them loses the
prototype's rule. `SplitMetric` answers "how mixed is this slice" for the policy
to compare candidates on; `ShouldSplit` answers "is subdividing worth a model
call" and carries the size floor. Overriding both is what the library's contract
invites, and the clamp is required because the library documents `SplitMetric` as
0-1 and `RLM.Policy.Greedy` size-weights it.

**Consequence**: a slice whose spread exceeds the survey's clamps to exactly 1,
so `Greedy` cannot rank two such slices against each other. Acceptable — the
prototype's rule could not either, and the default policy for the port is
`RLM.Policy.LLM`, matching what the prototype used.
