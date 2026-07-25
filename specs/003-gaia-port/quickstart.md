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

`Audit()` is one line, because both entry points share one:

```objectscript
ClassMethod Analyze(question, rootPath = "", outPath = "", llm = "",
    maxCalls = {..#MAXCALLS}) As %String
{
    If '$IsObject(llm) { Set llm = ##class(Gaia.LLM.AIHub).%New() }
    Set engine = ##class(RLM.Engine).%New(##class(Gaia.Source).%New(), llm,
        ##class(RLM.Budget).%New(maxCalls))
    Set engine.MaxDepth = ..#MAXDEPTH
    Set engine.ReportStyle = "markdown"
    Set text = engine.Run(question, .traceId, rootPath)
    If outPath '= "" { Do ##class(RLM.Report).WriteTextToFile(text, outPath) }
    Quit text
}

ClassMethod Audit(outPath As %String = "") As %String
{
    Quit ..Analyze(..#AUDITQUESTION, "", outPath)
}
```

The question is a parameter rather than a literal so a test can assert that the
audit and the triage ask different things without restating the prose, and `llm`
is injectable because a run driven by `RLM.LLM.Null` is the only kind that can be
compared byte for byte.

That replaces 513 lines with 129. The recursion, the budget arithmetic, the trace,
the report assembly and the file write are all the library's now, and `Gaia.RLM`
no longer extends `%AI.Agent` — an entry point that is its own provider cannot be
handed a different one.

### Why it returns the text and not a `%Status`

An earlier draft of this document and of `contracts/README.md` had it returning
`%Status`, which is the more usual shape and is wrong here. `^RLMAudit` does
`Set report = ##class(Gaia.RLM).Audit(...)` and then prints
`$Length(report)` — a status would print as a small integer and read as a
report of 1 character. FR-014 and T059 both say the routines are not edited, and
the routines are the published entry points, so the method keeps their contract.

`MAXDEPTH` and `MAXCALLS` stay on `Gaia.RLM` for the same reason: `^RLMAudit`
prints both before starting, so a run announces its own ceiling. They are now
engine _configuration_ — read once here and handed to `RLM.Engine.MaxDepth` and
`RLM.Budget` — rather than the recursion state the prototype checked them
against, which is the part FR-008 removes. `SPLITRATIO` and `SPLITMINROWS` do
go: nothing outside the class read them, and the rule they expressed now lives
in `Gaia.Source.ShouldSplit`.

A failed run is still not an exception. `RLM.Engine.Run` catches its own
failures and writes them into the report, so a bad run returns a document that
says what went wrong, and the routine prints its length as usual.

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
preview image the prototype builds on.

`module.xml` does not name `rlm-core` as a dependency either, which an earlier
draft of this document said it did. `rlm-core` is not published to any registry,
so an IPM install fails on `Could not find satisfactory version of rlm-core`
before compiling a line — and a `<Dependencies>` entry only helps someone who can
already resolve the name. `gaia-iml` gates instead: `Gaia.Install` runs at
activation, and where the library and AI Hub are absent it skips the analysis
layer, names what was missing, and leaves `^RunScript` installed. A consumer of
this library is not obliged to make the library installable everywhere the
consumer is.

## Asking about the detections only

```objectscript
do ^RLMTriage
```

Which is now:

```objectscript
Quit ..Analyze(..#TRIAGEQUESTION, "detection:b1", outPath)
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
Slices are named `dimension:child` and nest with `/` up to 3 levels. Each
dimension may appear at most once in a name.

reject_level (how heavily ESA's pipeline rejected the source's epochs (the target
being modelled)):
  reject_level:b0 - clean (ESA rejected under 5% of epochs)
  reject_level:b1 - moderate (5-20% rejected)
  reject_level:b2 - heavy (20-50% rejected)
  reject_level:b3 - severe (50%+ rejected -- over half of all epochs)

... epoch_count, signal_quality, model_confidence, variability ...

detection (whether the source is a variable-star detection at all: the 100%
flux-swing threshold the challenge asks about):
  detection:b0 - not a detection (flux swing under 100%)
  detection:b1 - variable-star detection (flux swing over 100%)
```

The first two lines are the grammar itself, stated by the library from the store
rather than written out anywhere in `gaia-iml`. `Gaia.Tools.Survey.ListDimensions`
returns exactly this, which is why the prototype's hand-written version of the
sentence was deleted rather than reworded.

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
SQLUser.GaiaQualityScored is empty -- the ingest has not run; run `do ^RunScript`
  first
only 31204 of 74998 rows are scored -- the PREDICT step ran partially; re-run
  `do ^RunScript`
```

On a loaded database `Ready()` returns 1 and `reason` is empty; the two strings
above are what a caller sees instead of a report when it does not.

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

76 tests, no failures. The library's own 148 run separately, in `rlm-iris`, and
must stay green —
a phase that breaks them found a library defect, and FR-014 says the fix goes
there rather than into `Gaia.Source`.

## What the reports will not do

Reproduce the prototype's text byte for byte. They are model-written; the
prototype set no temperature and this path sets none either, since `%AI.Agent.Chat`
exposes none. Determinism is asserted against `RLM.LLM.Null` instead, which the
prototype could not do at all.

The pre-port reports are kept at `data/out-baseline/` for comparison.
