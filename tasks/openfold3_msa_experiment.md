You are a bioinformatics engineer continuing work on OpenFold3 on the ETH Zurich Euler HPC cluster.
A previous agent already installed OpenFold3 and ran a successful no-MSA ubiquitin prediction in this workspace.
Your job is to explore how MSA works in OpenFold3 and benchmark MSA vs. inference timing for up to 5 proteins.

---

## Previous work (already done — do not repeat)

The previous agent completed the following (see `/workspace/REPORT.md` for details):

- Cloned openfold-3 to `/workspace/openfold3-src`
- Installed pixi 0.67.2 to `/workspace/pixi-home`; environment: `openfold3-cuda13`
- Downloaded model weights: `/workspace/openfold3_cache/of3-p2-155k.pt` (2.29 GB)
- Ran ubiquitin prediction with `--use-msa-server=False`, `--runner-yaml /workspace/low_mem.yml`
- Working runner YAML at `/workspace/low_mem.yml`:
  ```yaml
  model_update:
    presets:
      - predict
      - low_mem
  data_module_args:
    num_workers: 0
  ```
- Key constraint: 16 GiB SLURM cgroup memory; `num_workers=0` is required to avoid OOM

Setup commands to reproduce the environment (already done, just for reference):
```bash
export PIXI_HOME=/workspace/pixi-home
export PATH="/workspace/pixi-home/bin:$PATH"
export OPENFOLD_CACHE=/workspace/openfold3_cache
cd /workspace/openfold3-src
```

---

## Your goals

### Goal 1 — Understand MSA options in OpenFold3

Before running anything, read the relevant source files to understand how MSA is configured:

1. Check `run_openfold --help` (or the CLI source in `/workspace/openfold3-src`) for all MSA-related flags.
   Focus on: `--use-msa-server`, any `--msa-*` flags, local database flags, and `--num-msa-sequences`.
2. Read the OpenFold3 inference docs if available locally (check for `docs/` or `*.md` in the repo).
3. Understand the two MSA modes:
   - **Remote MSA** (`--use-msa-server=True`): queries the ColabFold MMseqs2 API — requires internet from the compute node.
   - **Local MSA**: runs jackhmmer/hmmer locally against sequence databases — requires local DB files and hmmer tools.

Write your findings to `/workspace/msa_options.md` before proceeding.

---

### Goal 2 — Check what MSA tools and databases are available on Euler

Run these checks:

```bash
# Check if MSA tools are available
which jackhmmer 2>/dev/null || echo "jackhmmer not found"
which hmmbuild 2>/dev/null || echo "hmmbuild not found"
which mmseqs 2>/dev/null || echo "mmseqs not found"
module avail 2>&1 | grep -iE "hmmer|mmseqs|blast" | head -20

# Check for sequence databases on cluster shared storage
ls /cluster/work/beltrao/ 2>/dev/null | head -20
ls /cluster/databases/ 2>/dev/null | head -20
find /cluster -maxdepth 4 -name "uniref90*" -o -name "uniclust*" -o -name "mgnify*" 2>/dev/null | head -10

# Check if the compute node has internet access
curl -s --max-time 5 https://api.colabfold.com 2>&1| head -5 || echo "No internet access"
```

Write results to `/workspace/msa_availability.md`.

---

### Goal 3 — Prepare a multi-protein input JSON

Create a query JSON with 5 proteins of varying lengths. Use these sequences (well-known, no copyright issues):

```json
[
  {
    "name": "ubiquitin",
    "sequences": [
      {"proteinChain": {"sequence": "MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEGIPPDQQRLIFAGKQLEDGRTLSDYNIQKESTLHLVLRLRGG", "count": 1}}
    ]
  },
  {
    "name": "gb1",
    "sequences": [
      {"proteinChain": {"sequence": "MQYKLILNGKTLKGETTTEAVDAATAEKVFKQYANDNGVDGEWTYDDATKTFTVTE", "count": 1}}
    ]
  },
  {
    "name": "villin_hp35",
    "sequences": [
      {"proteinChain": {"sequence": "LSDEDFKAVFGMTRSAFANLPLWKQQNLKKEKGLF", "count": 1}}
    ]
  },
  {
    "name": "trp_cage",
    "sequences": [
      {"proteinChain": {"sequence": "NLYIQWLKDGGPSSGRPPPS", "count": 1}}
    ]
  },
  {
    "name": "chignolin",
    "sequences": [
      {"proteinChain": {"sequence": "GYDPETGTWG", "count": 1}}
    ]
  }
]
```

Save this as `/workspace/query_5proteins.json`.

Also create individual single-protein JSON files under `/workspace/query_single/` for the timing benchmarks.

---

### Goal 4 — MSA timing experiments

For each experiment, record wall-clock time (`time` command or `/usr/bin/time -v`), peak memory, and whether MSA succeeded.

#### Experiment A — No-MSA baseline (for comparison)

Run all 5 proteins with MSA disabled, time it:

```bash
cd /workspace/openfold3-src
time OPENFOLD_CACHE=/workspace/openfold3_cache \
  /workspace/pixi-home/bin/pixi run -e openfold3-cuda13 run_openfold predict \
    --query-json /workspace/query_5proteins.json \
    --use-msa-server=False \
    --runner-yaml /workspace/low_mem.yml \
    --output-dir /workspace/output_nomsa_5/ \
  2>&1 | tee /workspace/timing_nomsa_5.log
```

#### Experiment B — Remote MSA (ColabFold server), 1 protein

If internet is available (from Goal 2), try MSA via the ColabFold server for a single short protein (chignolin or trp_cage):

```bash
cd /workspace/openfold3-src
time OPENFOLD_CACHE=/workspace/openfold3_cache \
  /workspace/pixi-home/bin/pixi run -e openfold3-cuda13 run_openfold predict \
    --query-json /workspace/query_single/chignolin.json \
    --use-msa-server=True \
    --runner-yaml /workspace/low_mem.yml \
    --output-dir /workspace/output_msa_server_1/ \
  2>&1 | tee /workspace/timing_msa_server_1.log
```

If this fails (no internet, server down, etc.), note the error and move on.

#### Experiment C — Remote MSA, 5 proteins

If Experiment B succeeded, run all 5 proteins with remote MSA:

```bash
cd /workspace/openfold3-src
time OPENFOLD_CACHE=/workspace/openfold3_cache \
  /workspace/pixi-home/bin/pixi run -e openfold3-cuda13 run_openfold predict \
    --query-json /workspace/query_5proteins.json \
    --use-msa-server=True \
    --runner-yaml /workspace/low_mem.yml \
    --output-dir /workspace/output_msa_server_5/ \
  2>&1 | tee /workspace/timing_msa_server_5.log
```

#### Experiment D — Local MSA (only if jackhmmer + databases are available)

If local MSA tools and databases are available (from Goal 2), run a local MSA experiment.
Configure whatever flags are needed based on what you found in Goal 1.
Time separately: MSA step alone (if separable) vs full inference.

Skip this experiment if neither jackhmmer nor local databases are available.

---

### Goal 5 — GPU resource experiment

Run the 5-protein no-MSA inference (or MSA if it worked) and observe GPU utilisation:

```bash
# Start GPU monitoring in background, sample every 10 s
nvidia-smi dmon -s u -d 10 > /workspace/gpu_utilisation.log &
GPUMON_PID=$!

# Run inference
cd /workspace/openfold3-src
time OPENFOLD_CACHE=/workspace/openfold3_cache \
  /workspace/pixi-home/bin/pixi run -e openfold3-cuda13 run_openfold predict \
    --query-json /workspace/query_5proteins.json \
    --use-msa-server=False \
    --runner-yaml /workspace/low_mem.yml \
    --output-dir /workspace/output_gpu_monitor/ \
  2>&1 | tee /workspace/timing_gpu_monitor.log

kill $GPUMON_PID
```

From the GPU log, report: mean GPU utilisation (%), peak VRAM used (MiB), and any idle gaps where GPU was waiting (likely for MSA / data loading).

---

## Synthesise findings in REPORT.md

Append a new section to `/workspace/REPORT.md` (or create it if missing) with the following structure:

```markdown
## MSA Experiment — <date>

### MSA options in OpenFold3
<Summary of flags found: what --use-msa-server controls, any local-MSA flags, num_msa_sequences, etc.>

### MSA tools and databases on Euler
<What is available: jackhmmer, mmseqs, databases. What is missing.>

### Timing results

| Experiment | Proteins | MSA mode | Wall time | Peak mem | Notes |
|---|---|---|---|---|---|
| A — no MSA | 5 | disabled | Xs | Y GiB | |
| B — server MSA | 1 | ColabFold API | Xs | Y GiB | |
| C — server MSA | 5 | ColabFold API | Xs | Y GiB | |
| D — local MSA | N | jackhmmer | Xs | Y GiB | skipped if N/A |

### GPU utilisation
<Mean GPU %, peak VRAM, any idle gaps and what caused them>

### Plan: disentangling MSA (CPU) from folding inference (GPU) on Euler

The eventual goal is to run this pipeline for many proteins as a **Snakemake workflow** on Euler.
Keep this in mind: the plan should map naturally onto Snakemake rules, where each rule has defined
inputs/outputs and can specify its own SLURM resources (CPUs, memory, GPU, time).

<Based on the above, write a concrete recommendation. Address:>
1. Whether MSA should be a separate SLURM job step (CPU-only, high memory, no GPU) or a separate job array.
2. Approximate CPU and memory requirements for MSA of N proteins (extrapolate from timing).
3. Approximate GPU time per protein for folding-only inference.
4. Suggested SLURM job structure: e.g., precompute MSA files in a CPU job → pass precomputed MSA to GPU inference job.
5. Any Euler-specific constraints (internet access on GPU nodes, scratch storage for MSA files, etc.).
6. **Snakemake design sketch**: for inspiration, first clone the batch-infer repo (an existing AF3 Snakemake
   pipeline for Euler) and read its MSA and prediction rules:

   ```bash
   git clone https://github.com/jurgjn/batch-infer /workspace/batch-infer
   cat /workspace/batch-infer/workflow/rules/alphafold3_msas.smk
   cat /workspace/batch-infer/workflow/rules/alphafold3_predictions.smk
   cat /workspace/batch-infer/workflow/config/*.yaml
   ```

   The AF3 approach: one protein per MSA job (`{id}` wildcard, `--norun_inference`), all proteins batched
   into one GPU job (`--norun_data_pipeline`). Intermediate files are `alphafold3_msas/{id}_data.json.gz`.

   OpenFold3 will likely need a **different architecture** — investigate and explain:
   - Does OpenFold3 have equivalent flags to split MSA from inference (like AF3's `--norun_inference` /
     `--norun_data_pipeline`)? If not, is there another way to precompute and cache MSA results (e.g. saving `.a3m` files)?
   - What is the intermediate file format for OpenFold3 MSA output?
   - Should the fold rule process one protein per job (unlike AF3 which batches all) given OpenFold3's different batching model?
   - Where to store intermediate MSA files on Euler scratch storage
   - Whether the MSA rule can be parallelised across proteins independently
```

---

## Done

Print a short summary of your findings (< 30 lines): what MSA options exist, what worked, timing numbers, and the top recommendation for the CPU/GPU split on Euler.
