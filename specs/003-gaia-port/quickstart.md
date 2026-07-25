# Quickstart: the ported Gaia analysis

Everything here is verified against the port before this document is marked done.
Figures are measured.

## Running it

Unchanged from before the port — that is the point:

```bash
docker exec gaia-iml-iris bash -c 'printf "do ^RLMAudit\nhalt\n" | iris session IRIS'
```

`^RunScript` is untouched. The analysis is a separate entry point because LLM
latency is not ours to control and `^RunScript` is the benchmarked path.

## What `Audit()` is, after the port

The whole method:

```objectscript
ClassMethod Audit(outPath As %String = "") As %Status
{
    Set engine = ##class(RLM.Engine).%New(##class(Gaia.Source).%New(),
        ##class(Gaia.LLM.AIHub).%New(), ##class(RLM.Budget).%New(18))
    Set engine.MaxDepth = 3
    Set engine.ReportStyle = "markdown"
    Set text = engine.Run("Where is this survey's data quality worst, and where "
        _"does the model's own prediction disagree with ESA's?", .traceId)
    Quit ##class(RLM.Report).WriteTextToFile(text, outPath)
}
```

That replaces 513 lines. The recursion, the budget arithmetic, the trace, the
report assembly and the file write are all the library's now.

## Cloning it

The library arrives as a submodule, so a plain `git clone` gets an empty
`lib/rlm-core` and nothing compiles:

```bash
git clone --recursive https://github.com/isc-tdyar/gaia-iml.git
# already cloned without it:
git submodule update --init
```

`iris.script` loads the submodule before `src/`, because the prototype's classes
extend the library's:

```objectscript
do $System.OBJ.LoadDir("/home/irisowner/dev/lib/rlm-core/src","ck",,1)
do $System.OBJ.LoadDir("/home/irisowner/dev/src","ck",,1)
```

IPM is not the route: `%ZPM.PackageManager` does not exist in the 2026.3 AI
preview image the prototype builds on. `module.xml` still declares the dependency
for anyone installing on an image that has it.

## Asking about the detections only

```objectscript
do ^RLMTriage
```

Which is now:

```objectscript
Set text = engine.Run("Which variable-star detections are least trustworthy?",
    .traceId, "detection:b1")
```

`detection:b1` is 57,099 sources — the same population the prototype selected with
`pct_change > 100`. It is a slice name resolved through the whitelist, not a SQL
string, so the engine's own confinement applies: every peek in the run carries the
scope, `detection` is not offered as a way to split, and every heading naming the
store names the subset instead.

The prototype could not do this. Its `Triage` handed a raw predicate to its
recursion, because the population it wanted is the union of three `variability`
buckets and the slice grammar names one child per dimension by design. Declaring
`detection` — one breakpoint at 100, over the same column — gives that population
its own name. `variability` is still there to subdivide the detections by swing
size.

## The six dimensions

```objectscript
Set src = ##class(Gaia.Source).%New()
Write ##class(RLM.Slice).Menu(src)
```

```text
reject_level (how heavily ESA's pipeline rejected the source's epochs (the target
being modelled)):
  - reject_level:b0 - clean (ESA rejected under 5% of epochs)
  - reject_level:b1 - moderate (5-20% rejected)
  - reject_level:b2 - heavy (20-50% rejected)
  - reject_level:b3 - severe (over half of all epochs rejected)
...
detection (whether the source is a variable-star detection at all - the question
the challenge asks):
  - detection:b0 - not a detection (flux swing under 100%)
  - detection:b1 - variable-star detection (flux swing over 100%)
```

Tokens are ordinals, not the prototype's `severe` / `clean`. Rewording a label
cannot invalidate a trace that named the child, which is what the ordinals are
for. Reports quote labels, so their prose is unchanged; trace rows read
`reject_level:b3` where they used to read `reject_level:severe`.

## Two dimensions over one column

`variability` and `detection` both divide `pct_change`. That is legal and useful,
and it has one consequence worth knowing:

```objectscript
Set sc = ##class(RLM.Slice).Resolve(src, "detection:b1/variability:b0", .p, .l)
Write src.Peek(p).n    // 0
```

Empty by construction. `Describe` says "This slice contains no sources." and
`ShouldSplit` declines it, so it costs no model call. A slice described from zeros
as though they were measurements is the failure this avoids.

## Refusing an unfit table

```objectscript
Set ok = src.Ready(.reason)
```

Two cases, because the remedies differ:

```text
the table is empty - the ingest has not run; run 'do ^RunScript'
only 74998 of 74998 rows are scored - the PREDICT step ran partially;
  re-run 'do ^RunScript'
```

The engine checks this before any model call **and before the root peek**, and
returns the reason as the report. Averaging over whichever rows happen to be
scored produces a document that is confident and wrong, and a reader cannot tell
it from a correct one.

## Running the tests

```bash
printf 'do $system.OBJ.LoadDir("/home/irisowner/dev/lib/rlm-core/src","ck",,1)
do $system.OBJ.LoadDir("/home/irisowner/dev/src","ck",,1)
set ^UnitTestRoot="/home/irisowner/dev/src/UnitTest"
do ##class(%UnitTest.Manager).RunTest("Gaia","/noload/nodelete/norecursive")
halt
' | docker exec -i gaia-iml-iris iris session IRIS -U USER
```

The `"ck"` qualifier is mandatory, for the same reason it is in `rlm-iris`:
without it the classes import without compiling and `%UnitTest` skips them while
still printing "All PASSED".

The library's own 136 tests run separately, in `rlm-iris`, and must stay green —
a phase that breaks them found a library defect, and FR-014 says the fix goes
there rather than into `Gaia.Source`.

## What the reports will not do

Reproduce the prototype's text byte for byte. They are model-written; the
prototype set no temperature and this path sets none either, since `%AI.Agent.Chat`
exposes none. Determinism is asserted against `RLM.LLM.Null` instead, which the
prototype could not do at all.

The pre-port reports are kept at `data/out-baseline/` for comparison.
