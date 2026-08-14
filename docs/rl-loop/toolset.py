"""The decomposition tools, served to the agent over MCP.

Every tool is a thin call into IRIS. Nothing here holds the store, and nothing
here holds a slice of it -- the whole point is that the data never leaves the
database, so what crosses this boundary is aggregate statistics, a capped sample
of records, and slice *names*.

Note what the model is allowed to say. `split` takes a dimension name that
`legal_moves` handed it. `read` takes a slice path in the same grammar. There is
no free-text predicate anywhere, which is what makes the arm-scoring in
taskset.py possible: every decision has a finite, enumerable set of alternatives
that IRIS can price after the fact.

Written against the verifiers v1 API. Illustrative; not yet run.
"""

import os

import httpx
import verifiers.v1 as vf

IRIS = os.environ.get("RLM_IRIS_URL", "http://localhost:52773/rlm")


class DecomposeToolsetConfig(vf.ToolsetConfig):
    max_records: int = 20
    """Cap on records a single `read` may return. The context bound: what the
    model accumulates is slices inspected times this, never the store size."""


class DecomposeToolset(vf.Toolset[DecomposeToolsetConfig]):
    """One instance per rollout. Holds the run id, not the data."""

    async def setup(self) -> None:
        self._client = httpx.AsyncClient(base_url=IRIS, timeout=120)
        self._run_id: str | None = None

    async def teardown(self) -> None:
        await self._client.aclose()

    async def _post(self, path: str, **body) -> dict:
        r = await self._client.post(path, json=body)
        r.raise_for_status()
        return r.json()

    @vf.tool
    async def open_store(self, source: str, scope: str = "") -> str:
        """Start a decomposition run over a store.

        Args:
            source: class name of the store, from the task prompt.
            scope: optional slice to confine the run to, as dim:token/dim:token.

        Returns a description of the whole store in aggregate: row or node count,
        and whatever statistics that kind of store reports.
        """
        out = await self._post("/run", source=source, scope=scope)
        self._run_id = out["runId"]
        # The taskset's rewards need this to find the run in ^RLM.Trace.
        self.trace.state["rlm_run_id"] = out["runId"]
        return out["describe"]

    @vf.tool
    async def legal_moves(self, slice: str = "") -> str:
        """The dimensions this slice may be split on, and the children of each.

        Args:
            slice: the slice to ask about, empty for the whole store.

        This is the complete set of legal moves. A dimension not listed here
        cannot be reached, and `split` will refuse it.
        """
        out = await self._post("/moves", runId=self._run_id, slice=slice)
        return out["menu"]

    @vf.tool
    async def split(self, slice: str, dimension: str) -> str:
        """Divide a slice on one dimension and report each child's statistics.

        Args:
            slice: the slice to divide, empty for the whole store.
            dimension: a dimension name from `legal_moves`.

        The children come from the store's own enumeration, so every slice name
        you get back resolves. Counts that stopped at a cap say so, and a capped
        count is a floor rather than a total.
        """
        out = await self._post(
            "/split", runId=self._run_id, slice=slice, dimension=dimension
        )
        return out["children"]

    @vf.tool
    async def read(self, slice: str) -> str:
        """Read the actual records of a slice, once it is small enough.

        Args:
            slice: the slice to read.

        Refuses a slice larger than the record cap, or one whose count came back
        capped -- a floor of five may be five million. When it refuses you get the
        statistics instead, and should split further.
        """
        out = await self._post(
            "/read",
            runId=self._run_id,
            slice=slice,
            limit=self.config.max_records,
        )
        return out["view"]

    @vf.tool
    async def note(self, slice: str, finding: str) -> str:
        """Record a finding against a slice.

        Args:
            slice: the slice the finding is about.
            finding: what the statistics or records show.

        Notes persist in IRIS keyed by slice, so they survive the context being
        compacted, and the scorer can check each claim against the slice it came
        from.
        """
        await self._post("/note", runId=self._run_id, slice=slice, finding=finding)
        return "recorded"

    @vf.tool
    async def answer(self, text: str) -> str:
        """Give the final answer and close the run.

        Args:
            text: the answer, citing the slices that support it.
        """
        await self._post("/answer", runId=self._run_id, answer=text)
        return "run closed"


__all__ = ["DecomposeToolset"]
