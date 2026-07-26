# Quickstart: `rlm-aihub`

Every figure below was printed by the code. Nothing here is estimated.

## What you need

An IRIS with `%AI.*`. Verified on `irishealth-community:2026.3.0AI.126.0` (Build
126U). `rlm-core` needs none of it and runs on 2026.1 community.

## Install

```objectscript
zpm "install rlm-core"
zpm "install rlm-aihub"
```

`rlm-aihub` declares `rlm-core` as a dependency and adds one resource,
`RLMAIHub.PKG`. On an IRIS without `%AI.*`, install only `rlm-core`.

## Run a decomposition through the instance's configured provider

```objectscript
Set store  = ##class(RLM.Source.Table).%New("Sample.Person", .sc)
Set llm    = ##class(RLMAIHub.Provider).%New("openai", "gpt-4o-mini")
If 'llm.Ready(.reason) { Write "not ready: ", reason, ! Quit }

Set engine = ##class(RLM.Engine).%New(store, llm,
    ##class(RLM.Budget).%New(24), ##class(RLM.Policy.Greedy).%New())
Set engine.MaxDepth = 2
Write engine.Run("how does this population divide?")
```

No URL, no bearer token, no SSL configuration. That is the whole point of the
module: `%New()` takes a provider name and a model, and the credential stays
where the instance administrator put it.

`Ready()` is a separate call because construction proves nothing.
`%AI.Provider.Create("openai", {"api_key": "sk-not-a-real-key"})` returns a
provider object and lists seven capabilities — measured on Build 126U — so a
caller that read construction as readiness would find out one exhausted budget
later.

## Optional: the instance's policies

```objectscript
Set llm.AuthPolicy  = ##class(%AI.Policy.ConsoleAuth).%New()
Set llm.AuditPolicy = ##class(%AI.Policy.ConsoleAudit).%New()
```

Both are optional and neither changes the result when absent. Authorization is
consulted before the round-trip, so a refused completion never reaches the
provider — on a metered provider that is the difference the seam exists to make.
The audit record carries the shape of the call (provider, model, token counts,
duration, status) and neither the prompt nor the completion text: the prompt
holds slice statistics about a store the caller may not be permitted to export.

An audit sink that throws is swallowed. Logging is not part of the completion,
and a misconfigured sink must not fail every call in the run.

## Give it a model that is not there

```objectscript
Set llm = ##class(RLMAIHub.Provider).%New("nosuchprovider", "nosuchmodel")
Set out = llm.Complete("instructions", "prompt", .sc)
Write $System.Status.GetErrorText(sc), !
```

`Complete` never throws. `%AI.*` signals failure by throwing and `RLM.LLM`'s
contract is `""` plus a status, so every call is wrapped: a provider outage
costs a run one slot rather than the whole report. A run whose second call fails
still produces a report, and the slice it could not analyse says so — "the
sub-call for 'x' failed; that slice is described by its statistics only".

## Test it

```bash
docker exec -i rlm-iris-ai iris session IRIS -U USER <<'EOF'
do $system.OBJ.LoadDir("/home/irisowner/dev/src","ck",,1)
set ^UnitTestRoot="/home/irisowner/dev/src/UnitTest"
do ##class(%UnitTest.Manager).RunTest("RLMAIHub","/noload/nodelete/norecursive")
halt
EOF
```

Measured on 2026-07-26:

| Suite      | `rlm-iris` (2026.1, no `%AI.*`) | `rlm-iris-ai` (2026.3.0AI Build 126U) |
| ---------- | ------------------------------- | ------------------------------------- |
| `RLM`      | 306 passed / 0 failed           | 306 passed / 0 failed                 |
| `RLMAIHub` | n/a — class skipped at compile  | 35 passed / 0 failed                  |

The `RLMAIHub` 35 break down as `Provider` 14, `Policies` 9, `EndToEndAIHub` 7,
`Manifests` 5.

Every one of them runs with no provider configured, no key, and nothing to
reach. `UnitTest.RLMAIHub.StubProvider` extends `%AI.Provider` and overrides
`ChatComplete`, whose body is a `$ZF(-6)` callout, so the override replaces the
callout entirely.

One `src/` tree serves both containers. `$System.OBJ.LoadDir(..., "ck", , 1)`
skips a class whose superclass is missing and continues, so on base IRIS it
prints

```text
ERROR #5373: Class '%AI.Policy.Audit', used by 'RLMAIHub.Provider:property:AuditPolicy', does not exist
Skipping class RLMAIHub.Provider
```

and the other 306 tests compile and run green.

## The two assertions the milestone is actually about

`UnitTest.RLMAIHub.EndToEndAIHub` runs the same fixture twice with the same
scripted replies, once through `RLM.LLM.Null` and once through
`RLMAIHub.Provider`, and asserts:

- the two documents are byte-identical
- the two call counts are exactly equal

The first is the strong form of portability. If the two providers differed at
all — an extra message, a reordered prompt, a retry, a tool loop — the documents
would diverge, and every scorecard comparison between an AI Hub arm and a REST
arm would be measuring the provider rather than the model.

The second is why this is built on `%AI.Provider.ChatComplete` and not
`%AI.Agent.Chat`. `%AI.Agent` runs a tool loop with `MaxIterations` defaulting
to 10. The engine charges one slot per decision; a provider that spent ten would
make the budget line in every report fiction, and a trajectory that depends on
tool results rather than only on the frozen store is not replayable.

## Known limit

Truncation is a proxy. `%AI.LLM.Response` carries `Content`, `ToolCalls` and
`Usage` and no finish reason — `FromJSON` reads exactly those three keys — so a
completion is treated as cut off when its reported `completion_tokens` reaches
the requested `MaxTokens`. That over-refuses: an answer that legally ends on the
limit is rejected. It is the correct direction of error, because a false refusal
is disclosed in the report and costs one slot while a false acceptance puts half
a sentence into a report as a finding. A finish reason on `%AI.LLM.Response`
would let the check be deleted.
