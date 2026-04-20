# euler_agents

Run AI coding agents (Codex, Claude) on the Euler HPC cluster via SLURM or interactively. Agents work inside a Singularity container and can clone repositories, install conda packages, and write code. Outputs persist in a workspace directory on cluster storage.

---

## One-time setup

### 1. Clone and configure

```bash
cd ~/src
git clone <repo-url> euler_agents
cd euler_agents
```

Edit `config/settings.json` — set your own workspace and logs paths (use cluster project storage, not home):

```json
{
  "workspace_dir": "/cluster/project/beltrao/<your-username>/workspaces",
  "logs_dir":      "/cluster/project/beltrao/<your-username>/logs",
  "image_path":    "/cluster/project/beltrao/jbuhmann/agentic_ai/images/euler-agents.sif",
  ...
}
```

```bash
mkdir -p /cluster/project/beltrao/<your-username>/{workspaces,logs}
```

### 2. Singularity image

A pre-built image is available at:

```
/cluster/project/beltrao/jbuhmann/agentic_ai/images/euler-agents.sif
```

To rebuild it (login node, maintainers only):

```bash
module load eth_proxy
singularity build --fakeroot \
    /cluster/project/beltrao/jbuhmann/agentic_ai/images/euler-agents.sif \
    images/euler-agents.def
```

### 3. Authenticate with Codex

Codex is only installed inside the Singularity image, not on the Euler login node. Authentication must therefore happen inside the container, with `home-codex/` mounted as `$HOME` so the tokens are written to the right place and picked up by all future jobs.

Run the following **once** on the login node:

```bash
cd ~/src/euler_agents
module load eth_proxy
singularity shell --cleanenv --containall \
    --home "$(pwd)/home-codex:/home" \
    --bind /tmp:/tmp \
    /cluster/project/beltrao/jbuhmann/agentic_ai/images/euler-agents.sif
```

Inside the container shell:

```bash
export HOME=/home
codex auth
```

Codex will display a short device code and a URL — open the URL in your browser, enter the code, and complete the login. Once done, verify the tokens were saved and exit:

```bash
ls ~/.codex/   # should show auth files
exit
```

From now on, every job copies `home-codex/` into its private tmpdir so your credentials are available without re-authenticating.

---

## Usage

```bash
# One-off task (timestamped workspace)
bin/submit --agent codex --task "Add type annotations to all functions in src/"

# Named project — workspace is reused across all jobs with the same name
bin/submit --agent codex --project myanalysis --task "Clone the repo and set up the environment"
bin/submit --agent codex --project myanalysis --task "Now add unit tests"

# Clone a repo into the workspace first
bin/submit --agent codex --project myanalysis \
    --repo https://github.com/org/myrepo \
    --task "Write unit tests for the data loading module"

# Edit config/task.json and submit without arguments
bin/submit --agent codex

# Interactive shell on a compute node
bin/submit --interactive --agent codex --project myanalysis

# Override job time limit
bin/submit --agent codex --task "..." --time 8:00:00
```

Without `--project`, each run gets a fresh timestamped workspace (e.g. `codex_20260420_143201_12345/`). With `--project`, all jobs share the same directory under `workspace_dir`, so later tasks can build on earlier results. The workspace is mounted as `/workspace` inside the container and persists after the job ends.

> **Note:** Do not run two jobs with the same `--project` in parallel. Each job gets its own task file, so there is no race on that. However, two agents writing to the same workspace simultaneously will conflict on files. The intended pattern is sequential: wait for one job to finish before submitting the next.

### Conda environments

Conda environments created by the agent are stored in `<workspace>/conda_envs/` and persist across jobs in the same project. The package cache goes to scratch (`$TMPDIR`) and is cleaned up automatically.

**Ask the agent to create an env:**
```bash
bin/submit --agent codex --project myproject \
    --task "Create a conda environment called 'myenv' with python=3.11 and numpy, then write numpy_test.py that prints the numpy version and run it."
```

**Ask the agent to reuse it in a later job:**
```bash
bin/submit --agent codex --project myproject \
    --task "Using the existing conda environment 'myenv', write a script that creates a numpy array of random numbers and prints their mean."
```

**Test an env yourself non-interactively:**
```bash
singularity exec --cleanenv --containall \
    --home "$(pwd)/home-codex:/home" \
    --bind /tmp:/tmp \
    --bind /cluster/project/beltrao/<your-username>/workspaces/myproject:/workspace \
    --env "CONDA_ENVS_DIRS=/workspace/conda_envs:/opt/conda/envs" \
    /cluster/project/beltrao/jbuhmann/agentic_ai/images/euler-agents.sif \
    bash -c "source /opt/conda/etc/profile.d/conda.sh && conda activate myenv && python myscript.py"
```

**Or interactively:**
```bash
bin/submit --interactive --agent codex --project myproject
# inside the shell:
source /opt/conda/etc/profile.d/conda.sh
conda activate myenv
python myscript.py
```

### Verify your setup

```bash
bin/submit --agent codex --project test-hello \
    --task "Write a Python script called hello.py that prints 'Hello from Euler' and run it to verify it works."
```

Check the job status:
```bash
squeue
```

Follow the logs (replace with your job ID):
```bash
tail -f /cluster/project/beltrao/<your-username>/logs/slurm-<jobid>.out
```

Once the job finishes, verify the output:
```bash
ls /cluster/project/beltrao/<your-username>/workspaces/test-hello/
cat /cluster/project/beltrao/<your-username>/workspaces/test-hello/hello.py
```
