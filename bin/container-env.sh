# Sourced INSIDE the container by both entrypoints — bin/inner.sh (headless) and
# bin/claude-shellrc (interactive) — so the two paths set up the same environment
# instead of drifting apart. Not executable on purpose.
#
# Relies on the variables bin/euler-agent-run injects with --env:
#   EULER_AGENTS_DIR   this repo, bound read-only at its host path
#   AGENT_WORKSPACE    the project workspace, bound read-write at its host path
#   GIT_USER_NAME / GIT_USER_EMAIL   commit identity (not a credential)
#   CONDA_PKGS_DIRS    single path: host package cache or /tmp fallback
# and optionally PIXI_HOME, XDG_CACHE_HOME, CUDA_CACHE_PATH (host-side caches so
# nothing accumulates under the quota-limited home).

# --containall gives the container its own /home; HOME is not always set to it.
export HOME=/home
export PATH=/opt/conda/bin:$PATH
# pixi is not in the image: it is the host's static binary, reachable through the
# PIXI_HOME bind. Its global config there redirects envs and cache off the home quota.
if [[ -n "${PIXI_HOME:-}" && -d "$PIXI_HOME/bin" ]]; then
    export PATH="$PIXI_HOME/bin:$PATH"
fi

mkdir -p "${AGENT_WORKSPACE:?AGENT_WORKSPACE not set}/conda_envs"
mkdir -p "${CONDA_PKGS_DIRS:-/tmp/conda_pkgs}"
[[ -n "${XDG_CACHE_HOME:-}" ]]  && mkdir -p "$XDG_CACHE_HOME"
[[ -n "${CUDA_CACHE_PATH:-}" ]] && mkdir -p "$CUDA_CACHE_PATH"

# Git identity so `git commit` works, plus the commit-msg hook that appends the
# Co-Authored-By trailer. No token is ever injected: the agent commits locally and
# the user pushes from the host after the run.
git config --global user.name  "${GIT_USER_NAME:-euler-agent}"
git config --global user.email "${GIT_USER_EMAIL:-euler-agent@noreply.invalid}"
git config --global core.hooksPath "${EULER_AGENTS_DIR:?EULER_AGENTS_DIR not set}/config/git-hooks"
