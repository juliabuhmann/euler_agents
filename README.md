# euler_agents

AI coding agents take time. A task like "refactor this module", "write tests for this codebase", or "analyse this dataset and produce a report" can run for minutes to hours. This repository lets you submit those tasks to the Euler HPC cluster as ordinary SLURM batch jobs — fire and forget, just like any compute job.

You write a task in plain English. The agent (Codex or Claude) gets a compute node, a clean Singularity environment, and a persistent workspace on cluster storage. You come back to the results.

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

**What you get:**
- Tasks run unattended on a compute node — no keeping a terminal open, no babysitting
- The agent can clone repos, install conda packages, read and write files freely
- Named projects (`--project`) give the agent a persistent workspace across multiple jobs — useful for multi-step work where later tasks build on earlier results
- Claude jobs record actual cost in `REPORT.md` so you know what each run spent

**Sandbox boundary — what is isolated:**
- The agent runs inside a Singularity container with `--cleanenv --containall`: no access to your home directory, other cluster paths, or any host mount not explicitly listed
- The harness repo itself is mounted read-only (`/repo:ro`) — the agent cannot modify the scripts that launched it
- Each job gets its own private tmpdir, so parallel jobs don't interfere with each other
- The agent runs as your own user UID — no privilege escalation is possible

**Risks — what is not protected:**
- **Unrestricted execution within the container.** Both agents run with all confirmation prompts disabled. Inside the container, the agent executes arbitrary shell commands and code with no approval step.
- **Full write access to the workspace.** The agent can delete, overwrite, or corrupt everything in `/workspace`, including prior results in a named project. There is no undo.
- **Outbound network.** The container has internet access (via the `eth_proxy` module). The agent can make HTTP requests, clone external repos, or call third-party APIs.
- **API key exposure.** `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` are injected as environment variables. If the agent reads and exfiltrates its own environment — or if a cloned repo contains a prompt-injection attack — those keys are at risk. Keep the keys scoped and rotate them if you suspect a problem.
- **Cost overruns.** Codex has no spending cap. Claude defaults to `--max-budget-usd 10`; set it explicitly for expensive tasks.

The practical rule: treat anything you pass to the agent (repo content, task prompt, reference data) the same way you would treat code you're about to `bash -c` on a compute node — because that is roughly what happens.

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

Edit `config/settings.json` — set your workspace and logs paths (use cluster project storage, not home):

```json
{
  "workspace_dir": "/cluster/project/beltrao/<your-username>/workspaces",
  "logs_dir":      "/cluster/project/beltrao/<your-username>/logs",
  "image_path":    "/cluster/project/beltrao/jbuhmann/agentic_ai/images/euler-agents.sif"
}
```

```bash
mkdir -p /cluster/project/beltrao/<your-username>/{workspaces,logs}
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
WORKSPACE=$(python3 -c "import json; print(json.load(open('config/settings.json'))['workspace_dir'])")
cat "$WORKSPACE/harness-test/hello.txt"
cat "$WORKSPACE/harness-test/REPORT.md"
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
WORKSPACE=$(python3 -c "import json; print(json.load(open('config/settings.json'))['workspace_dir'])")
cat "$WORKSPACE/harness-test/hello.txt"
cat "$WORKSPACE/harness-test/REPORT.md"   # should include a cost= field
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
