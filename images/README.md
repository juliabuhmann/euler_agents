# euler-agents Singularity images

This directory holds the image definition for the agent runtime.

## Contents

- `euler-agents.def` — the Singularity definition file. Builds an Ubuntu 24.04 image with:
  - Node.js 24 + the two agent CLIs: `@openai/codex@latest` and `@anthropic-ai/claude-code@latest`
  - Miniforge (conda + mamba) at `/opt/conda` — agents create their own envs at runtime
  - `uv` for fast pip installs; plus `git`, `curl`, `bubblewrap`, build tools, etc.

The built `.sif` files live **outside the repo** at
`/cluster/project/beltrao/jbuhmann/agentic_ai/images/`. The active image is selected by the
`image_path` key in `config/settings.local.json` (which overrides `config/settings.json` —
`euler-agent-run` merges local over base, so the `.local` value wins).

Because both agent CLIs are pinned to `@latest`, **rebuilding is how you pick up new CLI / model
support** — the `.def` itself usually needs no edit.

## Rebuilding the image (versioned, no in-place swap)

Build each new image under a **dated filename** and repoint the config, rather than overwriting
the live `.sif`. This keeps the previous image as an instant rollback.

### 1. Get a node with internet and `--fakeroot`

A login node is usually enough:

```bash
module load eth_proxy        # network access for apt/npm/conda during %post
```

If the login node lacks resources or disallows the build, grab an interactive compute node
(SLURM) instead — request local scratch for the build tmpdir:

```bash
srun --ntasks=1 --cpus-per-task=4 --mem-per-cpu=4G --tmp=20G --time=01:00:00 --pty bash
module load eth_proxy
```

### 2. Build to a dated filename

```bash
cd ~/src/euler_agents
export APPTAINER_TMPDIR="${TMPDIR:-/tmp}/apptainer_tmp"; mkdir -p "$APPTAINER_TMPDIR"

singularity build --fakeroot \
    /cluster/project/beltrao/jbuhmann/agentic_ai/images/euler-agents-YYYYMMDD.sif \
    images/euler-agents.def
```

The existing `euler-agents.sif` is untouched. If the build fails, nothing in production breaks.

### 3. Smoke-test the new image

Confirm the CLI is current and the target model actually runs (replace the model as needed):

```bash
source config/secrets.env    # exports ANTHROPIC_API_KEY
singularity exec --cleanenv \
    --env ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
    /cluster/project/beltrao/jbuhmann/agentic_ai/images/euler-agents-YYYYMMDD.sif \
    bash -lc 'claude --version && claude --dangerously-skip-permissions \
        --model claude-opus-4-8 -p "reply with OK" --output-format json'
```

A clean JSON reply (no `thinking.type.enabled` 400) means the new CLI is good.

### 4. Point euler-agents at the new image

Edit `image_path` in `config/settings.local.json` (the effective override; also update
`config/settings.json` to keep the committed default in sync):

```json
"image_path": "/cluster/project/beltrao/jbuhmann/agentic_ai/images/euler-agents-YYYYMMDD.sif",
```

Rollback = point `image_path` back at the previous `.sif`. No rebuild needed.

Auth is **not** affected by a rebuild: Codex tokens live in `home-codex/` (mounted as `$HOME`)
and the Claude API key comes from `config/secrets.env` — both are outside the image.

## Rebuild log

### 2026-06-22 — `euler-agents-20260622.sif` (Claude Code refresh for Opus 4.8)

- **Reason:** the previous image (`euler-agents.sif`, built 2026-04-20) shipped a Claude Code
  version that sends the legacy `thinking.type.enabled` parameter. `claude-opus-4-8` rejects it
  with `400 ... "thinking.type.enabled" is not supported for this model. Use
  "thinking.type.adaptive" and "output_config.effort"`. Sonnet 4.6 still accepts the legacy form,
  so only Opus runs failed.
- **Change:** rebuild from the unmodified `euler-agents.def`, which reinstalls
  `@anthropic-ai/claude-code@latest` (and `@openai/codex@latest`) — picking up Opus 4.8 support.
- **Action:** repoint `image_path` in `config/settings.local.json` to the new `.sif`.

### 2026-04-20 — `euler-agents.sif` (initial image)

- First built image: Ubuntu 24.04, Node 24, Codex + Claude Code CLIs, Miniforge, uv.
