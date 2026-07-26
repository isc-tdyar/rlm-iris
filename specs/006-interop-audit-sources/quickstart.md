# Quickstart: Interop and Audit sources

Two stores that are already in every IRIS instance: the interoperability message
flow and the audit log. Both sit on `RLM.Source.Extent`, which turns a dimension
declaration into SQL once so that the encoder and the decoder cannot drift apart.

Every figure below is what the code actually printed against a container holding
six planted message headers plus one pre-existing one, and a ten-row audit
fixture.

## The message flow

```objectscript
Set s = ##class(RLM.Source.Interop).%New()
Set dims = s.Dimensions()
```

```text
source (sending config): 4 children
target (receiving config): 3 children
status (message status): 4 children
hour (hour of day): 24 children
```

The first three are discovered from the data — a production's config names are
not knowable in advance, and a hardcoded menu would advertise children the
instance does not have. `hour` is derived: it offers 24 children over a store
spanning a week and 24 over one spanning an hour, so a policy's fanout is a
property of the dimension rather than of how long the production has been
running.

```objectscript
Set peek = s.Peek()
Write s.Describe("all messages", peek), !
Write s.SplitMetric(peek), !
```

```text
all messages: 7 message(s), 1 in error, 4 sending and 3 receiving config(s), busiest receiver BILLOUT
0.976
```

Counts and config names. No body id, no body class name, no description — the
columns that could carry message content are never selected, so there is nothing
to filter out later.

Narrowing to one sender:

```objectscript
Set sub = s.Peek(s.Predicate($ListBuild("source:HL7IN")))
```

```text
source HL7IN: 3 message(s), 1 in error, 1 sending and 2 receiving config(s), busiest receiver LABOUT
0.918
```

The metric is how mixed the slice's source-target routing is. It falls as the
slice narrows, and reaches 0 when every message in it takes the same route —
which is where a decomposition should stop.

## Refusing in the store's own terms

```objectscript
Write s.Ready(.reason), " ", reason, !
```

```text
1
```

A namespace without interoperability enabled is not a store with no rows:

```text
0 / namespace USER is not interoperability-enabled, so there is no message flow to decompose
```

That check runs before the count, because in such a namespace "no messages"
would be a true statement that sent the reader looking for a production instead
of at the namespace.

## The audit log

```objectscript
Set a = ##class(RLM.Source.Audit).%New()          // or over a fixture extent
Set peek = a.Peek()
```

```text
all events: 10 audit event(s), 4 user(s) in 2 namespace(s), most from alice (4)
0.935

facility %Ensemble: 2 audit event(s), 1 user(s) in 2 namespace(s), most from dave (2)
1
```

The metric is the normalized entropy of the slice's event types: 1 for a slice
holding two kinds of event one row each, 0 for a slice holding one kind.

`EventData`, `Description` and `UserInfo` are the most sensitive columns any
source in this project touches, and no method on `RLM.Source.Audit` reads any of
them. The end-to-end test plants a marker in all three and walks the finished
trace with `$QUERY` looking for it.

On this container the real log refuses:

```text
0 / %SYS.Audit holds no events, so there is nothing to divide
```

Auditing is switched on here, so an empty log genuinely means nothing was
recorded. With auditing off the refusal names that instead — the two are
different facts and only one of them is worth telling the reader to go fix.

## A run, and its replay

```objectscript
Set engine = ##class(RLM.Engine).%New(##class(RLM.Source.Interop).%New(),
    ##class(RLM.LLM.Null).%New(script),
    ##class(RLM.Budget).%New(32), ##class(RLM.Policy.Greedy).%New())
Set engine.DurableTrace = 1, engine.MaxDepth = 2
Set doc = engine.Run("how does this message flow divide?", .traceId)
```

```text
calls: 8  trace: 1
verify: 1
identical: 1  replay calls: 0  decisions: 2
```

The replay drives the real engine through the recorded model and the recorded
policy, so it traverses the same code as the run it reproduces.

## The scorecard

```text
policy                             calls peeks slices objective  chose       note
---------------------------------- ----- ----- ------ ---------  ----------  ----
RLM.Policy.Greedy                      8    24      7     0.000  status
RLM.Policy.LLM                         2     0      0        --  (declined)  run 3 examined no slice, so there is nothing to average
```

Greedy divides by `status` and reaches 0 — a perfectly separating split on this
flow. The LLM policy declined: the scripted reply names a dimension in prose
rather than as a token, the grammar refuses it, and the run examines no slice.
Reported as a decline with the reason, not as a zero. A policy that produced no
measurement is not a policy that scored badly, and the card says which.

## Reconciliation

```objectscript
Set parent = s.Peek().n
Set sum = 0
For h = 0:1:23 { Set sum = sum + s.Peek(hourTerm(h)).n }
Write parent, " ", sum, " ", s.NullCount("", "hour"), !
```

```text
parent=7 sum(hours)=6 gap=1
```

Six of the seven rows fall in an hour; the seventh has no `TimeCreated` and falls
in none. `NullCount` is what closes the gap, and the assertion is `=` with no
tolerance. A report whose figures do not add up is not a report that merely
rounds — it is Constitution III's concern.

## Running the suite

```bash
printf 'do $system.OBJ.LoadDir("/home/irisowner/dev/src","ck",,1)
set ^UnitTestRoot="/home/irisowner/dev/src/UnitTest"
do ##class(%UnitTest.Manager).RunTest("RLM","/noload/nodelete/norecursive")
halt
' | docker exec -i rlm-iris iris session IRIS -U USER
```

The `"ck"` qualifier is not optional. Without it the classes load without
compiling, the run uses whatever was compiled last, and it still prints
`All PASSED`.

300 tests, no provider, no network.

## What is not shared with `RLM.Source.Table`

`Table` predates `Extent` and was deliberately not re-parented onto it. It is
shipped, it has the largest test surface in the suite, and its output is asserted
byte for byte by the Gaia port tests. The duplication between the two is real and
is the price of not disturbing that.
