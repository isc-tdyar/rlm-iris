# The whole loop: IRIS decomposition as an RL environment

What training a recursive decomposition policy actually looks like, end to end,
with the Prime Intellect stack doing the training and IRIS doing the reward.

Written against `verifiers` v0.3.0 (v1 API) and `prime-rl`. The files here are
illustrative — accurate to the v1 API as of `verifiers` @ `9ca7f5d`, not yet run.

## The flow

```
  IRIS                                   verifiers / prime-rl
  ────────────────────────────────       ──────────────────────────────
  RLM.Engine.Run(question, scope)  ◄──── rlm_iris_v1 Toolset  (MCP)
    picks a dimension                      peek / split / read / answer
    peeks each child
    reads records at the leaves
    writes ^RLM.Trace                    rlm_iris_v1 Taskset
                                           one task = one question + scope
  RLM.Eval.Scorecard.Objective(run) ────►  @vf.reward  objective
  RLM.Eval.Arms.Enumerate(run)      ────►  @vf.reward  regret
  RLM.State.Findings(run)           ────►  @vf.reward  grounded
                                                │
                                                ▼
                                         prime-rl: GRPO over the
                                         policy that picks dimensions
```

## Why this environment is unusual

Most RL environments are bottlenecked on the reward. You need a judge model, a
human label, or a hand-written verifier, and each is expensive, noisy or both.
`gsm8k_v1` — the reference verifiers environment — ships a `verify.py` that runs
`math-verify` in the rollout runtime just to grade one number.

Here the reward is a SQL query. Because the model never authors code, a peek is a
pure function of the store, so after a run finishes IRIS can compute:

- **objective** — the mean split metric of the leaf slices the run reached.
  `RLM.Eval.Scorecard.Objective(runId)`. Lower is better; this is the episode
  return.
- **regret** — for every decision, the best dimension the run *didn't* take,
  scored by actually peeking it. `RLM.Eval.Arms.Enumerate(runId)`. This is a
  per-decision reward over the whole action set, not just the arm taken, and it
  costs zero model calls.
- **grounded** — did the answer cite slices that exist and figures that appear in
  the peeks it was shown. `RLM.State.Findings(runId)`.

No judge model. No human label. No LLM in the reward path at all.

`Eval.Arms` in particular is unusual enough to spell out: it gives dense
supervision on a discrete action set. At each decision the run chose one of *n*
dimensions, and we can price all *n* after the fact. That is much closer to a
contextual bandit with full feedback than to the sparse terminal reward most
agent RL runs on.

## The honest limitation

**verifiers has no offline training path.** Rollouts are live: prime-rl's GRPO
needs the live policy's own sampling logprobs, and the config validator rejects
frozen-model sampling for anything but the `ce` loss component. So this loop still
runs the agent against a real IRIS instance for every rollout — the reward is
free, the rollout is not.

What the determinism buys instead is everything *around* training: replaying a
recorded run with no model calls, comparing two policies on the same store
offline, and re-scoring old traces after changing the objective. For actual
gradient steps, plan on a live instance.

If offline is what you want, the traces are already a supervised dataset —
`(state, chosen action, per-action reward)` at every decision — and TRL's DPO or
plain SFT will consume that without verifiers in the picture.

## Files

| File | What it is |
|---|---|
| `iris_rest.cls` | The IRIS side. A REST surface over `RLM.Engine` and the eval classes. |
| `toolset.py` | `vf.Toolset` exposing decomposition as MCP tools the agent calls. |
| `taskset.py` | `vf.Taskset` — one task per question, with the three rewards above. |
| `rl.toml` | prime-rl config. `uv run rl @ rl.toml`. |

## Running it

```bash
# 1. IRIS, with the REST surface exposed
docker compose up -d

# 2. Evaluate a model with no training at all — this alone answers
#    "which model decomposes best?", which we currently cannot ask
uv run eval rlm-iris-v1 -n 20 --num-rollouts 4 --model openai/gpt-5-mini

# 3. Train
uv run rl @ rl.toml
```

Step 2 is worth doing on its own. It needs no GPU and no training loop, and it
turns `RLM.Eval.Scorecard` from a thing that compares two of our policies into a
thing that compares any model on any store.

## What has to be true first

The agent side of this needs bounded recursion and a depth-tagged trace, which is
what [the AI Hub request](../ER-AIHUB-RECURSIVE-SUBAGENTS.md) asks for. Until then
the decomposition runs in `RLM.Engine` — our own traversal, outside `%AI.*` — and
the loop above works, but the sub-agents are ours rather than the platform's.
