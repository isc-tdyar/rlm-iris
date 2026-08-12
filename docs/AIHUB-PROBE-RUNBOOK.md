# Runbook: re-checking the AI Hub agent surface

Everything `docs/ER-AIHUB-RECURSIVE-SUBAGENTS.md` claims about `%AI.Agent` was
measured on **2026.3.0AI Build 126U** during M5. Two of those claims have a shelf
life: the signatures may have changed, and `ai-hub-eap#26` may have been fixed.
This is how to re-check both, and what to send back.

## Why this is a runbook and not a CI job

AI Hub builds are WRC-gated. They are not on Docker Hub — `intersystems/iris-community`
publishes `2025.1` … `2026.2` plus `latest-em`/`latest-cd`, and **no AI-suffixed
tags at all**. So the check runs wherever the image was downloaded to, on a machine
with WRC access, and cannot be automated from a sandbox that has neither.

Target platform is ordinary `linux/amd64`; nothing here is architecture-specific.

## 1. Get the image onto the host

Either route works — the rest of the runbook only needs a local image tag.

```bash
# Registry, if the host can reach it
docker login containers.intersystems.com
docker pull containers.intersystems.com/intersystems/iris:<AI-build-tag>

# Or a manual download from WRC
docker load -i /path/to/iris-<AI-build>-docker.tar.gz
docker image ls | grep -i iris        # note the tag
```

**A licensed AI Hub build needs a key.** Unlike the community image, it will not
start without one. Put `iris.key` where the image expects it (commonly
`/usr/irissys/mgr/iris.key`) — mount it rather than baking it into a layer:

```yaml
volumes:
  - ./iris.key:/usr/irissys/mgr/iris.key:ro
```

## 2. Build and start

`Dockerfile` takes an `IMAGE` build arg and `docker-compose.yml` now forwards
`IRIS_IMAGE` into it, so nothing needs editing:

```bash
export IRIS_IMAGE=containers.intersystems.com/intersystems/iris:<AI-build-tag>
docker compose build
docker compose up -d
```

The build compiles `src/` with `$System.OBJ.LoadDir(..., "ck", , 1)`, which skips a
class whose superclass is missing and continues. On an AI Hub image `RLMAIHub.*`
compiles; on a community image it is skipped and the other classes still build. A
failed compile fails the build rather than the first run.

## 3. Run the probe

```bash
docker compose exec iris iris session IRIS -U USER \
  '##class(UnitTest.RLMAIHub.AgentProbe).Report()'
```

It reads `%Dictionary.CompiledClass`, `CompiledMethod`, `CompiledProperty` and
`CompiledParameter` — it calls nothing, spends no license slot, needs no provider
configured, and cannot hang. That last property is deliberate: the defect it exists
to help re-check *is* a hang, so the probe must not be able to reproduce it.

Output is `$ZVersion`, every `%AI.*` class on the instance, and for the seven
classes the enhancement request depends on, their parameters, properties and full
method signatures.

## 4. Run the suites

```bash
# rlm-core: LLM-free, no key, no network
docker compose exec iris iris session IRIS -U USER \
  '##class(%UnitTest.Manager).RunTest("RLM",,)'

# rlm-aihub: AI Hub only
docker compose exec iris iris session IRIS -U USER \
  '##class(%UnitTest.Manager).RunTest("RLMAIHub",,)'
```

## 5. Re-check ai-hub-eap#26

The probe reports the surface; it does not reproduce the defect. Reproducing it
means dispatching a child agent **with tools attached** from inside a parent's own
tool loop, which is the exact condition recorded in SPEC §6:

> A `%AI.Tool` that spawns a child agent never returns when the parent's own loop
> dispatches it — and only when the child has tools attached. It also leaks license
> slots.

Write that against whatever `Detail("%AI.Agent")` and `Detail("%AI.Tool")` actually
print, rather than against the signatures assumed here — that is the reason step 3
comes first. Two precautions, both learned from the original occurrence:

- **Run it with a wall-clock timeout you control.** The failure mode is a hang, so a
  test without an external bound does not fail, it stops.
- **Record the instance's license-slot count before and after.** The leak is the
  half of the defect that outlives the run, and it is invisible from the test's own
  result.

If the child returns, work down AC-1 through AC-8 in the enhancement request. AC-3
(slot count returns to its pre-run value over 100 iterations) is the one most worth
running even if everything else passes.

## 6. What to send back

Enough to change the document rather than just reassure someone:

1. `$ZVersion` — the exact build.
2. The full `Report()` output.
3. Whether a child agent with tools returns, and how long the parent waited.
4. License-slot count before and after.
5. Both suites' pass/fail counts.

With 1–3, ER §4 either collapses to "fixed in Build N" or gets upgraded from
"measured on 126U" to "still present on N". Either is worth more to the AI Hub team
than the current wording, which is honest but eight months stale.
