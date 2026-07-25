# Data model: Port the gaia-iml prototype onto rlm-iris

Nothing here is a new table. The store is `SQLUser.GaiaQualityScored` exactly as
`^RunScript` writes it, and this feature only reads it. What follows is the
declared shape of the six dimensions, the peek object they are summarized into,
and the two places where the prototype's shape and the library's do not line up.

## The store

`SQLUser.GaiaQualityScored`, 74,998 rows, 15 columns. Written by `^RunScript` with
both NGBoost predictions materialized as stored columns.

| Column            | Meaning                                      | Used as                    |
| ----------------- | -------------------------------------------- | -------------------------- |
| `source_id`       | Gaia DR3 source identifier                   | never read by this feature |
| `n_bp` / `n_rp`   | usable epochs per band                       | `epoch_count` dimension    |
| `bp_snr`/`rp_snr` | mean flux ÷ mean flux error                  | `signal_quality` dimension |
| `bp_cv`/`rp_cv`   | flux scatter ratio                           | `Describe` line 8          |
| `bp_min`/`bp_max` | flux extremes                                | `n_nearzero` aggregate     |
| `rp_min`/`rp_max` | flux extremes                                | `n_nearzero` aggregate     |
| `pct_change`      | relative flux swing, percent                 | `variability`, `detection` |
| `reject_fraction` | ESA's own epoch reject fraction — the target | `reject_level`, the metric |
| `pred_reject`     | NGBoost mean head's prediction               | `Ready()`, `Describe`      |
| `pred_sigma`      | NGBoost sigma head's prediction              | `model_confidence`         |

Measured 2026-07-25: `reject_fraction` has 0 nulls, and `pred_reject` is populated
for all 74,998 rows, so `Ready()` passes today and `NullCount()` returns 0 for
every dimension. Both are still wired, because the interesting case is the day
that changes.

## The six dimensions

Each is `AddBucketedDimension(name, property, breakpoints, labels)`. The labels
are the prototype's prose verbatim; the tokens are the library's ordinals.

### `reject_level` — `reject_fraction`, edges 0.05 / 0.20 / 0.50

| Token | Label                                     |
| ----- | ----------------------------------------- |
| `b0`  | clean (ESA rejected under 5% of epochs)   |
| `b1`  | moderate (5-20% rejected)                 |
| `b2`  | heavy (20-50% rejected)                   |
| `b3`  | severe (over half of all epochs rejected) |

### `epoch_count` — `n_bp`, edges 5 / 20 / 60

| Token | Label                           |
| ----- | ------------------------------- |
| `b0`  | very few epochs (under 5 in BP) |
| `b1`  | few epochs (5-19 in BP)         |
| `b2`  | well sampled (20-59 in BP)      |
| `b3`  | densely sampled (60+ in BP)     |

### `signal_quality` — `bp_snr`, edges 50 / 200 / 1000

| Token | Label                   |
| ----- | ----------------------- |
| `b0`  | very low SNR (under 50) |
| `b1`  | low SNR (50-199)        |
| `b2`  | good SNR (200-999)      |
| `b3`  | high SNR (1000+)        |

### `model_confidence` — `pred_sigma`, edges 0.04 / 0.08 / 0.15

| Token | Label                                        |
| ----- | -------------------------------------------- |
| `b0`  | model confident (sigma under 0.04)           |
| `b1`  | model moderately confident (sigma 0.04-0.08) |
| `b2`  | model unsure (sigma 0.08-0.15)               |
| `b3`  | model very unsure (sigma 0.15+)              |

### `variability` — `pct_change`, edges 100 / 1000 / 100000

| Token | Label                                                       | Rows   |
| ----- | ----------------------------------------------------------- | ------ |
| `b0`  | not variable (swing under 100%)                             | 17,899 |
| `b1`  | variable, modest swing (100-1000%)                          | 17,204 |
| `b2`  | variable, large swing (1000-100000%)                        | 31,224 |
| `b3`  | extreme swing (over 100000%, almost certainly instrumental) | 8,671  |

Populations measured; they sum to 74,998 with no nulls.

The prototype's boundaries are `>` and the library's buckets are `>=`, which is
a different partition in general. Here it is the same one: no row holds
`pct_change` exactly equal to 100, 1,000 or 100,000, so both encodings select the
same rows. Verified, not assumed — `pct_change > 100` and `pct_change >= 100`
both return 57,099.

### `detection` — `pct_change`, one edge at 100

| Token | Label                                          | Rows   |
| ----- | ---------------------------------------------- | ------ |
| `b0`  | not a detection (flux swing under 100%)        | 17,899 |
| `b1`  | variable-star detection (flux swing over 100%) | 57,099 |

New. Research decision 3 has the argument: `Triage` describes the union of
`variability`'s upper three buckets, the slice grammar names one child per
dimension by design, and a union of siblings must not become nameable. `detection`
gives that population its own name — the binary question the challenge actually
asks — and `variability` stays available to subdivide it by swing size.

`detection` and `variability` are not independent. Inside `detection:b1`,
`variability:b0` is empty by construction, and inside `detection:b0` the other
three are. The engine must describe such a slice as empty and must not spend a
model call on it.

## Dimension-level prose has no slot in the library's spec

`RLM.Source.Table.Dimensions()` emits `{"label": <property>, "children": [...]}`.
The prototype's dimensions each carry a sentence of prose as well — "how heavily
ESA's pipeline rejected the source's epochs (the target being modelled)" — and
`RLM.Slice.Menu()` renders `spec.label` where that sentence belongs.

`Gaia.Source` overrides `Dimensions()`, calls `##super()`, and replaces each
dimension's `label` with the prototype's sentence. No library change: `label` is
already free text and `Menu()` already prefers it over the bare dimension name.
Recorded because it is the one piece of the prototype's `Dimensions()` that the
library does not have a declared place for, and a reader looking for it in
`AddBucketedDimension`'s arguments will not find it.

## The peek object

`Gaia.Source.Peek(predicate)` returns the prototype's sixteen aggregates, plus the
two keys the library's own rules read:

| Key                     | Aggregate                                                  |
| ----------------------- | ---------------------------------------------------------- |
| `n`                     | `COUNT(*)` — read by the engine and by `ShouldSplit`       |
| `capped`                | always 0; the query is a full aggregate, never TOP-limited |
| `n_pred`                | `COUNT(pred_reject)` — what `Ready()` reconciles against   |
| `avg_rej` `sd_rej`      | `AVG`/`STDDEV(reject_fraction)` — `sd_rej` is the metric   |
| `min_rej` `max_rej`     | `MIN`/`MAX(reject_fraction)`                               |
| `avg_pred`              | `AVG(pred_reject)`                                         |
| `avg_sigma` `max_sigma` | `AVG`/`MAX(pred_sigma)`                                    |
| `avg_n_bp` `min_n_bp`   | `AVG`/`MIN(n_bp)`                                          |
| `avg_snr` `avg_cv`      | `AVG(bp_snr)`, `AVG(bp_cv)`                                |
| `max_pct`               | `MAX(pct_change)`                                          |
| `n_variable`            | `SUM(CASE WHEN pct_change > 100 …)`                        |
| `n_nearzero`            | `SUM(CASE WHEN bp_min < 1 OR rp_min < 1 …)`                |

`capped` is 0 rather than absent because principle III's disclosure reads it and
an absent key would read as an unanswered question rather than a "no".

An empty slice returns `n = 0` and nothing else; `Describe` says so rather than
rendering zeros as measurements. A failed query returns `{"error": …}` rather than
throwing, matching what the library's own `Table.Peek` does.

## The split metric and the recursion rule

Two different questions, kept separate:

- `SplitMetric(peek)` = `min(1, peek.sd_rej / baseline)`, where `baseline` is the
  survey-wide `STDDEV(reject_fraction)`, computed once per source instance. This
  is what a policy compares candidates on.
- `ShouldSplit(peek)` = `SplitMetric(peek) >= 1` **and** `peek.n >= 400`. This is
  whether subdividing is worth a model call, and it carries the prototype's
  400-row floor.

The clamp is required — the library documents the metric as 0–1 and `Greedy`
size-weights it — and it costs something: two slices both more spread than the
survey clamp to the same 1 and cannot be ranked against each other. The port runs
`RLM.Policy.LLM`, as the prototype did, so nothing regresses. Decision 7 of
research.md carries the full argument.

The baseline lives in an instance property, not a class variable. The engine
holds one source for the life of a run, so instance scope is run scope; the
prototype's class variable leaked across runs and went stale after an ingest.

## Readiness

`Ready(Output reason)` returns 0 in two distinguishable cases:

| Condition    | Reason                                                                                        |
| ------------ | --------------------------------------------------------------------------------------------- |
| `n = 0`      | the table is empty — the ingest has not run; run `do ^RunScript`                              |
| `n_pred < n` | only `n_pred` of `n` rows are scored — the PREDICT step ran partially; re-run `do ^RunScript` |

Two cases rather than one because the remedies differ and a single message would
mislead in whichever case it did not describe. The prototype conflated them into
a single `n_pred < n` throw from `Report()`, which never fired on an empty table.

The check runs before the root peek, which is why it uses its own small query
rather than reading a peek: on a store mid-load the root peek is the expensive
call and the one most likely to fail.
