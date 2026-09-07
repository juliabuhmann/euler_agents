# euler_agents

## In a nutshell

Run Claude Code on Euler compute nodes. The agent runs inside a Singularity container — the
container runtime available on HPC clusters — which isolates it from the host filesystem: it sees
only the directories you explicitly mount, and it sees them **at their host paths**, so scripts,
job files and conda environments the agent produces run unchanged outside the container.

Two ways to use it:

**1. [Sandboxed autonomous session](#use-case-1--sandboxed-autonomous-session)** — start the
agent inside the container and let it work. Because the container is the boundary, the agent's
permission prompts are switched off: you stop approving every file write and shell command, and
it keeps going on its own. You decide what it can touch by mounting directories read-write or
read-only. Work alongside it in the terminal, or optionally hand the session to
[claude.ai/code](https://claude.ai/code) or the mobile app and check in from your phone.

```bash
# on a node you hold, inside tmux — see the section for the node allocation
bin/euler-agent-run --agent claude --project mywork --remote-control --interactive \
    --extra-bind      /path/to/writable/dir \
    --extra-read-bind /path/to/readonly/data
# then inside the container:   cd /path/to/writable/dir && claude-rc
```

**2. [Submit a task and wait](#use-case-2--submit-a-task-and-wait)** — you write the task up
front, SLURM runs it unattended, and you read the output when it finishes. Best when the work is
well defined.

```bash
euler-agent-submit --agent claude --project my-analysis \
    --task "Explore the CSV files in data/, fit a linear regression, write findings to results/report.md"
```

Both run with confirmation prompts disabled — the container is the only boundary. See
[what the sandbox does and does not protect](#what-the-sandbox-does-and-does-not-protect)
before pointing one at data you care about.

---

## Setup (do once)

### 1. Install Claude Code

Check whether you already have it:

```bash
claude --version
```

If not, install it (user-space, no root):

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Make sure the install location is on your PATH (`~/.local/bin` for the script installer). The
container ships its own copy of Claude Code, so this is for using `claude` in your own terminal
and for the login step below.

### 2. Clone and configure

```bash
cd ~/src
git clone <repo-url> euler_agents
cd euler_agents
make install   # symlinks CLIs to ~/.local/bin
```

Add `~/.local/bin` to your PATH if it isn't already (add to `~/.bashrc`):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Create `config/settings.local.json` with your own paths (gitignored, merges over
`settings.json`):

```json
{
  "workspace_dir": "/cluster/project/<group>/<username>/workspaces",
  "logs_dir":      "/cluster/project/<group>/<username>/logs",
  "image_path":    "/cluster/project/beltrao/jbuhmann/agentic_ai/images/euler-agents.sif"
}
```

```bash
mkdir -p /cluster/project/<group>/<username>/{workspaces,logs}
```

> The merge is shallow: a top-level key in `settings.local.json` replaces the whole block from
> `settings.json`. If you override part of `"slurm"` or `"claude"`, restate every key in it.

### 3. Singularity image

A pre-built image is at `/cluster/project/beltrao/jbuhmann/agentic_ai/images/euler-agents.sif` —
no action needed unless you are rebuilding it. See
[rebuilding the image](#rebuilding-the-image).

### 4. Log in to your claude.ai account

One login covers everything: running the agent, and steering it from the browser or mobile app.
Run this on a **login node** — it needs a terminal and network access:

```bash
cd ~/src/euler_agents
bin/euler-agent-run --claude-login
```

Pick your **claude.ai account**, not an API key. This runs `claude auth login` inside the
container with `home-claude/` mounted writable, so the credential is stored in
`home-claude/.claude/.credentials.json` and copied into every run afterwards. It carries a refresh
token, so it renews itself rather than expiring after a few hours.

This is the default (`--auth login`). Two alternatives exist if you need them: a long-lived
`claude setup-token`, or pay-per-use with an API key — both in
[using a token or API key instead](#using-a-token-or-api-key-instead).

> Steering a session (Remote Control) accepts **only** this credential; the other two are
> rejected. If it later fails with a 401, the login was revoked — repeat this step.

### 5. Smoke test

Check the image, the mounts and your credential in one go, on a login node:

```bash
cd ~/src/euler_agents
bin/euler-agent-run --agent claude --project harness-test --interactive
```

Inside the container you should land at a `(euler-agents) <workspace_dir>/<project> $` prompt. Then:

```bash
claude --version
claude -p "reply with exactly: OK"
exit
```

A clean `OK` means image, auth and network all work.

---

## Use case 1 — Sandboxed autonomous session

An agent working on your own directories with the container as the safety boundary: read-only
mounts for data it must not damage, read-write only where it should produce something. You hold
the node yourself, so you can watch it, restart it and run commands alongside it — and the
session is steerable from [claude.ai/code](https://claude.ai/code) or the Claude mobile app, so
you can check in from your phone and put it down again.

### Step by step

**1. Allocate a long-running node** — detached, so it outlives your shell. Size it for the work
the agent will do; the wall time also bounds how long the session lives.

*CPU only*, with generous cores and memory (16 × 8 GB = 128 GB here) for data wrangling and
analysis. Leave the partition to SLURM, which picks one from the requested time:

```bash
sbatch --time=1-00:00:00 \
    --cpus-per-task=16 --mem-per-cpu=8G --tmp=100G \
    --job-name=agent-node --wrap="sleep infinity"
```

*With a GPU*, when the agent needs to train or run inference. Here the partition family depends
on the card — see [GPUs, partitions and Slurm accounts](#gpus-partitions-and-slurm-accounts):

```bash
sbatch -p cuda13pr.120h --time=5-00:00:00 \
    --gpus=nvidia_rtx_pro_6000:1 --gres=gpumem:96g \
    --cpus-per-task=4 --mem-per-cpu=8G --tmp=100G \
    --job-name=agent-node --wrap="sleep infinity"
```

An idle GPU reservation still holds the card, so prefer the CPU node unless the agent needs one.

**2. Find the node and SSH in** (once the job shows `R` / RUNNING):

```bash
squeue --me                 # note JOBID and NODELIST (e.g. eu-g5-042)
ssh <nodename>              # Euler allows SSH to nodes you hold an allocation on
# fallback if SSH to the node is blocked:  srun --jobid=<jobid> --pty bash
```

**3. Start tmux on the node** — not on a login node, where long-lived processes get reaped:

```bash
tmux new -s agent
```

**4. Start the container with the directories you want mounted.** Use `euler-agent-run`, *not*
`submit` — you already hold the node:

```bash
cd /path/to/euler_agents
bin/euler-agent-run --agent claude --project mywork --remote-control --interactive \
    --extra-bind      /path/to/writable/dir \
    --extra-read-bind /path/to/readonly/data
```

Add `--gpu` if the agent needs the GPU inside the container. Pass only node-*use* flags here
(`--project`, `--gpu`, `--extra-bind`, `--extra-read-bind`, `--ref`). Allocation flags
(`--cpus`, `--mem-per-cpu`, `--time`, `--gpu-mem`) were fixed in step 1 and `run` rejects them.

**5. Start the agent:**

```bash
cd /path/to/writable/dir   # same path as on the host — work where the code should end up
claude-rc                  # steerable session, permission prompts already disabled
```

Detach from tmux with `Ctrl-b d`. To reconnect after a disconnect, SSH back to the **same** node
and `tmux attach -t agent`. Find the session by name (`euler-rc-<project>-<jobid>`) in the app.

`claude-rc` is a helper from `bin/claude-shellrc`; it runs `claude remote-control` with a session
name and `--permission-mode bypassPermissions`. What `--remote-control` changes:

- `--project` becomes **required**, and `/home` becomes persistent
  (`<workspace>/<project>/.claude-home`) so the login and the conversation transcripts survive
  the job ending.
- Workspace trust is pre-accepted for the workspace and every bind, because
  `claude remote-control` prompts for it and has no bypass flag.
- It accepts **only** the stored claude.ai login from Setup step 4 — a `setup-token` or API key
  is rejected. `--model`, `--effort`, `--max-budget-usd` and `--auth` are ignored; you pick the
  model per session in the app.

The session dies when the SLURM job ends, so size the allocation in step 1 accordingly.

**If the login was revoked or you switched accounts**, `claude-rc` fails with a 401. Re-run
`bin/euler-agent-run --claude-login` (delete `home-claude/.claude/.credentials.json` first if it
refuses because a login already exists). The next launch of every project copies the newer
login into that project's `.claude-home`, keeping its transcripts and MCP authorizations; a
running container needs `claude auth login` inside instead.

### Mounting extra directories

Two flags, both repeatable, so any number of directories can be added in either mode:

| Flag | Mode | Meaning |
|---|---|---|
| `--extra-bind SRC` | read-write | the agent can read and write here |
| `--extra-read-bind SRC` | read-only | the agent can read but not modify; an explicit `:rw` is rejected rather than silently downgraded |

A repository can carry its own list instead, so you stop retyping it: put a file such as
`euler-agents.binds` in the repo (start from `config/binds.example`) and pass it with
`--binds-file`, in either use case:

```
# euler-agents.binds — one SRC[:DEST][:ro|rw] per line, mode defaults to ro
.:rw                                              # this repo, read-write
/cluster/project/<group>/<user>/mydata:ro         # input data
```

```bash
bin/euler-agent-run --agent claude --project mywork --interactive \
    --binds-file ~/src/myrepo/euler-agents.binds
```

Relative entries resolve against the file's directory, so `.` is the repo itself. A flag for
the same destination wins, so `--extra-bind /…/mydata` makes a read-only entry writable for one
run. Missing sources and malformed lines are errors, reported with the file name.

**Directories appear at their host path inside the container.** That is the default and the point:
an absolute path, a shebang, a conda prefix or a SLURM script the agent writes inside is valid
outside, so you never translate paths. `SRC:DEST` is still accepted for the rare case where you
need a different name; `DEST` must then be absolute. A bad spec — missing source, relative
`DEST`, contradictory mode — fails before the container starts, with the reason.

What the agent can reach, and nothing else:

| Path | Mode | Notes |
|---|---|---|
| `<workspace_dir>/<project>` | rw | the workspace — project storage; large or generated output belongs here |
| your binds | per flag | whatever you passed above, at the same paths |
| host conda envs | **ro** | from `conda_envs_dir` in settings; usable, not modifiable |
| host conda pkgs, pixi home, cache dir | rw | from settings; shared caches so nothing lands under the quota-limited home |
| this repo | **ro** | the launcher scripts — the agent cannot edit what constrains it |
| `/home` | rw | agent state; persistent per project, or a throwaway copy in the terminal-only variant. **Not** your home |
| `/tmp` | rw | node-local scratch, discarded when the job ends |

The host `$HOME` is never mounted and only `/etc/localtime` and `/etc/hosts` are system binds, so
the blast radius is exactly the table above. That is what makes it reasonable to run with
permission prompts bypassed: `bin/claude-shellrc` wraps `claude` and `codex` so the bare commands
skip them. A bound directory's *parents* exist inside only as empty mount points, so listing
`/cluster/project` shows just the pieces that were bound.

### Terminal only, without steering

Drop `--remote-control` and the session stays entirely in your terminal — no claude.ai, no phone.
Everything else is the same, and you start the agent with plain `claude` instead of `claude-rc`:

```bash
bin/euler-agent-run --agent claude --project mywork --interactive \
    --extra-bind      /path/to/writable/dir \
    --extra-read-bind /path/to/readonly/data
# inside the container:
cd /path/to/writable/dir
claude
```

The tradeoffs: `/home` is a throwaway copy, so conversation transcripts are discarded when you
exit, and you cannot pick the session up from elsewhere. In exchange `--project` is optional and
the model and effort flags apply as normal.

### Other ways to run a steerable session

**Fire-and-forget via SLURM.** No node to hold, no tmux — SLURM allocates and starts the session:

```bash
euler-agent-submit --agent claude --remote-control --project mywork --time 8:00:00
```

A `claude.ai/code?environment=...` URL appears in `logs/slurm-<jobid>.out`. You cannot intervene
on the node, and the session ends when `--time` runs out.

**Auto-start on a node you hold.** Steps 1–3 as above, then drop `--interactive` so the session
starts immediately instead of giving you a shell:

```bash
module load eth_proxy
cd /path/to/euler_agents
bin/euler-agent-run --remote-control --agent claude --project mywork --gpu
```

This runs in the foreground, answers the enable prompt itself, and prints the
`claude.ai/code?environment=...` URL. Use it when you want the node foothold but no shell — you
give up running commands inside the container alongside the agent.

---

## Use case 2 — Submit a task and wait

You specify the task up front; SLURM runs it unattended on a compute node and the agent writes
its own run summary when it finishes.

### Submit a job

```bash
# One-off task (fresh timestamped workspace each run)
euler-agent-submit --agent claude --task "Add type annotations to all functions in src/"

# Named project — workspace persists and is reused across jobs
euler-agent-submit --agent claude --project myanalysis --task "Clone the repo and explore the data"
euler-agent-submit --agent claude --project myanalysis --task "Now write a summary report"

# Clone a repo into the workspace first
euler-agent-submit --agent claude --project myanalysis \
    --repo https://github.com/org/myrepo \
    --task "Write unit tests for the data loading module"

# Read the task from a file, or from config/task.json when no flag is given
euler-agent-submit --agent claude --task-file tasks/myjob.md
euler-agent-submit --agent claude

# Mount extra directories, exactly as in use case 1 (same path inside and outside)
euler-agent-submit --agent claude --project myanalysis \
    --extra-read-bind /path/to/readonly/data \
    --task "Summarise the files in /path/to/readonly/data"

# Override the job time limit
euler-agent-submit --agent claude --task "..." --time 8:00:00
```

### Read the results

```bash
squeue -u $USER                                  # check it's running
tail -f <logs_dir>/slurm-<jobid>.out             # follow it
cat <workspace_dir>/myanalysis/REPORT.md         # agent's own run summary
```

`REPORT.md` gets one entry appended per run:

```
## Run 2026-04-21T12:00:00Z  (job=12345  model=claude-sonnet-4-6  exit=0  cost=$1.2340)
```

On a subscription the `cost=` figure is **notional** — computed from token usage at list prices,
not money charged. Your real limit is the plan's rate limits, which the harness does not track,
so an unattended job can quietly consume quota. For real per-run accounting see
[using a token or API key instead](#using-a-token-or-api-key-instead).

### Job size, GPUs and presets

```bash
# Named size preset from config/presets.json
euler-agent-submit --agent claude --preset medium-gpu --project mygpuproject --task "..."

# GPU with an explicit type and VRAM filter
euler-agent-submit --agent claude --gpu \
    --gpu-type nvidia_a100_80gb_pcie --gpu-mem 80g \
    --project mygpuproject --task "Train the model in train.py, checkpoints to a checkpoints/ subdir of the workspace"

# CPU sizing
euler-agent-submit --agent claude --cpus 4 --mem-per-cpu 8G --task "..."
```

`--gpu` sets `--gpus=<type>:1`, `--tmp=50G` and a 4-hour default time limit, and auto-selects a
partition from the requested time. **Always pair `--gpu-type` with `--gpu-mem`** — on Euler the
type name alone does not enforce which card you get. Types, VRAM values and partition families
are tabulated in [GPUs, partitions and Slurm accounts](#gpus-partitions-and-slurm-accounts).

### Email notifications

Only submitted jobs are notified — an interactive session (use case 1) has nothing to report on.
Disabled by default; opt in via `config/settings.local.json`:

```json
{
  "notifications": {
    "email": {
      "enabled": true,
      "address": "you@ethz.ch",
      "on_failure": true,
      "on_success": false
    }
  }
}
```

`on_failure` notifies on a non-zero exit. `on_success` notifies on clean completion — useful for
long jobs, noisy if you run many in parallel. Failure emails include the tail of the error log
and the `REPORT.md` summary; success emails include the summary and the cost.

Toggle success notifications for a single run without editing config:

```bash
euler-agent-submit --agent claude --task "..." --notify-success      # on for this run
euler-agent-submit --agent claude --task "..." --no-notify-success   # off for this run
```

---

## Additional features

These apply to both use cases unless noted.

### Named projects and persistent workspaces

The workspace is mounted at its host path, `<workspace_dir>/<project>`, and is the agent's
starting directory. Without `--project`, each run gets a fresh timestamped
directory. With `--project NAME`, every run for that project shares
`<workspace_dir>/NAME` — useful for multi-step work where later runs build on earlier results.
`--remote-control` requires it.

> Do not run two jobs with the same `--project` in parallel — agents writing to the same
> workspace will conflict. Run them sequentially.

### Model, effort and budget

| Flag | Controls | Default |
|---|---|---|
| `--model` | Model — haiku ≪ sonnet ≪ opus in cost | `claude-opus-4-8` |
| `--effort` | Thinking depth: `low / medium / high / xhigh / max` | Claude default |
| `--max-budget-usd` | Hard cap; the agent stops with `error_max_budget_usd` when hit | `10` |

Priority order: CLI flag > `config/task.json` > `config/settings.json`. To change the defaults
for every run, edit the `"claude"` block in `config/settings.local.json`.

On a subscription the budget is enforced against the notional cost above. It still bounds token
spend, which is a proxy for quota use, even though no money is charged. None of these three
apply to `--remote-control`, where the model is chosen per session in the app.

### Conda, pixi and caches — sharing the host's environments, sparing the home quota

Four optional settings bind the host's tool directories into the container at their own paths:

| Setting | Bound | Effect inside the container |
|---|---|---|
| `conda_envs_dir` | **ro** | your existing conda envs are visible and activatable; installs into them fail (bind one rw with `--extra-bind` if you want that) |
| `conda_pkgs_dir` | rw | conda/mamba reuse the host package cache instead of re-downloading into `/tmp` |
| `pixi_home` | rw | the host's `pixi` binary is on `PATH`, and its `config.toml` there (cache root, `detached-environments`) applies, so `pixi install` in a bound repo puts the env where it goes on the host |
| `cache_dir` | rw | `XDG_CACHE_HOME` (pip, uv, torch, Hugging Face) and `CUDA_CACHE_PATH` point here |

`CONDA_ENVS_DIRS` is `<workspace>/conda_envs:<conda_envs_dir>:/opt/conda/envs`: new environments
land in the project workspace, at a path that exists on the host, so an env built by the agent
activates on the host (and vice versa). Because every path is identical, shebangs and prefixes
baked into an env are correct on both sides.

Nothing accumulates under `~`: the host home is never mounted, `~` inside is the per-job agent
home, and the caches above go to project storage. Set the four values in
`config/settings.local.json` to match your host setup (they mirror `~/.condarc` and `$PIXI_HOME`).

```bash
euler-agent-submit --agent claude --project myproject \
    --task "Create a conda environment 'myenv' with python=3.11 and numpy, then verify it."
```

To inspect one by hand, on the host or in an interactive container, activate it by path:

```bash
conda activate <workspace_dir>/myproject/conda_envs/myenv
```

`uv` is also in the image, at `/opt/conda/bin/uv`.

### GPU access inside the container

`--gpu` on `euler-agent-run` passes `--nv` to Singularity, which is what exposes the NVIDIA
driver and devices to the agent. It works on both paths. In use case 2 it *also* makes
`euler-agent-submit` request a GPU node; in use case 1 the node already has the GPU from your
own allocation, and `--gpu` only affects the container.

### Git: the agent commits, you push

The container holds **no git credentials**, by design. With permission prompts off and outbound
network open, a token in the container could be exfiltrated by prompt injection in a cloned
repo or a data file, and a single wrong `git push --force` on the wrong repo has no undo. So:

- **Inside** the agent can `git clone` public repos, and `git commit` freely in any read-write
  bind. Commits are attributed to `git_user_name` / `git_user_email` from settings (default
  `euler-agent`, override in `config/settings.local.json` if you want your own identity) and
  carry a `Co-Authored-By` trailer naming the agent and model, added by
  `config/git-hooks/commit-msg`:

  ```
  Co-Authored-By: Claude (claude-opus-4-8) <noreply@anthropic.com>
  ```

- **Outside**, when the run is done, you review and push from the host with your own
  credentials:

  ```bash
  cd /path/to/writable/dir        # the same path the agent worked in
  git log --oneline origin/main..  # what the agent committed
  git push
  ```

For a **private repo**, clone it on the host first (into the workspace or anywhere you then pass
with `--extra-bind`); `--repo URL` inside the container works for public URLs only. Both paths,
headless and interactive, get the same identity and hook via `bin/container-env.sh`.

---

## Reference

### What the sandbox does and does not protect

The agent runs inside a Singularity container with `--cleanenv --containall`:

| | Detail |
|---|---|
| Host filesystem | No access — only the explicitly bound directories are visible, each at its host path |
| Home directory | Never mounted; the container gets its own `/home`, so nothing lands under your quota |
| Harness repo | Mounted read-only at its own path — the agent cannot modify the scripts that launched it |
| Read-only mounts | `--extra-read-bind`, `--ref` and the host conda envs are enforced by the kernel, not by the agent's cooperation |
| Git | No token in the container; the agent can only commit locally |
| Parallel jobs | Each job gets a private tmpdir; jobs don't interfere with each other |
| Privilege | Runs as your own UID — no root, no escalation possible |

What it does **not** protect against:

- **Unrestricted execution.** All confirmation prompts are disabled — the agent runs arbitrary
  code inside the container without approval.
- **Mutations to anything mounted read-write.** Full write access to the workspace, every
  `--extra-bind` target, the conda package cache and the pixi home; it can delete prior
  results. No undo. Mount read-only when in doubt.
- **Outbound network.** The container has internet access and can call external services.
- **Credential exposure.** The Claude login (or an injected API key / token, if you chose
  `--auth apikey|subscription`) is inside the container and could be exfiltrated via prompt
  injection in a cloned repo or a data file. No other credential is present.
- **Quota overruns.** On a subscription the harness cannot see your real rate-limit consumption.

Treat anything you pass to the agent the way you would treat code you are about to `bash -c` on
a compute node.

### Configuration files

| File | Tracked | Holds |
|---|---|---|
| `config/settings.json` | yes | committed defaults: image path, workspace dirs, host tool dirs (`conda_envs_dir`, `conda_pkgs_dir`, `pixi_home`, `cache_dir`), git identity, SLURM sizes, per-agent model/budget/auth |
| `config/settings.local.json` | no | your overrides; merged over `settings.json` **shallowly** (a top-level key replaces the whole block) |
| `config/secrets.env` | no | template for credentials |
| `config/secrets.local.env` | no | real credentials: `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY` (only needed for `--auth subscription|apikey`) |
| `config/task.json` | yes | default task plus model/effort/budget/repo/project, used when no `--task`/`--task-file` is given |
| `config/presets.json` | yes | named SLURM size presets for `euler-agent-submit --preset` |
| `config/agent-CLAUDE.md.template` | yes | environment description to copy into a bind as the agent's `CLAUDE.md` |

### Telling the agent about its environment

The agent does not know by itself that it is in a container on a cluster. The things that
surprise it: `~` is `/home` and not your host home, there are no SLURM binaries so it cannot
submit jobs, and the filesystem contains only what you bound. Three ways to tell it, from
least to most effort:

**1. Start the session with the generated briefing (interactive).** Every launch writes
`/tmp/agent-briefing.md` inside the container. It contains a short generic explanation of the
environment (from `config/agent-briefing.md`) followed by a table of this run's actual mounts and
their modes. Hand it to the agent as the first message:

```bash
claude "$(cat /tmp/agent-briefing.md)"
```

The container shell's banner reminds you of this command.

**2. Paste `config/agent-briefing.md` by hand.** Same text as option 1 without the mount table.
Useful when you are already inside a session.

**3. Put a `CLAUDE.md` into the repository the agent works in (permanent).** Claude Code
loads `CLAUDE.md` automatically from its working directory and that directory's parents, so a
file committed to the repo is picked up in every session started there, without pasting
anything. `config/agent-CLAUDE.md.template` is a starting point for such a file: the same
explanation as the briefing, plus a mount table you fill in once for that repo. Copy it and edit
the table:

```bash
cp config/agent-CLAUDE.md.template /cluster/home/<user>/src/myrepo/CLAUDE.md
```

Placing it in this `euler_agents` repo would not work: it is mounted read-only and is not a
parent of the agent's working directory.

Independently of these, your own global `~/.claude/CLAUDE.md` is loaded in every run: the
launcher copies it into the agent home at launch.

### GPUs, partitions and Slurm accounts

| GPU | `--gpu-type` | `--gpu-mem` | Partition family |
|---|---|---|---|
| A100 40 GB | `nvidia_a100-pcie-40gb` | `40g` | `gpupr.*` |
| A100 80 GB | `nvidia_a100_80gb_pcie` | `80g` | `gpupr.*` |
| RTX Pro 6000 (96 GB) | `nvidia_rtx_pro_6000` | `96g` | `cuda13pr.*` |
| RTX 4090 (24 GB) | `nvidia_geforce_rtx_4090` | `24g` | `gpupr.*` |
| RTX 3090 (24 GB) | `nvidia_geforce_rtx_3090` | `24g` | `gpupr.*` |

On Euler, `--gpu-type` alone does **not** enforce which GPU you get — the scheduler ignores the
type name and assigns any available card. Always pair it with `--gpu-mem SIZE` to filter by VRAM.
Note the 40 GB A100 GRES name uses hyphens (`a100-pcie-40gb`) and the 80 GB uses underscores
(`a100_80gb_pcie`) — an Euler inconsistency.

Partition suffixes cap wall time: `.4h` (4 h), `.24h` (2 days), `.120h` (5 days). Run
`sinfo -o "%P %l %G"` to list partitions, limits and their GPUs.

**Slurm account.** If GPU jobs queue forever, check which account they use — the default may
have a much smaller GPU share. On the Beltrao setup the system default is `es_beltrao` (4 GPUs),
not `es_biol` (61 GPUs).

```bash
my_share_info                                    # your shares
mkdir -p ~/.slurm && echo "account=es_biol" > ~/.slurm/defaults   # change the default
squeue -j <jobid> -o "%.18i %.30a"               # which account a job actually used
```

### Rebuilding the image

Rebuild on a login node when you want newer agent CLIs — both are pinned to `@latest` in the
definition, so a rebuild is how new model support arrives. Build to a **dated filename** and
repoint `image_path`, so the previous image stays as an instant rollback:

```bash
module load eth_proxy
export APPTAINER_TMPDIR="${TMPDIR:-/tmp}/apptainer_tmp"; mkdir -p "$APPTAINER_TMPDIR"
singularity build --fakeroot \
    /cluster/project/<group>/<user>/images/euler-agents-YYYYMMDD.sif \
    images/euler-agents.def
```

`images/README.md` has the full procedure, the smoke test, and a log of past rebuilds and why.

### How the scripts fit together

| Script | Runs where | Role |
|---|---|---|
| `bin/euler-agent-submit` | login node | writes and submits the SLURM job, or `srun --pty` for an interactive one; forwards everything else to `euler-agent-run` |
| `slurm/run-agent.sh` | compute node | thin SLURM wrapper that calls `euler-agent-run` |
| `bin/euler-agent-run` | compute or login node | resolves config, sets up the workspace, tmpdir and home, then starts Singularity. This is the only script that launches a container, and it needs no SLURM |
| `bin/container-env.sh` | inside container | sourced by both entrypoints: `HOME`/`PATH`, conda and cache dirs, git identity and hook — so the two paths cannot drift |
| `bin/inner.sh` | inside container | the non-interactive entrypoint: runs the task headless or starts Remote Control, then parses cost and writes `REPORT.md` |
| `bin/claude-shellrc` | inside container | the interactive entrypoint's rcfile: wraps `claude`/`codex` to skip permission prompts and adds `claude-rc` |
| `bin/notify.sh` | compute node | sends the completion email after a submitted run |

The `--interactive` and headless paths diverge at the end of `euler-agent-run`: interactive
starts `bash --rcfile bin/claude-shellrc`, headless starts `bin/inner.sh` (both addressed through
the repo's host path, which is where it is bound). What `inner.sh` adds on top of the shared
setup — cost reporting, `REPORT.md`, notifications — does not happen in an interactive session.

### Using a token or API key instead

`--auth login` (Setup step 4) is the default and is all most people need. Two alternatives exist.
All three are mutually exclusive: whichever you pick, the others are withheld from the container.

**A long-lived subscription token** (`--auth subscription`). Useful if you would rather not have a
refreshable login copied into every run's home — the token is static and injected as an env var
instead. Generate it on a login node:

```bash
module load eth_proxy
claude setup-token            # prints a token, sk-ant-oat...
echo "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-..." >> config/secrets.local.env
chmod 600 config/secrets.local.env
```

Requires a Claude subscription (Team or Max); it errors out if your plan cannot issue one.

**An API key** (`--auth apikey`) for pay-per-use. The tradeoff: you pay per token, but get real
per-run cost accounting and a budget cap that is a genuine dollar limit.

```bash
echo "ANTHROPIC_API_KEY=sk-ant-..." >> config/secrets.local.env
chmod 600 config/secrets.local.env
euler-agent-submit --agent claude --auth apikey --max-budget-usd 3 --task "..."
```

With an API key, `cost=` in `REPORT.md` is money actually spent. On either subscription mode it is
notional — computed from token usage at list prices — and your real limit is the plan's rate
limits, which the harness does not track.

**Neither alternative works with Remote Control**, which accepts only the stored claude.ai login.
Set a default with `"claude": { "auth": "login" | "subscription" | "apikey" }` in
`config/settings.local.json`, or pass `--auth` per run. To check what a run used, look at the
`Auth:` line in the log header:

```
Auth:      Claude subscription (stored claude.ai login)
Auth:      Claude subscription (long-lived OAuth token)
Auth:      Anthropic API key
```

---

## Codex (legacy)

Codex (`--agent codex`) still works for use case 2 and for a plain `--interactive` container
shell. It predates the Claude support and is no longer the primary path — Remote Control and
steering a session are
Claude-only.

| | Codex | Claude |
|---|---|---|
| Auth | browser OAuth → `home-codex/` | subscription token or API key |
| Default model | `gpt-5.4` | `claude-opus-4-8` |
| Cost reporting | not implemented | `REPORT.md` (real with an API key, notional on a subscription) |
| Budget cap | none | `--max-budget-usd` |

### Authenticating Codex

Authentication must happen inside the container so tokens are written to `home-codex/`, which is
mounted as `$HOME` in every run. Once, on a login node:

```bash
cd ~/src/euler_agents
module load eth_proxy
singularity shell --cleanenv --containall \
    --home "$(pwd)/home-codex:/home" \
    --bind /tmp:/tmp \
    /cluster/project/beltrao/jbuhmann/agentic_ai/images/euler-agents.sif
```

Inside the container, complete the browser OAuth flow:

```bash
export HOME=/home
codex login --device-auth
ls ~/.codex/   # should show auth files
exit
```

Then submit as usual with `--agent codex`. Note that Codex has no spending cap of any kind.
