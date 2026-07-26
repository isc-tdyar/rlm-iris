# Quickstart: replay and offline evaluation

Every figure below is what the suite produces on the fixtures in
`src/UnitTest/RLM`. Nothing here reaches a network.

## Record a run you can replay later

A run is replayable only if it wrote a durable trace. That is one property.

```objectscript
Set source = ##class(RLM.Source.Global).%New("^||RLMTest", "^||RLM*", .sc)
Set engine = ##class(RLM.Engine).%New(source, llm, ##class(RLM.Budget).%New(32),
    ##class(RLM.Policy.Greedy).%New())
Set engine.DurableTrace = 1
Set engine.MaxDepth = 2
Set report = engine.Run("what is in this global?", .traceId)
```

That run spends 8 model calls and 8 peeks over the fixture global.

## Replay it

```objectscript
Set replay = ##class(RLM.Replay).%New(source, traceId)
If 'replay.Verify(.reason) { Write "refused: ", reason, ! Quit }
Do replay.Run(.replayed)
Write (replayed = report), " ", replay.Calls, " calls, ", replay.Decisions, " decisions", !
```

Prints `1 0 calls, 2 decisions`. The document is byte-identical and no provider
was contacted: `RLM.LLM.Recorded` serves the recorded text and
`RLM.Policy.Recorded` serves the recorded decisions, keyed by slice path, while
the real `RLM.Engine` does the traversal.

## What a moved store looks like

```objectscript
Set ^||RLMTest("2019-11-04", "BOS-GEN", 99) = "mutated"
Write replay.Verify(.reason), " ", reason, !
```

Prints `0 the store no longer matches the trace: it was 1791394828 when the run
was recorded, is 384503498 now`. `Run` refuses too, and returns a report saying
it was not run rather than a document that looks reproduced.

The fingerprint is derived from the peeks, never from the contents, so no trace
node holds a value out of the store. The cost of that is real: a mutation no peek
can see — same node, same value length, different bytes — does not refuse.
`UnitTest.RLM.ReplayMismatch` asserts both halves.

## Enumerate the arms a run did not take

```objectscript
Set arms = ##class(RLM.Eval.Arms).Enumerate(source, traceId)
Write arms.arms.%Size(), " arms, ", arms.calls, " calls", !
```

Over a global this prints `0 arms, 0 calls`, and that is correct rather than
broken: a global offers exactly one dimension per subscript level, so there is no
alternative to have taken. Over a store with two independent dimensions the same
call returns scored arms.

## Score policies against each other

```objectscript
Set policies = $ListBuild("RLM.Policy.Greedy", "RLM.Policy.LLM",
    "UnitTest.RLM.PolicyBad")
Set card = ##class(RLM.Eval.Scorecard).Score(source, question, policies, llm)
Write ##class(RLM.Eval.Scorecard).Render(card), !
```

```text
policy                             calls peeks slices objective  chose
---------------------------------- ----- ----- ------ ---------  ----------
RLM.Policy.Greedy                      3     4      2     0.100  region
RLM.Policy.LLM                         4     0      2     0.100  region
UnitTest.RLM.PolicyBad                 3     4      2     0.540  channel
```

Lower objective is better: it is the mean split metric of the leaf slices the run
was left holding, read from the trace's own rows. The model picks the dimension
Greedy picks and pays a call for it. The control policy maximizes the metric
instead of minimizing it and scores 0.540, which is what makes the tie a result.

Cost and objective stay in separate columns. There is no combined score, because
weighing a model call against a metric point is the reader's call and nobody has
chosen those weights.

A row that cannot be scored carries its reason and does not take the card down
with it: an unknown class, a run whose budget ran out mid-traversal, a sub-call
that failed, a store that divides nothing. A partial run gets no objective at
all, because 0 already means "every leaf was one population".

## Run the suite

```bash
printf 'do $system.OBJ.LoadDir("/home/irisowner/dev/src","ck",,1)
set ^UnitTestRoot="/home/irisowner/dev/src/UnitTest"
do ##class(%UnitTest.Manager).RunTest("RLM","/noload/nodelete/norecursive")
halt
' | docker exec -i rlm-iris iris session IRIS -U USER
```

265 tests, no provider, no key. The `"ck"` qualifier is not optional: without it
classes load without compiling and the run still reports every test passing.
