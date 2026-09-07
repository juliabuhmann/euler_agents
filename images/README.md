# euler-agents Singularity images

This directory holds the image definition for the agent runtime.

## Contents

- `euler-agents.def` — the Singularity definition file. Builds an Ubuntu 24.04 image with:
  - Node.js 24 + the two agent CLIs, `@anthropic-ai/claude-code` and `@openai/codex`, at the
    versions given by the build arguments `CLAUDE_CODE_VERSION` / `CODEX_VERSION`
    (default `latest`; the versions installed are recorded in `/etc/euler-agents-versions`)
  - Miniforge (conda + mamba) at `/opt/conda` — agents create their own envs at runtime
  - `uv` for fast pip installs; plus `git`, `curl`, `bubblewrap`, build tools, etc.

The built `.sif` files live **outside the repo** at
`/cluster/project/beltrao/jbuhmann/agentic_ai/images/`. The active image is selected by the
`image_path` key in `config/settings.local.json` (which overrides `config/settings.json` —
`euler-agent-run` merges local over base, so the `.local` value wins).

**Rebuilding is how you pick up new CLI / model support** — the `.def` itself usually needs no
edit. Pass the CLI version you run on the host as a build argument so the container and your
terminal behave identically (same features, and `claude --resume` works across the boundary on
shared sessions); without it, the build takes whatever `latest` is that day.

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
    --build-arg CLAUDE_CODE_VERSION="$(claude --version | awk '{print $1}')" \
    /cluster/project/beltrao/jbuhmann/agentic_ai/images/euler-agents-$(date +%Y%m%d).sif \
    images/euler-agents.def
```

`claude --version` on the host prints e.g. `2.1.263 (Claude Code)`; the `awk` keeps the number.
Add `--build-arg CODEX_VERSION=...` likewise if you use Codex. The existing `.sif` files are
untouched: if the build fails, nothing in production breaks.

### 3. Smoke-test the new image

Confirm the installed versions and that the stored login works, without touching the config:

```bash
IMG=/cluster/project/beltrao/jbuhmann/agentic_ai/images/euler-agents-YYYYMMDD.sif
singularity exec --cleanenv --containall --home "$PWD/home-claude:/home" "$IMG" \
    bash -lc 'export HOME=/home; cat /etc/euler-agents-versions; claude auth status'
```

`auth status` should report `loggedIn: true`. Then run a real task through the launcher after
step 4 (e.g. the interactive smoke test from the main README).

### 4. Point euler-agents at the new image

Edit `image_path` in `config/settings.local.json` (the effective override; also update
`config/settings.json` to keep the committed default in sync):

```json
"image_path": "/cluster/project/beltrao/jbuhmann/agentic_ai/images/euler-agents-YYYYMMDD.sif",
```

Rollback = point `image_path` back at the previous `.sif`. No rebuild needed.

Auth is **not** affected by a rebuild: the Claude login lives in `home-claude/` and Codex tokens
in `home-codex/` (each mounted as the agent's `$HOME`) — both are outside the image.

## Rebuild log

### 2026-09-07 — `euler-agents-20260907.sif` (Claude Code pinned to the host version)

- **Reason:** the container's Claude Code (2.1.185) lagged the host's (2.1.263). Since the
  launcher now shares session directories between host and container, the two should run the
  same version so `--resume` works in both directions.
- **Change:** `euler-agents.def` gained `%arguments` (`CLAUDE_CODE_VERSION`, `CODEX_VERSION`,
  default `latest`) and writes the installed versions to `/etc/euler-agents-versions`. Built with
  `--build-arg CLAUDE_CODE_VERSION=2.1.263`; Codex came out as `codex-cli 0.153.4` (latest).
- **Verified:** `/etc/euler-agents-versions` reports 2.1.263 and `claude auth status` with the
  stored login reports `loggedIn: true` (claude.ai, team subscription).
- **Action:** `image_path` repointed in `config/settings.json` and `config/settings.local.json`.

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
