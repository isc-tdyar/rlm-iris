# Quickstart: decomposing a global

Everything below is copied from a real run in the `rlm-iris` container. The
figures are what the suite produces, not what the design intended.

## The store

`^||RLMTest` is the test fixture — 21 nodes, three levels, five first-level
subscripts, built by `UnitTest.RLM.FixtureGlobal`. It stands in for the global
this feature exists for: no schema, no class definition, no SQL projection, and
nobody left who remembers the subscript layout.

## Point a source at it

```objectscript
Set src = ##class(RLM.Source.Global).%New("^||RLMTest", "^||RLM*", .sc)
```

The second argument is the allowlist and it is not optional in practice: with an
empty one the source refuses everything. The deny set (`^%*`, `^ISC*`, `^rMAP*`,
`^ROUTINE*`, `^odd*`) is checked after the allowlist and wins, so `"^*"` still
cannot reach `^ROUTINE`.

Refusal happens in `%OnNew`, and `%New` discards the instance when `%OnNew`
returns an error. A refused source does not exist:

```objectscript
Set src = ##class(RLM.Source.Global).%New("^ROUTINE", "^*", .sc)
Write $IsObject(src)                        // 0
Write $System.Status.GetErrorText(sc)
// '^ROUTINE' matches the denied pattern '^ROUTINE*'; the deny set is not overridable
```

## What one peek says

```objectscript
Write src.Describe("^||RLMTest", src.Peek(""))
```

```text
^||RLMTest
  nodes: 21
  depth reached: 3
  immediate children: 5
  busiest children: 2019-11-04 (8), 7 (3), 42 (3), 2020-03-11 (3), a,b (3)
  node kind: 43% data, 57% pointer
  value length: mean 5, sd 2.45
  subscript types: 2 numeric, 3 string, 0 list
```

Not one stored value appears in it. The subscripts do — they are how a model
names the slice it wants next — but the values are present only as a mean and a
standard deviation of their lengths. That is the whole trick: `Peek` returns
aggregates over a bounded walk, so its size is set by `TopN` and not by the
store. Measured, the peek of the 21-node fixture serializes to 392 characters and
the peek of a store roughly 25× larger to 402.

## A whole decomposition

```objectscript
Set llm = ##class(RLM.LLM.Null).%New(script)      // scripted, deterministic
Set eng = ##class(RLM.Engine).%New(src, llm, ##class(RLM.Budget).%New(32),
                                   ##class(RLM.Policy.Greedy).%New())
Set report = eng.Run("what is in this global", .traceId)
```

```text
Question
--------
what is in this global

Store
-----
^||RLMTest
  nodes: 21
  depth reached: 3
  immediate children: 5
  busiest children: 2019-11-04 (8), 7 (3), 42 (3), 2020-03-11 (3), a,b (3)
  node kind: 43% data, 57% pointer
  value length: mean 5, sd 2.45
  subscript types: 2 numeric, 3 string, 0 list

Slices examined
---------------
- 7 [... nodes: 3 ...] mostly pointer nodes, one value per leaf
- 42 [... nodes: 3 ...] mostly pointer nodes, one value per leaf
- 2019-11-04 [... nodes: 8; immediate children: 3;
   busiest children: BOS-GEN (3), NYC-MEM (2), x)y (2);
   node kind: 63% data, 38% pointer ...] mostly pointer nodes, one value per leaf
- 2020-03-11 [... nodes: 3 ...] mostly pointer nodes, one value per leaf
- a,b [... nodes: 3 ...] mostly pointer nodes, one value per leaf

Answer
------
mostly pointer nodes, one value per leaf

Limits of this analysis
-----------------------
- Spent 6/32 model calls and 5 peeks.
```

Six calls: one per child of the root, plus the synthesis. The root is not
sub-called, because its statistics are already under "Store". `Policy.Greedy`
picked the split from `SplitMetric` — 0.93 at the root here — and spent no call
doing it. The children's node counts sum to the parent's exactly, which is the
arithmetic the suite checks.

## The trace

```text
1 decision   d=0
2 subcall    d=1  s1:37
3 subcall    d=1  s1:3432
4 subcall    d=1  s1:323031392D31312D3034
5 subcall    d=1  s1:323032302D30332D3131
6 subcall    d=1  s1:612C62
7 synthesis  d=0
```

The slice keys are hex, two digits per UTF-8 byte, so `2019-11-04` is
`323031392D31312D3034`. Subscripts carry commas, quotes and close-parens —
`a,b`, `q"z` and `x)y` are all in the fixture on purpose — and any of them
written into a path would collide with the path grammar. Hex has no delimiters to
collide with, and `Decode` refuses an odd-length or non-hex token rather than
guessing, so a fabricated slice key is rejected before it reaches indirection.

## The caps, and why they are disclosed

```objectscript
Set src.VisitCap = 5
Write src.Peek("").capped        // 1
Write src.Peek("").n             // 5
```

`VisitCap` defaults to 50,000 and `DepthCap` to 8. A walk that hit either sets
`capped`, `Describe` says so, and `RLM.Engine` puts it in "Limits of this
analysis" — a count that is a floor read as a total corrupts every claim built on
it, so it never travels without the flag. A cap set exactly at the store's size
is not a truncation and is not flagged.

## Running the tests

```bash
printf 'do $system.OBJ.LoadDir("/home/irisowner/dev/src","ck",,1)
set ^UnitTestRoot="/home/irisowner/dev/src/UnitTest"
do ##class(%UnitTest.Manager).RunTest("RLM","/noload/nodelete/norecursive")
halt
' | docker exec -i rlm-iris iris session IRIS -U USER
```

The `"ck"` qualifier is mandatory. Without it the classes import without
compiling, `%UnitTest` runs the previously compiled versions, and the run still
prints "All PASSED".

Six classes cover this feature: `SourceGlobalAllow` (the allowlist),
`SourceGlobal` (the walk and the hex round trip), `SourceGlobalCaps` (cap
honesty), `SourceGlobalMetric` (the split metric), `SourceGlobalShape` (type mix,
value-length moments, peek size independence) and `EndToEndGlobal` (the whole
decomposition, portability, and read-only).
