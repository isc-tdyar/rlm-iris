# Implementation Plan: Interop and Audit sources

**Branch**: `006-interop-audit-sources` | **Spec**: [spec.md](spec.md) | **Milestone**: M4

## Technical Context

- **Language**: InterSystems ObjectScript, IRIS 2026.1 in container `rlm-iris`.
- **Module**: `rlm-core` — the portable one. No `%AI.*`, no HTTP.
- **Tests**: `%UnitTest`, `RLM.LLM.Null` only. Baseline is 265 passing.
- **Stores under test**: `Ens.MessageHeader` (writable in the container's
  interop-enabled USER namespace) and `%SYS.Audit` (present, empty, auditing off).

## Architecture

### The shared piece: `RLM.Source.Extent`

Both new sources are SQL extents split by categorical columns plus one derived
bucketed column. `RLM.Source.Table` already contains that plumbing — dimension
declaration, `Predicate` term encoding, the `Where` decoder, `SQLTable`, `Column`,
`Query`, `NullCount` — but it also contains a peek and a metric that mean nothing
for a message flow.

So the plumbing moves into a new abstract `RLM.Source.Extent` that `Interop` and
`Audit` extend, and `Table` is left alone.

Not refactoring `Table` onto the new base is a deliberate call, recorded here
because it is the kind of decision that looks like laziness later. `Table` is
shipped, has the largest test surface in the suite, and its behaviour is asserted
byte for byte by the Gaia port tests. Re-parenting it to gain roughly eighty lines
of shared code would put every one of those assertions at risk for no behaviour
change. The duplication is real and is the price; the class comment on `Extent`
says so, so the next person does not think it was missed.

### `RLM.Source.Interop`

- Extent defaults to `Ens.MessageHeader`; overridable per FR-016.
- Dimensions: `source` (`SourceConfigName`), `target` (`TargetConfigName`),
  `status` (`Status`, enumerated), `hour` (bucketed over hour-of-day derived from
  `TimeCreated`).
- `hour` is bucketed with declared children rather than enumerated, because
  `TimeCreated` has one distinct value per message. Buckets are derived in SQL from
  the timestamp; the tokens are ordinals, so a relabelling does not invalidate a
  trace.
- Peek: `n`, `errors`, `sources`, `targets`, `busiest` (`{source, target, n}`),
  `capped`. The busiest pair comes from a `TOP 1 … GROUP BY … ORDER BY COUNT(*)
  DESC`, and the pair distribution for the metric comes from a bounded `TOP k GROUP
  BY` — bounded so a slice with ten thousand distinct pairs costs the same peek as
  one with three.
- Split metric: normalized entropy of the pair distribution, with a remainder
  bucket for everything past the top k, exactly as `Global.SplitMetric` handles a
  truncated fanout list. Understating evenness is the safe direction.
- `Ready`: refuses when the namespace is not interop-enabled, then when the extent
  is empty. Two conditions, two reasons, checked in that order — the cheaper and
  more fundamental one first.

### `RLM.Source.Audit`

- Extent defaults to `%SYS.Audit`; overridable per FR-016, which is what makes it
  testable in a container whose audit log is empty.
- Dimensions: `eventsource` (`EventSource`), `eventtype` (`EventType`),
  `username` (`Username`), `namespace` (`Namespace`).
- Peek: `n`, `users`, `namespaces`, `dominant` (`{type, n}`), `capped`.
- Split metric: normalized entropy of the event-type distribution.
- `Ready`: refuses when auditing is disabled, then when the log is empty — and
  those are two distinct reasons about the same zero, which is the point of
  FR-012. Auditing state is read through `$SYSTEM.Security` rather than a global,
  and a source pointed at a fixture extent skips the auditing check because the
  fixture is not the audit log.

### What neither source touches

`MessageBodyId`, `MessageBodyClassName`, `Description`, `EventData`, `UserInfo`.
Not "is not currently selected" — the select lists are assembled from a fixed set
of column names in these two classes, and a test walks a finished trace with
`$QUERY` asserting none of that content appears in it.

## Phases

| Phase | Content                                        | Gate                                        |
| ----- | ---------------------------------------------- | ------------------------------------------- |
| 1     | `RLM.Source.Extent` + its unit tests           | Extent tests pass                           |
| 2     | US1 `RLM.Source.Interop` peek/dims/metric      | Interop unit tests pass                     |
| 3     | US2 Interop readiness refusals                 | refusal tests pass                          |
| 4     | US3 `RLM.Source.Audit`                         | Audit unit tests pass                       |
| 5     | US5 time bucketing + reconciliation            | counts reconcile exactly                    |
| 6     | US4 E2E: engine, replay, scorecard, no-leak    | full suite green, feature gate              |

Phase order puts the shared base first because both sources need it, and puts the
E2E gate last because it is the only phase that asserts the milestone claim rather
than a seam.

## Testing strategy

- **Interop** tests insert real `Ens.MessageHeader` rows in `OnBeforeOneTest` and
  delete exactly those ids in `OnAfterOneTest`. Real rows rather than a fixture,
  because the enumerated `Status` datatype and the UTC timestamp format are two of
  the three things this source exists to know about, and a fixture would let a
  wrong assumption about either pass.
- **Audit** tests use a fixture persistent class with the same column shape,
  pointed at through FR-016. The real `%SYS.Audit` is used for exactly one
  assertion: that a disabled audit log refuses.
- **Leak** tests walk the trace with `$QUERY` for planted marker strings, the same
  shape as `ReplayMismatch.TestTheFingerprintDoesNotContainStoreContents`.
- **Reconciliation** tests sum child counts and compare against parent plus null
  count with `=`, not a tolerance.

## Risks

- **Ens.MessageHeader is not a plain table.** It has an ownership/queue model and
  properties that are populated by the framework. Mitigated by only ever writing
  the four properties the dimensions read, and by asserting the row count after
  insert rather than assuming it.
- **A test that fails to clean up leaves rows in a live extent.** Cleanup deletes
  by recorded id in `OnAfterOneTest`, and a leaked row would surface immediately as
  a count assertion failure in the next test rather than silently.
- **Auditing might be enabled on someone else's machine.** The readiness test
  asserts the refusal *reason matches the actual state* rather than asserting a
  fixed 0, so it holds either way.
