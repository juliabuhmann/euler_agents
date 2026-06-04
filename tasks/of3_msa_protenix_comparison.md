## Environment

- Singularity container — no `sbatch`, no `module load`; run everything directly
- Named project: `of3-bw-native` — `/workspace/` is bound to that project dir
- OpenFold3 (Blackwell build) — all paths relative to `/workspace/`:
  - Python: `/workspace/openfold3-src/.pixi/envs/openfold3-cuda13/bin/python3.13`
  - Source: `/workspace/openfold3-src`
  - Weights: `/workspace/openfold3_cache/of3-p2-155k.pt`
  - Torch extensions cache: `/workspace/torch_extensions`
- Repo cloned via `--repo`: `/workspace/pooled_ppi_comparison/`
  - Runner YAML (Blackwell, Triton kernels): `/workspace/pooled_ppi_comparison/bw_triton.yml`
- Protenix MSA cache (read-only): `/reference/` — one subdirectory per UniProt accession, each with `msa/0.a3m`
- GPU: RTX Pro 6000 Blackwell (96 GB, SM_120); confirm with `nvidia-smi` before running
- Internet available; GitHub credentials injected

Run OF3 as (matching `slurm/run_of3_bw_pool.sh`):
```bash
OF3_ENV=/workspace/openfold3-src/.pixi/envs/openfold3-cuda13
ln -sf "$OF3_ENV/bin/ptxas" "$OF3_ENV/bin/ptxas-blackwell"
export PATH="$OF3_ENV/bin:$PATH"
export LD_LIBRARY_PATH="$OF3_ENV/lib:${LD_LIBRARY_PATH:-}"
export CUDA_HOME=$OF3_ENV
export TORCH_EXTENSIONS_DIR=/workspace/torch_extensions
PYTHONPATH=/workspace/openfold3-src \
  "$OF3_ENV/bin/python3.13" -m openfold3.run_openfold predict \
    --query-json  <json> \
    --use-msa-server=<true|false> \
    --runner-yaml /workspace/pooled_ppi_comparison/bw_triton.yml \
    --inference-ckpt-path /workspace/openfold3_cache/of3-p2-155k.pt \
    --output-dir  <out_dir>
```

Check `/workspace/REPORT.md` at the start if it exists — it may contain context from prior runs.

## Goal

Determine whether Protenix-format A3M MSA files can be used as input to OpenFold3, and quantify
whether switching from online (ColabFold server) MSA to precached Protenix MSA changes the
predicted confidence scores (ipTM, pTM, ranking_score) for a known yeast interacting pair.

The test complex is a known yeast PPI: **p0c2h7 + p38779** (positive interactor pair from
`benchmarks/yeast_real/datasets/validation_50_nproteins_seed42/`, STRING experimental score 912).
Read their sequences from `sequences.tsv` in that dataset directory — do not hardcode them.

Run two OF3 predictions on this pair, clearly named by condition:

| Condition label | MSA source | OF3 JSON field |
|---|---|---|
| `of3_msa_server` | ColabFold server (on-the-fly) | `use-msa-server=true`, no file paths |
| `of3_protenix_msa` | Protenix `.a3m` cache (`/reference/<acc>/msa/0.a3m`) | `main_msa_file_paths` per chain |

Then compare ipTM / pTM / ranking_score across the two conditions and document the result.

## Branch and scripts

1. Create and check out a new branch: `euler/of3-msa-protenix-msas`
2. Add all new scripts under `scripts/2026may_msaof/` in the repo
3. Commit the scripts and push the branch to GitHub

## Steps

### 1. Understand the OF3 query JSON format

Read `openfold3/projects/of3_all_atom/config/inference_query_format.py` in the OF3 source.
The `Chain` model supports `paired_msa_file_paths` and `main_msa_file_paths` (lists of paths
to A3M files). Decide which field to use for the Protenix per-chain `.a3m` files (likely
`main_msa_file_paths`; investigate whether the Protenix cache provides paired or unpaired MSAs
by inspecting `/reference/p0c2h7/msa/0.a3m` header lines).

### 2. Write a script to build the OF3 query JSONs

`scripts/2026may_msaof/01_build_of3_jsons.py`

The script should:
- Accept `--accessions ACC1 ACC2 ...` and an `--msa-cache-dir` argument
- Read sequences from `benchmarks/yeast_real/datasets/validation_50_nproteins_seed42/sequences.tsv`
- Write two OF3-format query JSONs under a specified `--out-dir`:
  - `<complex>_server_msa.json` — sequences only, relies on `--use-msa-server=true` at inference
  - `<complex>_protenix_msa.json` — adds `main_msa_file_paths` (or `paired_msa_file_paths` if
    appropriate) per chain, pointing to the **absolute cluster paths** of the `.a3m` files
    (since the scripts run outside the container when submitted to SLURM)

The query name and structure should follow the pool2 OF3 JSON format in `pool_input/pool2_of3.json`
for reference.

### 3. Run both OF3 conditions

Use the invocation pattern from the Environment section above. Run both conditions; output directories must be clearly labeled:
- `/workspace/of3_msa_protenix/predictions/of3_msa_server/`
- `/workspace/of3_msa_protenix/predictions/of3_protenix_msa/`

### 4. Compare results

Write `scripts/2026may_msaof/02_compare_confidence.py`:
- Reads `*_summary_confidences.json` files from both output directories
- Prints and saves a comparison table: condition × {ranking_score, iptm, ptm, fraction_disordered}

Run it and include the output in the commit / REPORT.

### 5. Document and commit

Write a brief summary to `/workspace/REPORT.md`:
- Which condition (server vs. Protenix MSA) produced what scores
- Whether Protenix MSAs were accepted without errors by OF3
- Any format issues found (headers, pairing vs. unpaired distinction)

Commit to the branch:
```
git add scripts/2026may_msaof/
git commit -m "feat(msa): add OF3 + Protenix MSA comparison scripts and results"
git push -u origin euler/of3-msa-protenix-msas
```

## Success criteria

- Both OF3 predictions complete without errors
- `scripts/2026may_msaof/01_build_of3_jsons.py` and `02_compare_confidence.py` committed to the branch
- A comparison table (at minimum: ranking_score, ipTM, pTM for each condition) is printed and saved
- `/workspace/REPORT.md` documents whether Protenix MSAs worked and any caveats

## On format mismatch

If OF3 rejects the Protenix `.a3m` files (wrong headers, missing pairing rows, etc.):
- Diagnose the exact error and inspect the `.a3m` header lines to understand what
  transformation is needed (e.g. ColabFold pairing tags → OF3 paired format)
- Write `scripts/2026may_msaof/00_convert_protenix_msa.py` that converts the cached
  Protenix `.a3m` files to whatever OF3 requires, then re-run the `of3_protenix_msa`
  condition with the converted files
- The goal is always to get both conditions to complete so the scores can be compared —
  a conversion step is fine as long as it is scripted and reproducible

## On GPU / CUDA failure

If the Blackwell GPU is unavailable or OF3 crashes with a CUDA error:
- Document GPU state from `nvidia-smi` in `REPORT.md`
- Do not retry inference; commit the scripts and the diagnostic output
