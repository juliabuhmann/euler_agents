You are working in /workspace. Your goal is to create a reusable benchmarking dataset for co-fractionation mass spectrometry (CF-MS) protein complex inference.

## Reference pipeline

Study the scripts in /reference/ — in particular:
- `config.py` — all simulation parameters and their defaults
- `01_generate_ground_truth.py` — how synthetic protein-complex networks are generated
- `02_generate_synthetic_profiles.py` — how SEC-MS elution profiles are simulated (Gaussians + noise)

Use these as the basis for understanding the data format and simulation approach. Write clean, self-contained scripts tailored to this benchmark generation task.

## Dataset structure

The dataset has two axes:

**Noise condition** (`without_noise`, `with_noise`):
- `without_noise`: no measurement noise, no missing values — elution profiles are clean Gaussians
- `with_noise`: realistic noise and missing values as in the reference pipeline

**Network difficulty** (`easy`, `medium`, `hard`):
- Refers only to network structure complexity (number of proteins, complex sizes, degree of subunit sharing/overlap)
- Based on your study of the reference pipeline parameters, choose values that produce meaningfully different inference challenges
- Noise parameters are fixed per noise condition and do not vary across difficulty levels

For each combination, generate datasets for three splits (**train**, **val**, **test**) with **5 independent replicates** each (seeds 0–4).

Total: 2 noise conditions × 3 difficulty levels × 3 splits × 5 seeds = **90 datasets**.

## Output structure

```
/workspace/
├── generate_ground_truth.py    # reusable, argparse CLI
├── generate_profiles.py        # reusable, argparse CLI
├── generate_benchmark.py       # orchestrator: generates all 90 datasets
├── dataset/
│   ├── README.md               # documents difficulty levels, parameter choices, and noise settings
│   ├── manifest.csv            # one row per dataset (see columns below)
│   ├── without_noise/
│   │   ├── easy/
│   │   │   ├── train/seed_0/{ground_truth.npz, profiles.npz}
│   │   │   ├── train/seed_1/ ...
│   │   │   ├── val/
│   │   │   └── test/
│   │   ├── medium/
│   │   └── hard/
│   └── with_noise/
│       ├── easy/
│       ├── medium/
│       └── hard/
```

## Data format requirements

- `ground_truth.npz`: `proteins`, `complexes`, `adjacency`, `protein_mw`, `complex_mw`
- `profiles.npz`: `profiles` (n_proteins × n_fractions), `fractions`, `proteins`
- `manifest.csv` columns: `noise_condition`, `difficulty`, `split`, `seed`, `n_proteins`, `n_complexes`, `n_edges`, `ground_truth_path`, `profiles_path`

After generating everything, print a summary table confirming all 90 datasets were created.
