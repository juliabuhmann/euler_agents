You are working in /workspace, which contains the CF-MS benchmarking pipeline.

## Context

The benchmark evaluates methods that predict protein-protein interactions from
co-fractionation mass spectrometry (CF-MS) elution profiles.

**Input available to any method**: only `profiles.npz` (proteins × fractions matrix,
may contain zeros for missing/undetected values). Do not read any other files from the
dataset — in particular, never read `ground_truth.npz` in a method script.

**Forbidden**: reading `adjacency` or `complexes` from `ground_truth.npz` for anything
other than the evaluation scripts.

**Split rules** (strictly enforced):
- `train` split: fit any free parameters, thresholds, or learned weights
- `val` split: final evaluation only — never use to tune parameters
- `test` split: completely off-limits in all scripts

**Before round 1**: read `results/pearson_baseline/val.csv`, compute the baseline mean avg
(`avg = (AUROC + AUPR) / 2` averaged across all conditions), and create
`research_log/LEADERBOARD.md` with the baseline as the first row. This is your reference number.

**Target metric**: compute as follows:
1. For each `(noise_condition, difficulty)` group, average `avg` over the 5 seeds
2. Then average those group means across all `(noise_condition, difficulty)` combinations

This gives equal weight to each condition regardless of seed variance.
The goal is to improve this mean avg over the Pearson baseline. This is the single number
that defines success.

---

## Existing infrastructure

- `method_baseline.py` — Pearson baseline; follow its CLI and output format for all new methods
- `evaluate.py --predictions PRED_CSV --manifest dataset/manifest.csv --split {train|val} --output RESULTS_CSV`
- `compare_methods.py --split val` — auto-discovers all methods in `results/`, plots and prints summary
- `results/{method_name}/train.csv` and `val.csv` — where each method saves its evaluation results
- `conda run -n cfms-eval python <script>` — use this environment for all Python execution

---

## Auto-research loop — 3 rounds

Run three sequential research rounds. Each round is independent: start by reading all
previous round logs, then propose and implement something new or build on a previous
approach that showed promise.

### State tracking

Maintain a `research_log/` directory in `/workspace` with two types of files:

**`research_log/LEADERBOARD.md`** — a single file you create before round 1 and update
after every round. It is the first thing you read at the start of each round. Format:

```markdown
# Leaderboard (val split)
# Metric: mean avg = mean over conditions of [ mean over 5 seeds of (AUROC+AUPR)/2 ]

| Rank | Method | Mean AUROC | Mean AUPR | Mean avg | vs baseline | Notes |
|------|--------|------------|-----------|----------|-------------|-------|
| 1    | pearson_baseline | ... | ... | ... | — | raw Pearson r of profiles |
```

Keep it sorted by mean avg descending. Add one row per method after each round.
The Notes column should be a one-line description of what the method does differently.

**`research_log/round_N.md`** — detailed log for each round (see format below).

At the start of each round:
1. Read `research_log/LEADERBOARD.md` to see the current ranking and what has been tried
2. Read the latest `research_log/round_*.md` for context on what worked and what didn't

### What to try

You have full freedom to improve at any level of the pipeline. Examples (not exhaustive):

- **Profile preprocessing**: imputation of missing values, baseline subtraction, normalization
- **Scoring function**: Spearman, mutual information, co-apex scoring, cosine similarity
- **Gaussian fitting**: fit peaks to each profile, compare peak positions/amplitudes
- **Multi-feature methods**: combine multiple similarity measures (train a simple logistic
  regression or weighted sum on the train split)
- **Graph / transitivity**: leverage predicted cluster structure to re-score pairs

Use your own knowledge of signal processing, statistics, and CF-MS to design each approach.
Only fall back to web search in later rounds if you have genuinely exhausted your own ideas.

### Round procedure

For each round N (1 through 3):

1. **Design** — read `research_log/LEADERBOARD.md` and the latest round log, then decide
   what to try and why. Reason from first principles about what the profiles encode and
   what a better scoring function should capture.

2. **Implement** — write `method_{name}.py` following the same CLI as `method_baseline.py`:
   ```
   python method_{name}.py --manifest dataset/manifest.csv --split train --output /tmp/preds_train.csv
   python method_{name}.py --manifest dataset/manifest.csv --split val   --output /tmp/preds_val.csv
   ```
   If the method has tunable parameters, fit them on the train split only.

3. **Evaluate** — run evaluate.py on both splits and save to `results/{name}/`:
   ```bash
   conda run -n cfms-eval python method_{name}.py --manifest dataset/manifest.csv --split train --output /tmp/preds_train.csv
   conda run -n cfms-eval python evaluate.py --predictions /tmp/preds_train.csv --manifest dataset/manifest.csv --split train --output results/{name}/train.csv

   conda run -n cfms-eval python method_{name}.py --manifest dataset/manifest.csv --split val --output /tmp/preds_val.csv
   conda run -n cfms-eval python evaluate.py --predictions /tmp/preds_val.csv --manifest dataset/manifest.csv --split val --output results/{name}/val.csv
   ```

4. **Compare** — run `conda run -n cfms-eval python compare_methods.py --split val` and note
   the updated ranking.

5. **Update leaderboard** — add the new method's row to `research_log/LEADERBOARD.md`,
   re-sort by mean avg, and update the rank column.

6. **Document** — write `research_log/round_N.md` using this format:

```markdown
# Round N — {method name}

## Hypothesis
What you expected to improve and why.

## Design decisions
Key choices made and alternatives considered.

## Implementation notes
Any non-obvious details about how it was built.

## Results (val split, mean ± std over seeds)

| Condition | AUROC | AUPR | avg |
|-----------|-------|------|-----|
| without_noise/easy   | ... | ... | ... |
| ...                  | ... | ... | ... |
| **Mean across all**  | ... | ... | ... |

Comparison vs baseline avg: +X.XXX / −X.XXX

## What worked / what didn't
Honest assessment. Did the hypothesis hold?

## Recommendation for next round
What to build on, what to abandon.
```

---

## Final report

After all 3 rounds, write `/workspace/RESEARCH_REPORT.md`:

```markdown
# CF-MS Auto-Research Report

## Summary

Table of all methods tried, sorted by mean val avg (descending).
Copy the exact numbers from the results CSVs — do not round or approximate.

| Rank | Method | Mean AUROC | Mean AUPR | Mean avg | vs baseline avg |
|------|--------|-----------|----------|---------|-----------------|
| 1    | ...    | ...       | ...      | ...     | +X.XXX          |

## Full per-condition results (val split)

For each method, a complete table across all conditions:

| Method | Condition | AUROC | AUPR | avg |
|--------|-----------|-------|------|-----|
| ...    | without_noise/easy   | ... | ... | ... |
| ...    | without_noise/medium | ... | ... | ... |
| ...    | (all rows)           | ... | ... | ... |

## What helped

Bulleted list of approaches / design decisions that improved performance,
with a brief explanation of why they likely worked.

## What did not help

Bulleted list of approaches that failed, with hypothesis for why.

## Best method description

A clear, self-contained description of the best-performing method:
how it works, what preprocessing it applies, how it scores pairs,
and any parameters that were tuned on train.

## Recommended next directions

2–3 concrete ideas for further improvement, informed by what was learned.
```

Run `conda run -n cfms-eval python compare_methods.py --split val` one final time and confirm
the figure `/workspace/figures/results/comparison_val.png` reflects all methods.
