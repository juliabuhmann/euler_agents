# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Bash harness that runs Claude Code (or Codex) inside a Singularity/Apptainer container on ETH
Euler (SLURM). The container is the sandbox: agents run with permission prompts bypassed, and the
set of bind mounts is the only boundary. The README is the user-facing manual; `images/README.md`
covers rebuilding the `.sif` and keeps a rebuild log.

This is a fork set up for UNIL **Curnagl**: `origin` = `alpae/euler_agents`, `upstream` =
`juliabuhmann/euler_agents` (built for ETH Euler). To keep upstream merges easy, the
`euler-agent-*` names stay, and cluster differences live in config (`config/sites/`), not in
`if site == …` branches in the scripts.

## Development

There is no build or test suite. The scripts only really run on the cluster (they need
`singularity`, `sbatch`/`srun`, environment modules). Locally: `bash -n bin/<script>` and
`shellcheck -S warning bin/*` (the SC1090/SC2054/SC2088 hits are pre-existing and benign).

For a local dry run, copy the repo to a temp dir and put stubs first on `PATH`: an `sbatch`
that prints its arguments, a `singularity` that does the same, and on macOS a `realpath`
supporting `-m` (BSD's doesn't). Point `config/settings.local.json` in the copy at temp dirs and
set `HOME` to a temp dir — `euler-agent-run` writes into `~/.claude/projects` for session
sharing. That exercises partition selection, time limits, presets and bind validation.

On the cluster:

- `make install` / `make uninstall` — symlink `euler-agent-submit`, `euler-agent-run`, `gpu-avail` into `~/.local/bin`
- Smoke test (login node): `bin/euler-agent-run --agent claude --project harness-test --interactive`, then `claude -p "reply with exactly: OK"`
- Steerable session via SLURM: `euler-agent-submit --agent claude --remote-control --project NAME --time 8:00:00 [--workspace DIR]`
- `test_slurm/*.sh` are standalone sbatch scripts for checking SLURM/GPU allocation, not tests of the harness

Commits use conventional-commit style with a scope: `feat(run): …`, `fix(run): …`, `chore(image): …`, `docs: …`.

## Architecture

Call chain for a headless job:

```
euler-agent-submit  (host, login node: resources, presets, partition, max-time check; sbatch)
  └─ slurm/run-agent.sh  (in the SLURM job: thin, cluster-neutral wrapper)
       └─ bin/euler-agent-run  (host side on the compute node: site modules, config, workspace, binds, auth; container exec)
            └─ bin/inner.sh  (inside the container: clone repo, run claude -p / codex exec, append REPORT.md)
            └─ bin/notify.sh (host side, after the container exits: optional email)
```

Both host scripts source `bin/host-config.sh`, which merges the settings with the cluster
profile and defines `_setting` / `_site` / `_load_site_modules`. `euler-agent-run` loads the
site modules itself on every launch (batch job, held node, `--claude-login`), so no path needs a
manual `module load`, and it uses `container_cmd` from the profile rather than a literal
`singularity`.

The interactive path (`euler-agent-run --interactive`, use case 1 in the README) skips `inner.sh`
and starts `bash --rcfile bin/claude-shellrc`, which wraps `claude`/`codex` to add the bypass
flags and provides `claude-rc` for Remote Control. Both in-container entry points source
`bin/container-env.sh` so they set up HOME, PATH, conda/pixi/cache dirs and git identity the same
way — put shared in-container setup there, not in only one of them.

`euler-agent-submit` handles only SLURM allocation flags (`--cpus`, `--mem-per-cpu`, `--time`,
`--gpu-mem`, `--partition`, `--preset`); everything else is passed through to `euler-agent-run`.
It makes bind/ref/task-file paths absolute before passing them on, because the job may start in
a different cwd. New run-time flags go in `euler-agent-run`'s arg parser and usage text; new
allocation flags go in `euler-agent-submit`.

### Key invariants in `bin/euler-agent-run`

- **Identity binds**: every host directory is mounted at its own path (`SRC:SRC`), so paths the
  agent writes are valid on the host. Only `/home` (the agent home) and `/tmp` (per-launch
  scratch `$TMPDIR/euler-agents.<jobid>.<pid>/scratch`) are container-private. The host `$HOME`
  is never mounted. The repo itself is bound read-only so the agent can't edit its own launcher.
- **One shared agent home** `home-<agent>/` (in the repo, or under `agent_home_dir`), used directly
  by every container — deliberately not copied per job, because claude.ai refresh tokens rotate
  and copies go stale (see the comment around `SOURCE_HOME`).
- **Bind precedence**: `--extra-bind`/`--extra-read-bind` flags first, then `--binds-file`
  entries, which are skipped if their destination is already in `MOUNTED_DESTS`. Specs are
  `SRC[:DEST][:ro|rw]`; DEST must be absolute, which is how `SRC:DEST` is told apart from `SRC:MODE`.
  `--extra-read-bind` with an explicit `:rw` is an error, not a silent downgrade.
- **Host-side pre-seeding** of `home-claude/.claude.json` and `.claude/settings.json`: workspace
  trust for every bind destination, onboarding done, bypass-permissions disclaimer accepted. These
  are Claude Code internal keys and may break with CLI upgrades.
- **Session sharing**: for the workspace and each rw bind, the host's
  `~/.claude/projects/<encoded path>` is bind-mounted into the agent home so `claude --resume`
  works across the boundary (which is why the image pins the host's Claude Code version).
- **Auth modes** (`--auth`): `login` (default; stored OAuth in `home-claude/.claude/.credentials.json`
  from `--claude-login`), `subscription` (`CLAUDE_CODE_OAUTH_TOKEN`), `apikey` (`ANTHROPIC_API_KEY`).
  Credentials come from `config/secrets.env` / `config/secrets.local.env`. `--remote-control`
  works only with `login` and requires `--project` (it names the session `euler-rc-<project>-<jobid>`).
- **No git credentials in the container**, by design. `container-env.sh` sets the commit identity
  and points `core.hooksPath` at `config/git-hooks/`, whose `commit-msg` appends an agent
  `Co-Authored-By` trailer. The user pushes from the host.
- **The workspace is the starting directory**: `<workspace_dir>/<project>`, or any absolute
  `--workspace DIR` (requires `--project`, which then only names the session). Claude keys trust
  and session sharing by exact cwd, so the workspace is always in both lists.
- A per-session `/tmp/agent-briefing.md` is generated from `config/agent-briefing.md` plus the
  actual mount table.

### Configuration

- `config/settings.json` is the committed default; `config/settings.local.json` (gitignored) is
  merged over it with a **shallow** `dict.update` — a nested block like `"slurm"` or `"claude"` is
  replaced whole.
- **Cluster profiles**: `"site"` (default `curnagl`) selects `config/sites/<site>.json` — modules,
  `container_cmd`, `max_time`, `cpu_partition` / `gpu_partition` or Euler's
  `gpu_partitions_by_hours`, `gpu_request`, `default_gpu_type`, `gpu_mem_gres`, `gpu_sbatch_args`,
  `mail_domain`, `presets` (override `config/presets.json` by name). `"site_overrides"` in
  settings patches single keys. Anything cluster-specific goes here.
- Settings are read through `_setting`/`_site`/`_agent_setting`, which run small `python3 -c`
  snippets; each agent reads only its own section (`claude`/`codex`).
- Values parsed out of `$(python3 …)` with `read`: `$(…)` strips trailing empty lines, so a
  multi-line result read line by line needs a sentinel last line (see `_apply_preset`).
- Task resolution: `--task` > `--task-file` > `config/task.json` (which can also set model,
  effort, budget, repo_url, project) > per-agent defaults in settings.
- `legacy_workspace_dirs`: a `--project` not found under `workspace_dir` is looked up there.
- `config/presets.json` backs `--preset`.
- `config/agent-CLAUDE.md.template` is a template users copy into their bind as the agent's
  `CLAUDE.md`; it is not instructions for this repo.

### Image

`images/euler-agents.def` builds Ubuntu 24.04 + Node 24 + the Claude Code and Codex CLIs (versions
via `CLAUDE_CODE_VERSION`/`CODEX_VERSION` build args) + Miniforge at `/opt/conda` + uv. Images are
built (`--fakeroot`, on a login node) under dated filenames outside the repo — on Curnagl in a
`/work` project dir; upstream's Euler images are in `/cluster/project/beltrao/jbuhmann/agentic_ai/images/`
— and selected via `image_path`; when rebuilding,
update `image_path` in `config/settings.json` and add an entry to the rebuild log in
`images/README.md`.

Default model names appear in several places (`config/settings.json`, fallbacks in
`bin/inner.sh`, help text and README); keep them in sync when changing defaults.
