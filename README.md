# euler_agents

## In a nutshell

Run Codex or Claude Code as unattended SLURM batch jobs on Euler. Tasks run inside a Singularity container, which isolates the agent from the host filesystem — it can only access the workspace directory and a read-only copy of this repository.

**What is Singularity?** A container technology for HPC clusters (similar to Docker, but no root required). The agent's runtime — Codex or Claude Code, conda, all dependencies — is packaged into a single image file (`euler-agents.sif`). Each job runs inside that image, with no visibility into the rest of the cluster.

```bash
euler-agent-submit --agent claude \
    --repo https://github.com/your-org/your-repo \
    --project my-analysis \
    --task "Explore the CSV files in data/, fit a linear regression, and write findings to results/report.md."
```

```bash
squeue -u $USER                        # check it's running
cat /path/to/workspaces/my-analysis/results/report.md   # read the output
cat /path/to/workspaces/my-analysis/REPORT.md           # agent's own run summary + cost
```

- Tasks run unattended on a compute node — no keeping a terminal open, no babysitting
- The agent can clone repos, install conda packages, read and write files freely
- Named projects (`--project`) give the agent a persistent workspace across multiple jobs — useful for multi-step work where later tasks build on earlier results
- Claude jobs record actual cost in `REPORT.md` so you know what each run spent

## Sandbox and risks

The agent runs inside a Singularity container with `--cleanenv --containall`. What this means in practice:

| | Detail |
|---|---|
| Host filesystem | No access — only the explicitly bound directories are visible |
| Home directory | Not mounted; the container gets its own isolated `$HOME` |
| Harness repo | Mounted read-only (`/repo:ro`) — the agent cannot modify the scripts that launched it |
| Parallel jobs | Each job gets a private tmpdir; jobs don't interfere with each other |
| Privilege | Runs as your own UID — no root, no escalation possible |

What the sandbox does **not** protect against:

- **Unrestricted execution.** All confirmation prompts are disabled — the agent runs arbitrary code inside the container without approval.
- **Workspace mutations.** Full write access to `/workspace`; it can delete prior results. No undo.
- **Outbound network.** The container has internet access and can call external services.
- **API key exposure.** Keys are injected as env vars and could be exfiltrated via prompt injection in a cloned repo.
- **Cost overruns.** Codex has no spending cap. Set `--max-budget-usd` explicitly for Claude.

Treat anything you pass to the agent the way you would treat code you are about to `bash -c` on a compute node.

---

## Setup

### 1. Clone, configure, and install

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

Create `config/settings.local.json` with your own paths (gitignored, merges over `settings.json`):

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

### 2. Singularity image

A pre-built image is at `/cluster/project/beltrao/jbuhmann/agentic_ai/images/euler-agents.sif` — no action needed unless you are rebuilding it.

To rebuild (login node, maintainers only):

```bash
module load eth_proxy
singularity build --fakeroot \
    /cluster/project/beltrao/jbuhmann/agentic_ai/images/euler-agents.sif \
    images/euler-agents.def
```

### 3. Authenticate with Codex

Codex authentication must happen inside the container so tokens are written to `home-codex/`, which is mounted as `$HOME` in every job. Run **once** on the login node:

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

### 4. Smoke test

Verify the full workflow (SLURM → Singularity → Codex → workspace):

```bash
euler-agent-submit --agent codex \
    --project harness-test \
    --task "Write the string 'hello from SLURM' to /workspace/hello.txt."
```

Follow the job:

```bash
squeue -u $USER
tail -f /cluster/project/beltrao/<your-username>/logs/slurm-<jobid>.out
```

After it finishes, verify the output:

```bash
cat <workspace_dir>/harness-test/hello.txt
cat <workspace_dir>/harness-test/REPORT.md
```

---

## Usage

```bash
# One-off task (fresh timestamped workspace each run)
euler-agent-submit --agent codex --task "Add type annotations to all functions in src/"

# Named project — workspace persists and is reused across jobs
euler-agent-submit --agent codex --project myanalysis --task "Clone the repo and explore the data"
euler-agent-submit --agent codex --project myanalysis --task "Now write a summary report"

# Clone a repo into the workspace first
euler-agent-submit --agent codex --project myanalysis \
    --repo https://github.com/org/myrepo \
    --task "Write unit tests for the data loading module"

# Edit config/task.json and submit without extra flags
euler-agent-submit --agent codex

# Interactive shell on a compute node
euler-agent-submit --interactive --agent codex --project myanalysis

# Override job time limit
euler-agent-submit --agent codex --task "..." --time 8:00:00
```

The workspace is mounted as `/workspace` inside the container. Without `--project`, each run gets a fresh timestamped directory. With `--project`, all jobs for that project share the same directory — useful for multi-step work where later tasks build on earlier results.

> Do not run two jobs with the same `--project` in parallel — agents writing to the same workspace will conflict. Run them sequentially.

### Conda environments

Environments created by the agent persist in `<workspace>/conda_envs/` and are reusable across jobs in the same project.

```bash
# Create an environment
euler-agent-submit --agent codex --project myproject \
    --task "Create a conda environment 'myenv' with python=3.11 and numpy, then verify with a short script."

# Reuse it in a later job
euler-agent-submit --agent codex --project myproject \
    --task "Using the conda environment 'myenv', write a script that prints the numpy version."
```

To test an environment interactively:

```bash
euler-agent-submit --interactive --agent codex --project myproject
# inside the shell:
source /opt/conda/etc/profile.d/conda.sh && conda activate myenv
```

### GPU jobs

Pass `--gpu` to request a GPU node and enable NVIDIA GPU access inside the container:

```bash
# Any A100 (scheduler picks 40 or 80 GB — tends to give 40 GB when available)
euler-agent-submit --agent claude --gpu --project mygpuproject \
    --task "Train the model in train.py and save checkpoints to /workspace/checkpoints/"

# A100 40 GB explicitly
euler-agent-submit --agent claude --gpu \
    --gpu-type nvidia_a100-pcie-40gb --gpu-mem 40g \
    --project mygpuproject --task "..."

# A100 80 GB explicitly
euler-agent-submit --agent claude --gpu \
    --gpu-type nvidia_a100_80gb_pcie --gpu-mem 80g \
    --project mygpuproject --task "..."

# RTX Pro 6000 Blackwell (96 GB) — note: different partition family
euler-agent-submit --agent claude --gpu \
    --gpu-type nvidia_rtx_pro_6000 --gpu-mem 96g --partition cuda13pr.4h \
    --project mygpuproject --task "..."

# Longer job — partition is auto-selected from time (6h → gpupr.24h)
euler-agent-submit --agent claude --gpu --time 6:00:00 --project mygpuproject \
    --task "Run the full training pipeline"

# Interactive GPU shell
euler-agent-submit --interactive --gpu --agent claude --project mygpuproject
```

`--gpu` sets `--gpus=<type>:1`, `--tmp=50G`, and a 4-hour default time limit. The SLURM partition is auto-selected from the `gpupr.*` family based on the requested time (≤4h → `gpupr.4h`, ≤24h → `gpupr.24h`, longer → `gpupr.120h`). The RTX Pro 6000 is in the `cuda13pr.*` family instead — use `--partition cuda13pr.4h` explicitly for that GPU.

**Important:** on Euler, `--gpu-type` alone does not enforce which GPU you get — the scheduler ignores the type name and assigns any available GPU. Always pair it with `--gpu-mem SIZE` to filter by VRAM. Known GPU types and their `--gpu-mem` values:

| GPU | `--gpu-type` | `--gpu-mem` | Partition |
|---|---|---|---|
| A100 40 GB | `nvidia_a100-pcie-40gb` | `40g` | `gpupr.*` |
| A100 80 GB | `nvidia_a100_80gb_pcie` | `80g` | `gpupr.*` |
| RTX Pro 6000 (96 GB) | `nvidia_rtx_pro_6000` | `96g` | `cuda13pr.*` |
| RTX 4090 (24 GB) | `nvidia_geforce_rtx_4090` | `24g` | `gpupr.*` |
| RTX 3090 (24 GB) | `nvidia_geforce_rtx_3090` | `24g` | `gpupr.*` |

Note: the 40 GB A100 GRES name uses hyphens (`a100-pcie-40gb`), the 80 GB uses underscores (`a100_80gb_pcie`) — an Euler inconsistency.

### Default Slurm account and GPU availability

If GPU jobs queue for a long time or never start, check which account they are submitted under — the default account may have a much smaller GPU share than expected. On the Beltrao group setup, the system default is `es_beltrao` (4 GPUs), not `es_biol` (61 GPUs).

Check your current default:

```bash
my_share_info
```

Change the default to the larger share permanently:

```bash
mkdir -p ~/.slurm && echo "account=es_biol" > ~/.slurm/defaults
```

Verify which account a submitted job is actually using (use `%.30a` to avoid truncation):

```bash
squeue -j <jobid> -o "%.18i %.30a"
```

---

## Claude agent (optional)

Claude Code (`--agent claude`) is an alternative to Codex with the same interface.

| | Codex | Claude |
|---|---|---|
| Auth | Browser OAuth → `home-codex/` | API key, or Team/Max subscription login (`--auth`) |
| Default model | `gpt-5.4` | `claude-opus-4-8` |
| Cost reporting | not implemented | recorded in `REPORT.md` (API key only) |

### Setup

**1. Get an Anthropic API key** at [console.anthropic.com](https://console.anthropic.com).

**2. Make the key available to jobs** — write it to `config/secrets.env` (gitignored, auto-loaded by `euler-agent-run`):

```bash
echo "ANTHROPIC_API_KEY=sk-ant-..." > config/secrets.env
chmod 600 config/secrets.env
```

Alternatively, export it in your shell profile (`~/.bashrc`). The key is passed into the container via `--env` and never written to disk inside it.

**3. Smoke test** — verifies the full workflow including cost reporting:

```bash
euler-agent-submit --agent claude \
    --project harness-test \
    --model claude-haiku-4-5-20251001 \
    --max-budget-usd 0.10 \
    --task "Write the string 'hello from SLURM' to /workspace/hello.txt."
```

After the job finishes:

```bash
cat <workspace_dir>/harness-test/hello.txt
cat <workspace_dir>/harness-test/REPORT.md   # should include a cost= field
```

### Auth: API key vs subscription

By default Claude jobs use `ANTHROPIC_API_KEY` (pay-per-use). If you have a Claude Team or Max plan, `--auth subscription` runs jobs on your subscription instead — the key is withheld and Claude Code authenticates with a long-lived OAuth token (`CLAUDE_CODE_OAUTH_TOKEN`).

```bash
# API key (default)
euler-agent-submit --agent claude --auth apikey --task "..."

# subscription (Team/Max)
euler-agent-submit --agent claude --auth subscription --task "..."
```

To use `--auth subscription`, set the token up once.

**1. Generate the token.** On a machine with the `claude` CLI installed and network access (e.g. an Euler login node with `module load eth_proxy`), run:

```bash
claude setup-token
```

This starts a browser OAuth flow — it prints a URL; open it, sign in to your Claude account, and approve. The command then prints a long-lived token (`sk-ant-oat...`). Requires a Claude subscription (Team or Max); it errors out if your plan can't issue one.

**2. Store it** as a line in `config/secrets.local.env` (gitignored, auto-loaded by jobs):

```
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-...
```

**3. Use it** — per run, or make it the default in `config/settings.json` (`"claude": { "auth": "subscription" }`):

```bash
euler-agent-submit --agent claude --auth subscription \
    --project myproject --task "..."
```

**Cost reporting is notional in this mode.** `REPORT.md` still shows a `cost=$…` figure, but on a subscription you don't pay per token — it's a hypothetical cost Claude computes from token usage (tokens × list prices), not real spend. Your actual limit is the plan's rate limits, which the harness does not track, so an unattended job can silently consume your quota.

`--max-budget-usd` still works as a guardrail: Claude Code enforces it against that notional cost and stops with `error_max_budget_usd` when exceeded. It bounds token spend (a proxy for quota use), even though no dollars are actually charged.

To check which auth a job used, look at the `Auth:` line in the SLURM `.out` log header:

```
SLURM job <jobid> on <node>
Workspace: ...
Agent:     claude
Image:     ...
Auth:      Anthropic API key
```

`Auth: Anthropic API key` or `Auth: Claude subscription (long-lived OAuth token)` tells you which one was used.

### Controlling costs

| Flag | Controls | Default |
|---|---|---|
| `--max-budget-usd` | Hard USD cap — agent stops when hit | `10` |
| `--effort` | Thinking depth: `low / medium / high / xhigh / max` | Claude default |
| `--model` | Model — haiku ≪ sonnet ≪ opus in cost | `claude-opus-4-8` |

Priority order: CLI flag > `config/task.json` > `config/settings.json`.

```bash
euler-agent-submit --agent claude --max-budget-usd 3 --effort low --task "Quick exploration"
euler-agent-submit --agent claude --max-budget-usd 20 --effort high --task "Deep analysis"
```

To change defaults for all Claude jobs, edit `config/settings.json`:

```json
"claude": { "model": "claude-opus-4-8", "effort": null, "max_budget_usd": 10 }
```

After each run the actual cost is recorded in the workspace `REPORT.md`:

```
## Run 2026-04-21T12:00:00Z  (job=12345  model=claude-sonnet-4-6  exit=0  cost=$1.2340)
```

### Remote control (steerable sessions)

`--remote-control` starts a long-running Claude session on the compute node that you steer
from [claude.ai/code](https://claude.ai/code) or the mobile app — kick it off, close your
laptop, check in from your phone.

One-time login (Remote Control needs a full-scope claude.ai account — API keys and
`setup-token` are rejected). Creds persist in `home-claude/`:

```bash
bin/euler-agent-run --claude-login   # on a login node; pick your claude.ai account, not an API key
```

Then launch (`--project` required — transcripts persist in the project home and survive the job):

```bash
euler-agent-submit --agent claude --remote-control --project mywork --time 8:00:00
```

A `claude.ai/code?environment=...` URL appears in the log (`logs/slurm-<jobid>.out`); or find
the session by name (`euler-rc-<project>-<jobid>`) in the app.

Notes: live steering ends when the job ends (raise `--time`). `--model/--effort/--max-budget-usd/
--auth/--task` don't apply — it runs on your subscription, model chosen in the app. On Team/
Enterprise, an Owner may need to enable Remote Control in admin settings. Don't test via
`--interactive` (that path has no internet — no `eth_proxy`).

#### Manual session on a node you manage (SSH + tmux)

The `euler-agent-submit --remote-control` line above is fire-and-forget. If you'd rather hold a
GPU node open as an interactive foothold — to run things by hand, debug, and start/restart
Remote Control yourself — allocate the node first, then drive it over SSH + tmux.

> The `config/presets.json` sizes (`medium-gpu`, …) are a `euler-agent-submit` feature and
> **cannot** be passed to a bare node allocation. Specify the SLURM resources directly below
> (mirror a preset's values if you want consistency).

**1. Allocate a long-running GPU node** — detached, so it outlives your shell. The partition
family depends on the GPU type: the **RTX Pro 6000** (Blackwell, 96 GB) uses **`cuda13pr.*`**;
other cards use `gpupr.*` / `gpu.*`. Pick one whose limit covers your wall time — for the RTX
Pro 6000: `cuda13pr.4h` (4 h), `cuda13pr.24h` (2 days), `cuda13pr.120h` (5 days). Run
`sinfo -o "%P %l %G"` to list partitions, limits, and their GPUs. For a multi-day session:

```bash
sbatch -p cuda13pr.120h --time=5-00:00:00 \
    --gpus=nvidia_rtx_pro_6000:1 --gres=gpumem:96g \
    --cpus-per-task=4 --mem-per-cpu=8G \
    --job-name=rc-node --wrap="sleep infinity"
```

**2. Find the node and SSH in** (once the job shows `R` / RUNNING):

```bash
squeue --me                 # note JOBID and NODELIST (e.g. eu-g5-042)
ssh <nodename>              # Euler allows SSH to nodes you hold an allocation on
# fallback if SSH to the node is blocked:  srun --jobid=<jobid> --pty bash
```

**3. Start tmux on the node:**

```bash
tmux new -s rc
```

**4. Launch Remote Control with `euler-agent-run`** — *not* `submit`; you already hold the node.
Load the proxy first (this path skips the SLURM wrapper that normally does it), then:

```bash
module load eth_proxy
cd /path/to/euler_agents
bin/euler-agent-run --remote-control --agent claude \
    --project myproject \
    --gpu \
    --ref /path/to/reference
```

This runs in the foreground: it seeds workspace trust, answers the enable prompt, uses the
persistent `.claude-home`, and prints the `claude.ai/code?environment=...` URL. Detach with
`Ctrl-b d` and steer from the app; the session keeps running on the node.

Notes:
- Pass only node-*use* flags to `euler-agent-run` (`--project`, `--gpu`, `--ref`,
  `--remote-control`). Allocation flags (`--cpus`, `--mem-per-cpu`, `--time`, `--gpu-mem`) were
  fixed in step 1, and `run` rejects them.
- To reconnect after a disconnect: SSH back to the **same** node, then `tmux attach -t rc`.
- An idle GPU reservation still holds the card — use a CPU node (drop `--gpus`/`--gres`) if the
  work only needs the GPU in bursts.

---

## GitHub access (optional)

By default the agent has no GitHub credentials — it can clone public repos anonymously but cannot push, commit to private repos, or open pull requests. Add `--github-auth` when the task requires any of these.

### When to use it

```bash
# Clone a private repo and push changes back
euler-agent-submit --agent claude --github-auth \
    --repo https://github.com/your-org/private-repo \
    --project myproject \
    --task "Refactor the data loader, commit, and push the changes to a new branch."

# Push results or open a PR (repo already cloned in workspace)
euler-agent-submit --agent claude --github-auth \
    --project myproject \
    --task "Create a branch results/run-42, write a summary to results.md, commit and push it."

# Works identically for Codex
euler-agent-submit --agent codex --github-auth \
    --repo https://github.com/your-org/private-repo \
    --project myproject \
    --task "Add type annotations to src/ and push the changes."
```

What `--github-auth` enables inside the container:
- Authenticated clone, fetch, push, pull for all `https://github.com/` URLs (public and private)
- Commits are attributed to the identity in `GIT_USER_NAME` / `GIT_USER_EMAIL`
- Every commit is automatically tagged with a `Co-Authored-By` trailer identifying the agent and model

### Setup

**1. Create a fine-grained PAT** at [github.com/settings/tokens](https://github.com/settings/tokens).
Required permissions: **Contents** (read/write), **Pull requests** (read/write).

**2. Add credentials to `config/secrets.local.env`** (gitignored, auto-loaded):

```bash
cat >> config/secrets.local.env <<'EOF'
GITHUB_TOKEN=github_pat_...
GIT_USER_NAME="Your Name"
GIT_USER_EMAIL="you@example.com"
EOF
chmod 600 config/secrets.local.env
```

That's it. No changes to the Singularity image are needed.

### Quick test

**Via `euler-agent-run`** (runs directly on the current node, no SLURM):

```bash
euler-agent-run --agent claude --github-auth \
    --repo https://github.com/your-org/sandbox \
    --project github-auth-test \
    --task "Create a branch test/github-auth-$(date +%Y%m%d), add hello.txt with 'euler-agents git auth test', commit and push it."
```

**Via `euler-agent-submit`** (submits to SLURM):

```bash
euler-agent-submit --agent claude --github-auth \
    --repo https://github.com/your-org/sandbox \
    --project github-auth-test \
    --task "Create a branch test/github-auth-$(date +%Y%m%d), add hello.txt with 'euler-agents git auth test', commit and push it."
```

After the job finishes, check GitHub — the branch should exist and the commit should show one of:

```
Co-Authored-By: Claude (claude-sonnet-4-6) <noreply@anthropic.com>
Co-Authored-By: Codex (gpt-5.4) <noreply@openai.com>
```


---

## Notifications (optional)

Get notified by email when a job fails or completes. Disabled by default — opt in via `config/settings.local.json`:

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

`on_failure` notifies when the agent exits with a non-zero code. `on_success` notifies on clean completion — useful for long jobs where you want to know the moment they finish, but noisy if you run many jobs in parallel.

Failure emails include the last lines of the error log and a summary from `REPORT.md`. Success emails include the agent summary from `REPORT.md` and the cost.

**Toggle success notifications for a single run** without editing the config:

```bash
euler-agent-submit --agent claude --task "..." --notify-success      # on for this run
euler-agent-submit --agent claude --task "..." --no-notify-success   # off for this run
```

> **Note:** Email is sent via `/usr/sbin/sendmail` (Postfix relay on the compute node). ETH addresses (`@ethz.ch`) work reliably. External addresses depend on the ETH relay policy.

<!-- TODO: Slack and Telegram webhook support -->
