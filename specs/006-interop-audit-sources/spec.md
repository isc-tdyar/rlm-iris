# Feature Specification: Interop and Audit sources

**Branch**: `006-interop-audit-sources` | **Milestone**: M4 | **Status**: Draft

## Why this exists

`RLM.Source.Table` can already decompose any SQL extent, and both
`Ens.MessageHeader` and `%SYS.Audit` are SQL extents. So the honest question this
spec has to answer first is: what does a dedicated source give that a configured
`Table` does not?

Three things, and they are the whole feature:

1. **The dimensions are the domain.** A caller configuring `Table` over
   `Ens.MessageHeader` has to know that the interesting splits are source, target,
   status and hour-of-day, that `Status` is an enumerated integer whose numbers
   mean nothing to a reader, and that `TimeCreated` is a UTC string that has to be
   bucketed rather than enumerated. Getting any of that wrong produces a report
   that is confidently about the wrong thing.
2. **The metric is the domain.** "How mixed is this slice" means something
   different for a message flow (is this queue carrying one kind of traffic or
   several unrelated kinds?) than for a numeric measure's relative spread. A
   source that reused `Table`'s spread metric over a message count would be
   measuring nothing.
3. **The refusals are the domain.** A message flow with no messages, an audit log
   that is switched off, a namespace with no interop: each is a store that is
   present but not fit to report on, and each must refuse with a reason the caller
   can act on rather than average over whatever rows exist.

Neither source may return a message body or an audit event's detail. That is
Constitution I, and it is sharper here than anywhere else in the project: a
message body is PHI in most deployments, and an audit event's `EventData` is the
record of who saw what.

## User Scenarios

### US1 — Characterize a live production's message flow (P1)

An engineer on call has a production whose message volume has changed and no idea
which interface is responsible. They point an RLM run at the message header extent
and get back a document naming the busiest source-target pairs, the error
concentration, and where the traffic sits in the day — computed by IRIS over the
live headers, with no export and no message body read.

**Acceptance**

- Given a namespace holding interop message headers, when a run decomposes them,
  then the report names slices by source, target, status and time bucket, and
  reports counts and error rates per slice.
- Given the same run, when the trace is inspected, then no message body, body id,
  or body class name appears anywhere in it.
- Given a slice, when it is peeked, then the peek is answered by an aggregate over
  the extent and no row leaves the database.

### US2 — Refuse a store that is not fit to report on (P1)

**Acceptance**

- Given a namespace that is not interop-enabled, when readiness is asked, then it
  refuses naming that as the reason.
- Given an interop-enabled namespace with zero message headers, when readiness is
  asked, then it refuses saying the extent is empty, rather than reporting a
  document about 0 messages.
- Given a `Status` value the enumeration does not cover, when it is described, then
  it is labelled with its number and marked unknown rather than silently dropped.

### US3 — Characterize the audit log (P1)

A compliance reviewer wants the shape of a period's audit activity: which event
types dominate, which users and namespaces they came from, whether failures
cluster.

**Acceptance**

- Given an audit log with events, when a run decomposes it, then the report names
  slices by event source, event type, user and namespace with counts per slice.
- Given the same run, when the trace is inspected, then no `EventData`,
  `Description` or `UserInfo` content appears anywhere in it.
- Given a system with auditing disabled, when readiness is asked, then it refuses
  saying auditing is off — because an empty audit log on a system with auditing
  disabled is not evidence of no activity.

### US4 — Both sources are ordinary sources (P2)

**Acceptance**

- Given either source, when it is handed to `RLM.Engine` with `RLM.Policy.Greedy`,
  then it runs, traces, replays byte for byte and appears in a scorecard with no
  change to the engine, the policy or the evaluation classes.
- Given either source, when its source text is inspected, then it contains no
  reference to `%AI.*` — both are part of the portable module.

### US5 — Time is bucketed, not enumerated (P2)

A timestamp column has as many distinct values as it has rows, so enumerating it
as a dimension would offer the model a menu the size of the store.

**Acceptance**

- Given a timestamp-derived dimension, when its children are enumerated, then
  there is a fixed small number of them regardless of how many rows exist.
- Given a run over a store spanning several hours, when a time slice is peeked,
  then its count reconciles against its parent, with any rows the dimension cannot
  cover disclosed as a null count.

## Requirements

### Functional

- **FR-001** `RLM.Source.Interop` decomposes an interop message header extent
  through the `RLM.Source` contract.
- **FR-002** Its dimensions are, at minimum: source config name, target config
  name, status, and a bucketed hour-of-day. Each is discovered from the data
  except the bucketed one, whose children are declared.
- **FR-003** Its peek returns message count (`n`), error count, distinct source
  count, distinct target count, and the busiest source-target pair by count — and
  `capped` when a cap stopped the count.
- **FR-004** Its peek never reads `MessageBodyId`, `MessageBodyClassName` or any
  body class, and never returns a `Description`.
- **FR-005** Its split metric is the normalized entropy of the slice's
  source-target pair distribution: a slice carrying one kind of traffic is one
  population; a slice mixing many is not.
- **FR-006** `Ready` refuses, with a reason, when the namespace is not
  interop-enabled or the extent is empty.
- **FR-007** `RLM.Source.Audit` decomposes an audit log extent through the same
  contract.
- **FR-008** Its dimensions are, at minimum: event source, event type, username
  and namespace, discovered from the data.
- **FR-009** Its peek returns event count (`n`), distinct-user count,
  distinct-namespace count, and the dominant event type by count.
- **FR-010** Its peek never reads `EventData`, `Description` or `UserInfo`.
- **FR-011** Its split metric is the normalized entropy of the slice's event-type
  distribution.
- **FR-012** `Ready` refuses, with a reason, when auditing is disabled or the log
  is empty. Auditing-disabled is a distinct reason from empty, because the two mean
  different things about the same zero.
- **FR-013** Both sources report a null count for any dimension whose children
  cannot cover every row in the parent, so a report's slice counts reconcile.
- **FR-014** Both sources' enumerated status and type codes are described with a
  human label; a code the enumeration does not cover is described with its raw
  value and marked unknown rather than dropped.
- **FR-015** Both sources are read-only. No supported path writes to the extent
  they read.
- **FR-016** Both accept an alternative class name so a caller — including a test —
  can point them at a same-shaped extent. The default is the real one.
- **FR-017** Both are in the portable module: no `%AI.*` dependency.

### Non-functional

- **NFR-001** Peek cost is bounded by a configurable row cap, and a capped count
  is reported as a floor in the described text.
- **NFR-002** A peek's serialized size does not grow with the size of the slice.
- **NFR-003** Every test runs with no provider and no network, using
  `RLM.LLM.Null`.

## Success Criteria

- **SC-001** A run over a populated message header extent produces a report whose
  slice counts sum to the root count plus the disclosed null count, exactly.
- **SC-002** A `$QUERY` walk of a completed run's trace finds no message body id,
  body class name, audit event data or audit description anywhere in it.
- **SC-003** Both sources replay byte for byte through `RLM.Replay`.
- **SC-004** Both sources appear as rows in an `RLM.Eval.Scorecard` with Greedy and
  the LLM policy, with no change to the scorecard.
- **SC-005** Every refusal case returns 0 from `Ready` with a non-empty reason
  naming which condition failed.
- **SC-006** The suite stays green and grows by the tests this feature adds, with
  no prior test edited.

## Assumptions

- The container's namespace is interop-enabled, so `Interop` tests insert real
  `Ens.MessageHeader` rows and delete them afterwards. Verified in the container:
  `%EnsembleMgr.IsEnsembleNamespace` returns 1 and a header saves.
- The container's audit log is empty and auditing is disabled. `Audit` tests
  therefore run against a same-shaped fixture extent via FR-016, and the
  auditing-disabled refusal is tested against the real `%SYS.Audit` — the one
  assertion an empty container makes easy rather than hard.
- Writing audit events from a test is out of scope: enabling system auditing to
  populate a log is a system-wide configuration change, not a test fixture.

## Out of scope

- Reading or classifying message bodies, in any form.
- A production-configuration source (business hosts, settings, queue depths). That
  is a different store with different dimensions.
- Live monitoring, alerting or any scheduled run.
- Writing to either extent, purging, or resending a message.
