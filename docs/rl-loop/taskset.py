"""rlm-iris: recursive decomposition of a live IRIS store as an RL environment.

One task is one question against one store scope. The agent decomposes the store
through the MCP tools in `toolset.py`; IRIS records the run in `^RLM.Trace` and
then scores it.

What makes this environment unusual is the reward. Because the model never
authors code, a peek is a pure function of the store, so every reward below is a
query against IRIS after the run finishes -- no judge model, no human label, no
LLM anywhere in the reward path. `regret` in particular prices *every* dimension
the run could have chosen at each decision, not just the one it took, which is
dense feedback on a discrete action set rather than a sparse terminal score.

Written against the verifiers v1 API. Illustrative; not yet run.
"""

import json
import os

import httpx
import verifiers.v1 as vf

IRIS = os.environ.get("RLM_IRIS_URL", "http://localhost:52773/rlm")

SYSTEM = (
    "You are analysing a data store too large to read. Split it into slices, "
    "inspect the statistics of each, split the ones that are still mixed, and "
    "read the records only once a slice is small enough. Answer from what the "
    "slices show. Every figure you quote must be one you were given."
)


class DecomposeData(vf.TaskData):
    """One question against one store."""

    source: str
    """Class name of the RLM.Source to decompose, e.g. 'Gaia.Source'."""

    scope: str = ""
    """Slice to confine the run to, in dim:token/dim:token form. Empty = whole store."""

    max_depth: int = 2


class DecomposeTask(vf.Task[DecomposeData]):
    async def setup(self, runtime: vf.Runtime) -> None:
        """Confirm the store is fit to report on before spending a rollout on it.

        RLM.Source.Ready() exists because a store mid-load produces figures that
        are confident and wrong. A rollout against one is worse than no rollout,
        because it trains on them.
        """
        async with httpx.AsyncClient(base_url=IRIS, timeout=30) as c:
            r = await c.get("/ready", params={"source": self.data.source})
            r.raise_for_status()
            if not r.json()["ready"]:
                raise vf.InfraError(f"store not ready: {r.json()['reason']}")

    async def _run_record(self, trace: vf.Trace) -> dict:
        """The IRIS-side record of this rollout, keyed by the run id the agent used.

        Cached on the trace so three rewards cost one round trip.
        """
        if "rlm" not in trace.state:
            run_id = trace.state.get("rlm_run_id")
            if run_id is None:
                raise vf.RolloutError("agent never opened a decomposition run")
            async with httpx.AsyncClient(base_url=IRIS, timeout=120) as c:
                r = await c.get(f"/run/{run_id}/score")
                r.raise_for_status()
                trace.state["rlm"] = r.json()
        return trace.state["rlm"]

    # ---- rewards -----------------------------------------------------------

    @vf.reward(weight=1.0)
    async def objective(self, trace: vf.Trace) -> float:
        """How cleanly the run divided the store. RLM.Eval.Scorecard.Objective().

        The mean split metric of the leaf slices reached, in 0-1, lower better --
        so it is inverted here. A run that left every leaf as mixed as the root
        scores 0; one that separated the population scores near 1.

        Returns 0 rather than raising when the run was partial: a run that lost a
        slice to an exhausted budget examined a different population than it set
        out to, and Scorecard already refuses to score those.
        """
        rec = await self._run_record(trace)
        if rec.get("partial"):
            return 0.0
        return 1.0 - float(rec["objective"])

    @vf.reward(weight=0.5)
    async def regret(self, trace: vf.Trace) -> float:
        """How much better the best unchosen dimension would have been.

        RLM.Eval.Arms.Enumerate() re-scores every candidate the run did not take,
        at every decision, by peeking it. Zero model calls -- this is only
        answerable because the model picked from an enumerated menu, so every arm
        is a name the store itself offered.

        Mean regret across decisions, inverted so 1.0 means the run picked the
        best available dimension every time.
        """
        rec = await self._run_record(trace)
        arms = rec.get("arms") or []
        if not arms:
            return 1.0
        return 1.0 - min(1.0, sum(a["regret"] for a in arms) / len(arms))

    @vf.reward(weight=0.5)
    async def grounded(self, trace: vf.Trace) -> float:
        """Fraction of the answer's figures that appear in the peeks it was shown.

        The failure mode of any decomposition is a confident synthesis over slices
        that do not support it. IRIS holds both halves -- the peeks it served and
        the findings it recorded -- so this is a string check against the trace
        rather than a judgement.
        """
        rec = await self._run_record(trace)
        cited, supported = rec["cited"], rec["supported"]
        return (supported / cited) if cited else 0.0

    # ---- metrics: recorded, not summed into the reward ----------------------

    @vf.metric
    async def slices_examined(self, trace: vf.Trace) -> float:
        return float((await self._run_record(trace))["slices"])

    @vf.metric
    async def max_depth_reached(self, trace: vf.Trace) -> float:
        return float((await self._run_record(trace))["depth"])

    @vf.metric
    async def model_calls(self, trace: vf.Trace) -> float:
        """Charged separately from peeks, because they are not interchangeable:
        a peek is one aggregate the database answers from an index."""
        return float((await self._run_record(trace))["calls"])

    async def validate(self, runtime: vf.Runtime) -> bool:
        """A task is valid if its scope resolves against the store.

        The model-free counterpart of the rewards: a scope the store does not
        offer would spend a rollout on a refusal.
        """
        async with httpx.AsyncClient(base_url=IRIS, timeout=30) as c:
            r = await c.get(
                "/resolve",
                params={"source": self.data.source, "scope": self.data.scope},
            )
            return r.status_code == 200 and r.json()["ok"]


class DecomposeConfig(vf.TasksetConfig):
    questions: str = "questions.jsonl"
    """One {source, scope, question, max_depth} per line."""


class DecomposeTaskset(vf.Taskset[DecomposeTask, DecomposeConfig]):
    def load(self) -> list[DecomposeTask]:
        rows = [
            json.loads(line)
            for line in open(self.config.questions)
            if line.strip()
        ]
        return [
            DecomposeTask(
                DecomposeData(
                    idx=i,
                    prompt=f"{SYSTEM}\n\n{row['question']}",
                    source=row["source"],
                    scope=row.get("scope", ""),
                    max_depth=row.get("max_depth", 2),
                ),
                self.config.task,
            )
            for i, row in enumerate(rows)
        ]


__all__ = ["DecomposeTaskset"]
