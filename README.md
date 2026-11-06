# euler_agents

## In a nutshell

Run Claude Code on SLURM compute nodes. This fork is set up for UNIL's **Curnagl**; the ETH
Euler setup it comes from is kept as a second [cluster profile](#cluster-profiles). The agent runs
inside a Singularity container — the
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
bin/hpc-agent-run --agent claude --project mywork --remote-control --interactive \
    --extra-bind      /path/to/writable/dir \
    --extra-read-bind /path/to/readonly/data
# then inside the container:   cd /path/to/writable/dir && claude-rc
```

**2. [Submit a task and wait](#use-case-2--submit-a-task-and-wait)** — you write the task up
front, SLURM runs it unattended, and you read the output when it finishes. Best when the work is
well defined.

```bash
hpc-agent-submit --agent claude --project my-analysis \
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
git clone https://github.com/alpae/euler_agents.git euler_agents
cd euler_agents
make install   # symlinks CLIs to ~/.local/bin
```

> The commands used to be called `euler-agent-run` / `euler-agent-submit`. After pulling the
> rename, run `make install` again: it links the new `hpc-agent-*` names and removes the old links.

Add `~/.local/bin` to your PATH if it isn't already (add to `~/.bashrc`):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Create `config/settings.local.json` with your own paths (gitignored, merges over
`settings.json`). `"site"` picks the cluster profile and defaults to `curnagl`:

```json
{
  "site":          "curnagl",
  "workspace_dir": "/scratch/<username>/agentic_ai/workspaces",
  "logs_dir":      "/scratch/<username>/agentic_ai/logs",
  "image_path":    "/work/FAC/<faculty>/<department>/<pi>/<project>/agentic_ai/images/hpc-agents-YYYYMMDD.sif"
}
```

```bash
mkdir -p /scratch/$USER/agentic_ai/workspaces /scratch/$USER/agentic_ai/logs
```

Any path works for `workspace_dir` as long as it is the same on every node and survives
between jobs: Claude files sessions and memory under the absolute working directory, so a
path that changes per job (node-local `$TMPDIR`) loses them. A shared scratch is fine, but
check its purge policy and keep code in git — or put the workspace under `/work`.

> The merge is shallow: a top-level key in `settings.local.json` replaces the whole block from
> `settings.json`. If you override part of `"slurm"` or `"claude"`, restate every key in it.

### 3. Singularity image

Build one on a Curnagl login node and point `image_path` at it — see
[rebuilding the image](#rebuilding-the-image). (On Euler, a pre-built image is at
`/cluster/project/beltrao/jbuhmann/agentic_ai/images/euler-agents-20261001.sif`.)

### 4. Log in to your claude.ai account

One login covers everything: running the agent, and steering it from the browser or mobile app.
Run this on a **login node** — it needs a terminal and network access:

```bash
cd ~/src/euler_agents
bin/hpc-agent-run --claude-login
```

Pick your **claude.ai account**, not an API key. This runs `claude auth login` inside the
container with `home-claude/` mounted writable, so the credential is stored in
`home-claude/.claude/.credentials.json`. Every run mounts that same directory as the agent's home,
so the credential refreshes itself in place and stays valid as long as you keep using it.

This is the default (`--auth login`). Two alternatives exist if you need them: a long-lived
`claude setup-token`, or pay-per-use with an API key — both in
[using a token or API key instead](#using-a-token-or-api-key-instead).

> Steering a session (Remote Control) accepts **only** this credential; the other two are
> rejected. If it later fails with a 401, the login was revoked — repeat this step.

### 5. Smoke test

Check the image, the mounts and your credential in one go, on a login node:

```bash
cd ~/src/euler_agents
bin/hpc-agent-run --agent claude --project harness-test --interactive
```

Inside the container you should land at a `(hpc-agents) <workspace_dir>/<project> $` prompt. Then:

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
analysis. Curnagl caps every job at 3 days:

```bash
sbatch -p cpu --time=1-00:00:00 \
    --cpus-per-task=16 --mem-per-cpu=8G \
    --job-name=agent-node --wrap="sleep infinity"
```

*With a GPU*, when the agent needs to train or run inference:

```bash
sbatch -p gpu --gres=gpu:1 --time=1-00:00:00 \
    --cpus-per-task=4 --mem-per-cpu=8G \
    --job-name=agent-node --wrap="sleep infinity"
```

On Euler the partition and GPU request look different — see
[Euler: GPUs, partitions and Slurm accounts](#euler-gpus-partitions-and-slurm-accounts).

An idle GPU reservation still holds the card, so prefer the CPU node unless the agent needs one.

**2. Find the node and SSH in** (once the job shows `R` / RUNNING):

```bash
squeue --me                 # note JOBID and NODELIST
ssh <nodename>              # where the cluster allows SSH to nodes you hold an allocation on
# fallback if SSH to the node is blocked:  srun --jobid=<jobid> --pty bash
```

**3. Start tmux on the node** — not on a login node, where long-lived processes get reaped:

```bash
tmux new -s agent
```

**4. Start the container with the directories you want mounted.** Use `hpc-agent-run`, *not*
`submit` — you already hold the node. It loads the site's modules itself (`singularityce` on
Curnagl, `eth_proxy` on Euler), so there is no `module load` step:

```bash
cd /path/to/euler_agents
bin/hpc-agent-run --agent claude --project mywork --remote-control --interactive \
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
and `tmux attach -t agent`. Find the session by name (`hpc-rc-<project>-<jobid>`) in the app.

`claude-rc` is a helper from `bin/claude-shellrc`; it runs `claude remote-control` with a session
name and `--permission-mode bypassPermissions`. What `--remote-control` changes:

- `--project` becomes **required**; it names the session (`hpc-rc-<project>-<jobid>`).
- Workspace trust is pre-accepted for the workspace and every bind, because
  `claude remote-control` prompts for it and has no bypass flag.
- It accepts **only** the stored claude.ai login from Setup step 4 — a `setup-token` or API key
  is rejected. `--model`, `--effort`, `--max-budget-usd` and `--auth` are ignored; you pick the
  model per session in the app.

The session dies when the SLURM job ends, so size the allocation in step 1 accordingly.

**If the login was revoked or you switched accounts**, `claude-rc` fails with a 401. Re-run
`bin/hpc-agent-run --claude-login` (delete `home-claude/.claude/.credentials.json` first if it
refuses because a login already exists). All containers share that one home, so the new login is
live for every project at once; a container that is already running needs `claude auth login`
inside instead.

### Mounting extra directories

Two flags, both repeatable, so any number of directories can be added in either mode:

| Flag | Mode | Meaning |
|---|---|---|
| `--extra-bind SRC` | read-write | the agent can read and write here |
| `--extra-read-bind SRC` | read-only | the agent can read but not modify; an explicit `:rw` is rejected rather than silently downgraded |

A repository can carry its own list instead, so you stop retyping it: put a file such as
`hpc-agents.binds` in the repo (start from `config/binds.example`) and pass it with
`--binds-file`, in either use case:

```
# hpc-agents.binds — one SRC[:DEST][:ro|rw] per line, mode defaults to ro
.:rw                                              # this repo, read-write
/work/<project_dir>/mydata:ro                     # input data
```

```bash
bin/hpc-agent-run --agent claude --project mywork --interactive \
    --binds-file ~/src/myrepo/hpc-agents.binds
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
| `/home` | rw | the agent home `home-claude/`: login, settings, transcripts. One persistent directory shared by every container. **Not** your home |
| `/tmp` | rw | node-local scratch, discarded when the job ends |

The host `$HOME` is never mounted and only `/etc/localtime` and `/etc/hosts` are system binds, so
the blast radius is exactly the table above. That is what makes it reasonable to run with
permission prompts bypassed: `bin/claude-shellrc` wraps `claude` and `codex` so the bare commands
skip them. A bound directory's *parents* exist inside only as empty mount points, so listing
`/work` shows just the pieces that were bound.

### Terminal only, without steering

Drop `--remote-control` and the session stays entirely in your terminal — no claude.ai, no phone.
Everything else is the same, and you start the agent with plain `claude` instead of `claude-rc`:

```bash
bin/hpc-agent-run --agent claude --project mywork --interactive \
    --extra-bind      /path/to/writable/dir \
    --extra-read-bind /path/to/readonly/data
# inside the container:
cd /path/to/writable/dir
claude
```

The tradeoff: you cannot pick the session up from elsewhere. In exchange `--project` is optional
and the model and effort flags apply as normal. Transcripts persist either way (see
[Sessions and `--resume`](#sessions-and---resume)).

### Other ways to run a steerable session

**Fire-and-forget via SLURM.** No node to hold, no tmux — SLURM allocates and starts the session:

```bash
hpc-agent-submit --agent claude --remote-control --project mywork --time 8:00:00 \
    --workspace       /scratch/$USER/agentic_ai/mywork \
    --extra-read-bind /path/to/readonly/data
```

A `claude.ai/code?environment=...` URL appears in `logs/slurm-<jobid>.out`. You cannot intervene
on the node, and the session ends when `--time` runs out (at most 3 days on Curnagl).
`--workspace` puts the workspace — where the session starts, read-write — at that directory
instead of `<workspace_dir>/<project>`, e.g. a repo you cloned on the host.

**Continue a session after the job ended** (e.g. it hit `--time`): submit again with the same
`--project` and workspace, plus one of

| Flag | Reattaches to | Passed as |
|---|---|---|
| `--rc-continue` | the Remote Control session last recorded for the workspace — only within roughly 4 hours of it | `claude remote-control --continue` |
| `--rc-session-id ID` | that session | `claude remote-control --session-id ID` |

```bash
hpc-agent-submit --agent claude --remote-control --rc-continue --project mywork --time 8:00:00 \
    --workspace /scratch/$USER/agentic_ai/mywork --extra-read-bind /path/to/readonly/data
```

The record should be in the shared agent home, so a new job can find it. Past the 4-hour window there
is nothing to reattach to: start a new session and point it at the previous results. The same
flags work with `--interactive`, where `claude-rc` then reattaches.

**Auto-start on a node you hold.** Steps 1–3 as above, then drop `--interactive` so the session
starts immediately instead of giving you a shell:

```bash
cd /path/to/euler_agents
bin/hpc-agent-run --remote-control --agent claude --project mywork --gpu
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
hpc-agent-submit --agent claude --task "Add type annotations to all functions in src/"

# Named project — workspace persists and is reused across jobs
hpc-agent-submit --agent claude --project myanalysis --task "Clone the repo and explore the data"
hpc-agent-submit --agent claude --project myanalysis --task "Now write a summary report"

# Clone a repo into the workspace first
hpc-agent-submit --agent claude --project myanalysis \
    --repo https://github.com/org/myrepo \
    --task "Write unit tests for the data loading module"

# Read the task from a file, or from config/task.json when no flag is given
hpc-agent-submit --agent claude --task-file tasks/myjob.md
hpc-agent-submit --agent claude

# Mount extra directories, exactly as in use case 1 (same path inside and outside)
hpc-agent-submit --agent claude --project myanalysis \
    --extra-read-bind /path/to/readonly/data \
    --task "Summarise the files in /path/to/readonly/data"

# Override the job time limit
hpc-agent-submit --agent claude --task "..." --time 8:00:00
```

### Read the results

```bash
squeue -u $USER                                  # check it's running
tail -f <logs_dir>/slurm-<jobid>.out             # follow it
cat <workspace_dir>/myanalysis/REPORT.md         # agent's own run summary
```

`REPORT.md` gets one entry appended per run:

```
## Run 2026-04-21T12:00:00Z  (job=12345  model=opus  exit=0  cost=$1.2340)
```

On a subscription the `cost=` figure is **notional** — computed from token usage at list prices,
not money charged. Your real limit is the plan's rate limits, which the harness does not track,
so an unattended job can quietly consume quota. For real per-run accounting see
[using a token or API key instead](#using-a-token-or-api-key-instead).

### Job size, GPUs and presets

```bash
# Named size preset from config/presets.json
hpc-agent-submit --agent claude --preset medium-gpu --project mygpuproject --task "..."

# Any GPU on the site's GPU partition
hpc-agent-submit --agent claude --gpu \
    --project mygpuproject --task "Train the model in train.py, checkpoints to a checkpoints/ subdir of the workspace"

# Euler only: explicit type and VRAM filter
hpc-agent-submit --agent claude --gpu --gpu-type nvidia_a100_80gb_pcie --gpu-mem 80g --task "..."

# CPU sizing
hpc-agent-submit --agent claude --cpus 4 --mem-per-cpu 8G --task "..."
```

`--gpu` requests one GPU in the site's form (`--gres=gpu:1` on Curnagl, `--gpus=<type>:1` on
Euler; `--gpu-type` sets the type) with a 4-hour
default time limit, on the site's GPU partition: `gpu` on Curnagl, a time-tiered `gpupr.*` on
Euler. Without `--gpu` the job goes to the site's CPU partition (`cpu` on Curnagl). A `--time`
above the site's limit (3 days on Curnagl) is refused before anything is submitted. On Euler,
**always pair `--gpu-type` with `--gpu-mem`** — see
[Euler: GPUs, partitions and Slurm accounts](#euler-gpus-partitions-and-slurm-accounts).

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
hpc-agent-submit --agent claude --task "..." --notify-success      # on for this run
hpc-agent-submit --agent claude --task "..." --no-notify-success   # off for this run
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

Names may be nested to group related workspaces: `--project shi/omicsMSA` uses
`<workspace_dir>/shi/omicsMSA`, creating the parent as needed. Each segment is limited to
letters, digits, `.`, `_` and `-`; the Remote Control session is then named
`hpc-rc-shi-omicsMSA-<jobid>`.

`--workspace DIR` (absolute, requires `--project`) uses DIR as the workspace instead of
`<workspace_dir>/<project>`, creating it if needed; `--project` then only names the session.
Use it to start the agent in a repo or results directory that lives elsewhere:

```bash
hpc-agent-submit --agent claude --remote-control --project mywork \
    --workspace ~/src/myrepo
```

> Do not run two jobs with the same `--project` in parallel — agents writing to the same
> workspace will conflict. Run them sequentially.

### The agent home: one directory, shared by every container

`/home` inside the container is `home-claude/` (or `home-codex/`), the same directory for every
launch in every mode. It holds the claude.ai login, the pre-accepted trust and onboarding flags,
and Claude's own state. It is deliberately **not** a per-job copy: claude.ai refresh tokens
rotate, so a copied credential dies the moment any other copy refreshes, and containers that
copied the login would keep logging each other out. One file refreshed in place is what your
laptop does with several Claude windows open, and Claude Code is built for that.

The directory lives in this repo by default. To keep it off your home quota, set
`agent_home_dir` in `config/settings.local.json` to a directory on project storage and move
`home-claude/` (and `home-codex/`) there once:

```bash
mkdir -p /work/<project_dir>/agentic_ai/agent-homes
mv home-claude home-codex /work/<project_dir>/agentic_ai/agent-homes/
```

Leftover `<workspace>/<project>/.claude-home` directories from the earlier per-project design
are unused now and can be deleted.

### Sessions and `--resume`

Claude Code keeps transcripts per working directory under `~/.claude/projects/`. Inside the
container `~` is the agent's own home, so on its own `claude --resume` would show none of your
host sessions. The launcher therefore mounts your host session directory for the workspace and for every **read-write**
bind into the agent home, at the same encoded path. Effects:

- `cd` into a bound repo inside the container and `claude --resume` lists the sessions you
  started there on the host, and vice versa.
- Sessions started inside persist in your host `~/.claude/projects/` (they count against your
  home quota, exactly as host sessions do).
- Only those directories' transcripts are visible to the agent; read-only binds and the rest of
  your `~/.claude` are not.
- The mounts sit in a `projects` folder private to each launch (`launches-claude/<launch>/`,
  next to `home-claude/`), so parallel containers cannot disturb each other's. A session started
  in a directory that is not shared lands there and is copied to your host `~/.claude/projects/`
  when the container exits; if the host already has a different file of that name, the launch
  folder is kept and the launcher prints its path.

Resuming across Claude Code versions (the image's vs. your host's) usually works but is not
guaranteed; rebuild the image if it misbehaves.

### Model, effort and budget

| Flag | Controls | Default |
|---|---|---|
| `--model` | Model: an alias (`opus`, `sonnet`, `haiku`; haiku ≪ sonnet ≪ opus in cost) or a full ID such as `claude-opus-5-5` | `opus` |
| `--effort` | Thinking depth: `low / medium / high / xhigh / max` | Claude default |
| `--max-budget-usd` | Hard cap; the agent stops with `error_max_budget_usd` when hit | `10` |

An alias resolves to the newest model of that family the image's Claude Code knows, so the
default moves forward when the image is rebuilt; pass a full ID to pin one.

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

Nothing accumulates under `~`: the host home is never mounted, `~` inside is the agent home
(`home-claude/`, or wherever `agent_home_dir` points), and the caches above go to project storage. Set the four values in
`config/settings.local.json` to match your host setup (they mirror `~/.condarc` and `$PIXI_HOME`).

```bash
hpc-agent-submit --agent claude --project myproject \
    --task "Create a conda environment 'myenv' with python=3.11 and numpy, then verify it."
```

To inspect one by hand, on the host or in an interactive container, activate it by path:

```bash
conda activate <workspace_dir>/myproject/conda_envs/myenv
```

`uv` is also in the image, at `/opt/conda/bin/uv`.

### GPU access inside the container

`--gpu` on `hpc-agent-run` passes `--nv` to Singularity, which is what exposes the NVIDIA
driver and devices to the agent. It works on both paths. In use case 2 it *also* makes
`hpc-agent-submit` request a GPU node; in use case 1 the node already has the GPU from your
own allocation, and `--gpu` only affects the container.

### Git: the agent commits, you push

The container holds **no git credentials**, by design. With permission prompts off and outbound
network open, a token in the container could be exfiltrated by prompt injection in a cloned
repo or a data file, and a single wrong `git push --force` on the wrong repo has no undo. So:

- **Inside** the agent can `git clone` public repos, and `git commit` freely in any read-write
  bind. Commits are attributed to `git_user_name` / `git_user_email` from settings (default
  `hpc-agent`, override in `config/settings.local.json` if you want your own identity) and
  carry one `Co-Authored-By` trailer naming the agent. Claude Code adds its own, with the
  model that actually ran; `config/git-hooks/commit-msg` adds one only when the agent did
  not (Codex, or Claude with its attribution turned off), naming the model only for headless
  runs, where `--model` decided it:

  ```
  Co-Authored-By: Codex (gpt-5.4) <noreply@openai.com>
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
| Parallel jobs | Each launch gets a private `/tmp`; all launches share the one agent home, as several Claude windows on a laptop do |
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

### Organisation policies

If your claude.ai account belongs to a Team or Enterprise organisation, its admins can push
**managed settings** that apply to every session logged in with that account, including the one
in the container. The harness cannot override them, and does not try. A policy that disables
bypass-permissions mode breaks the unattended modes: Claude asks for approval that nobody can
give, so tool calls such as `Write` or `Bash` are denied.

Symptoms:

- A headless job ends with exit code 3 and the log shows
  `WARNING: Claude was denied tool calls despite --dangerously-skip-permissions`. `REPORT.md`
  lists the denied tools. (`claude -p` itself exits 0 in this case. `inner.sh` checks
  `permission_denials` in its JSON output and marks the run failed.)
- A Remote Control session keeps asking for approval in the app.
- `/status` in an interactive container lists `Enterprise managed settings (remote)` under
  *Setting sources*. `/permissions` shows which rules come from the policy.

What to do:

- Ask your organisation's claude.ai admin to allow bypass-permissions mode for your account. The
  table above describes what the container does and does not protect, which helps make the case.
- Or log in to the container with an account that is not under that policy
  (`hpc-agent-run --claude-login`), if your organisation allows that for this work.
- Interactive sessions still work, as long as you approve each step yourself.

Don't recreate bypass mode by putting broad allow rules (all of `Bash`, `Write`, `Edit`) into the
agent home's settings. That gets around a decision your organisation made deliberately.

### Configuration files

| File | Tracked | Holds |
|---|---|---|
| `config/settings.json` | yes | committed defaults: image path, workspace dirs, host tool dirs (`conda_envs_dir`, `conda_pkgs_dir`, `pixi_home`, `cache_dir`), `agent_home_dir` (where `home-claude/` lives; null = this repo), git identity, SLURM sizes, per-agent model/budget/auth |
| `config/sites/<site>.json` | yes | cluster profile selected by `"site"`: modules to load, container command, CPU/GPU partitions, GPU request style, max wall time, mail domain, preset overrides. Tweak single keys with `"site_overrides"` in settings |
| `config/settings.local.json` | no | your overrides; merged over `settings.json` **shallowly** (a top-level key replaces the whole block) |
| `config/secrets.env` | no | template for credentials |
| `config/secrets.local.env` | no | real credentials: `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY` (only needed for `--auth subscription|apikey`) |
| `config/task.json` | yes | default task plus model/effort/budget/repo/project, used when no `--task`/`--task-file` is given |
| `config/presets.json` | yes | named SLURM size presets for `hpc-agent-submit --preset` |
| `config/agent-CLAUDE.md.template` | yes | template for a repository's `CLAUDE.md` with project notes (data, environments, conventions) |

### Telling the agent about its environment

The agent does not know by itself that it is in a container on a cluster. The things that
surprise it: `~` is `/home` and not your host home, there are no SLURM binaries so it cannot
submit jobs, and the filesystem contains only what you bound.

**Claude is told automatically.** Every launch writes `/tmp/agent-briefing.md` inside the
container: a short explanation of the environment (from `config/agent-briefing.md`) followed by
this run's actual mounts and their modes. The agent home's user-level `CLAUDE.md`
(`/home/.claude/CLAUDE.md`, rebuilt at every launch) imports it with `@/tmp/agent-briefing.md`,
so Claude loads it at the start of every session — interactive, headless and Remote Control —
without anything to paste. All containers share that one `CLAUDE.md`, but `/tmp` is private to
each launch, so each container reads its own mount table. To check, ask the agent which mounts
it has, or run `/memory` in an interactive session.

That file starts with a copy of your own global `~/.claude/CLAUDE.md`, so your personal
instructions apply inside the container too. Codex does not read it; paste the briefing there
by hand (`cat /tmp/agent-briefing.md`).

**Project knowledge goes in the repository's `CLAUDE.md`.** Where the data lives, which
environment to use, how results are organised: put that in a `CLAUDE.md` in the directory the
agent works in, and Claude loads it from there. `config/agent-CLAUDE.md.template` is a starting
point. Host sessions in that directory read the same file, so keep container-specific statements
out of it — the briefing covers those.

```bash
cp config/agent-CLAUDE.md.template ~/src/myrepo/CLAUDE.md
```

### Cluster profiles

Everything cluster-specific lives in `config/sites/<site>.json`, picked by `"site"` in the
settings (default `curnagl`):

| Key | Curnagl | Euler |
|---|---|---|
| `modules` | `["singularityce"]` | `["eth_proxy"]` (compute nodes need the proxy for internet) |
| `container_cmd` | `singularity` | `singularity` |
| `max_time` | `3-00:00:00` | none |
| `cpu_partition` / `gpu_partition` | `cpu` / `gpu` | none / chosen from `gpu_partitions_by_hours` |
| `gpu_request` | `--gres=gpu:{type}1` | `--gpus={type}1` (`{type}` = `TYPE:` or empty) |
| `default_gpu_type` | none (any GPU) | `a100` |
| `gpu_mem_gres` | false | true (`--gpu-mem` allowed) |

`hpc-agent-run` loads the modules on every launch — in a batch job, on a node you hold, and for
`--claude-login` — so none of the commands in this README need a `module load` first. For
another cluster, copy one of the files and set `"site"` to its name. To change a single key
without a new file, use `"site_overrides": { "modules": [] }` in `config/settings.local.json`.

### Euler: GPUs, partitions and Slurm accounts

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
module load singularityce        # Euler: module load eth_proxy
export APPTAINER_TMPDIR="${TMPDIR:-/tmp}/apptainer_tmp"; mkdir -p "$APPTAINER_TMPDIR"
singularity build --fakeroot \
    --build-arg CLAUDE_CODE_VERSION="$(claude --version | awk '{print $1}')" \
    /work/<project_dir>/agentic_ai/images/hpc-agents-YYYYMMDD.sif \
    images/hpc-agents.def
```

`images/README.md` has the full procedure, the smoke test, and a log of past rebuilds and why.

### How the scripts fit together

| Script | Runs where | Role |
|---|---|---|
| `bin/host-config.sh` | login or compute node | sourced by `submit` and `run`: merges the settings files and the site profile, loads the site's modules |
| `bin/hpc-agent-submit` | login node | writes and submits the SLURM job, or `srun --pty` for an interactive one; forwards everything else to `hpc-agent-run` |
| `slurm/run-agent.sh` | compute node | thin SLURM wrapper that calls `hpc-agent-run` |
| `bin/hpc-agent-run` | compute or login node | resolves config, sets up the workspace, tmpdir and home, then starts Singularity. This is the only script that launches a container, and it needs no SLURM |
| `bin/container-env.sh` | inside container | sourced by both entrypoints: `HOME`/`PATH`, conda and cache dirs, git identity and hook — so the two paths cannot drift |
| `bin/inner.sh` | inside container | the non-interactive entrypoint: runs the task headless or starts Remote Control, then parses cost and writes `REPORT.md` |
| `bin/claude-shellrc` | inside container | the interactive entrypoint's rcfile: wraps `claude`/`codex` to skip permission prompts and adds `claude-rc` |
| `bin/notify.sh` | compute node | sends the completion email after a submitted run |

The `--interactive` and headless paths diverge at the end of `hpc-agent-run`: interactive
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
hpc-agent-submit --agent claude --auth apikey --max-budget-usd 3 --task "..."
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
| Default model | `gpt-5.4` | `opus` |
| Cost reporting | not implemented | `REPORT.md` (real with an API key, notional on a subscription) |
| Budget cap | none | `--max-budget-usd` |

### Authenticating Codex

Authentication must happen inside the container so tokens are written to `home-codex/`, which is
mounted as `$HOME` in every run. Once, on a login node:

```bash
cd ~/src/euler_agents
module load singularityce        # Euler: module load eth_proxy
singularity shell --cleanenv --containall \
    --home "$(pwd)/home-codex:/home" \
    --bind /tmp:/tmp \
    <image_path>
```

Inside the container, complete the browser OAuth flow:

```bash
export HOME=/home
codex login --device-auth
ls ~/.codex/   # should show auth files
exit
```

Then submit as usual with `--agent codex`. Note that Codex has no spending cap of any kind.
