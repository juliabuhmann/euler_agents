# Briefing: you are running inside a Singularity container on a SLURM cluster

The launcher writes this file, with this launch's mount table appended, to
`/tmp/agent-briefing.md`, and the agent home's `CLAUDE.md` imports it, so Claude reads it at
the start of every session. Codex does not; paste it there by hand.

- **The container is the sandbox.** Permission prompts are switched off. The mounted
  directories are the real boundary: nothing else exists inside, and read-only mounts reject
  writes at the kernel level. If a path you expect is missing, it was not mounted — say so.
- **Paths are identical inside and outside.** Every mounted directory sits at its host path,
  so absolute paths, shebangs, conda prefixes and SLURM scripts you write are valid on the
  host. Do not translate paths. The one exception is `~`: it is `/home`, a private agent home
  shared by all of the user's containers — not the user's home. Never put project files,
  environments or caches under `~`.
- **Parents of mounted directories look empty.** They exist only as mount points. Do not
  conclude that files are missing or were deleted from a sparse `ls` of a parent.
- **Environments and caches.** `conda`, `mamba`, `uv` (and `pixi`, from the host) are on
  `PATH`. `conda create -n NAME` puts the environment in the workspace's `conda_envs/`, at a
  path that exists on the host; the user's own conda environments are visible read-only.
  Package and pip/uv/torch/Hugging Face caches are redirected to project storage already.
- **There is no SLURM inside.** `sbatch`, `squeue`, `srun` and the `module` system are not
  available. If work needs a batch job or a GPU allocation, write the job script with the
  real paths and ask the user to submit it from outside.
- **No root.** `apt-get` cannot install anything. Use conda, pixi or uv.
- **Git: commit, do not push.** There is no push credential. Commit in a read-write mount
  with the preset identity. Claude: end each message with one `Co-Authored-By` trailer naming
  the model you are (the commit hook rejects a Claude commit without one); for Codex the hook
  adds it. Leave the
  work on a branch, and tell the user what to push.
- **Where to write.** Results and generated output into the workspace or another read-write
  mount, never into read-only data. Scratch into `/tmp`, which vanishes with the job.
- **The job has a wall-clock limit** and ends without warning when it is reached. Keep the
  user informed of long-running steps. When the launcher knows the end time, it is in the
  *Time limit* section below.
