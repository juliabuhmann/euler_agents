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
# Submit a GPU job (defaults to one A100, gpupr.4h partition, 4h time limit)
euler-agent-submit --agent claude --gpu --project mygpuproject \
    --task "Train the model in train.py and save checkpoints to /workspace/checkpoints/"

# Longer job — partition is auto-selected (6h → gpupr.24h)
euler-agent-submit --agent claude --gpu --time 6:00:00 --project mygpuproject \
    --task "Run the full training pipeline"

# Select a different GPU type
euler-agent-submit --agent claude --gpu --gpu-type rtx3090 --project mygpuproject \
    --task "Run inference and write results to /workspace/results.json"

# Hard-code a specific partition (overrides auto-selection)
euler-agent-submit --agent claude --gpu --partition gpu.24h --project mygpuproject \
    --task "..."

# Interactive GPU shell
euler-agent-submit --interactive --gpu --agent claude --project mygpuproject
```

`--gpu` sets `--gpus=<type>:1`, `--tmp=50G`, and a 4-hour default time limit. The SLURM partition is auto-selected from the `gpupr.*` family based on the requested time (≤4h → `gpupr.4h`, ≤24h → `gpupr.24h`, longer → `gpupr.120h`). Override with `--partition` to use a specific partition (e.g. `gpu.24h` for the general queue). `--gpu-type` defaults to `a100`.

---

## Claude agent (optional)

Claude Code (`--agent claude`) is an alternative to Codex with the same interface.

| | Codex | Claude |
|---|---|---|
| Auth | Browser OAuth → `home-codex/` | API key (`ANTHROPIC_API_KEY`) |
| Default model | `gpt-5.4` | `claude-sonnet-4-6` |
| Cost reporting | not implemented | recorded in `REPORT.md` |

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

### Controlling costs

| Flag | Controls | Default |
|---|---|---|
| `--max-budget-usd` | Hard USD cap — agent stops when hit | `10` |
| `--effort` | Thinking depth: `low / medium / high / xhigh / max` | Claude default |
| `--model` | Model — haiku ≪ sonnet ≪ opus in cost | `claude-sonnet-4-6` |

Priority order: CLI flag > `config/task.json` > `config/settings.json`.

```bash
euler-agent-submit --agent claude --max-budget-usd 3 --effort low --task "Quick exploration"
euler-agent-submit --agent claude --max-budget-usd 20 --effort high --task "Deep analysis"
```

To change defaults for all Claude jobs, edit `config/settings.json`:

```json
"claude": { "model": "claude-sonnet-4-6", "effort": null, "max_budget_usd": 10 }
```

After each run the actual cost is recorded in the workspace `REPORT.md`:

```
## Run 2026-04-21T12:00:00Z  (job=12345  model=claude-sonnet-4-6  exit=0  cost=$1.2340)
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
