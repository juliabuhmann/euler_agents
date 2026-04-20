#!/usr/bin/env bash
# Runs inside the Singularity container.
# Optionally clones a repo, then runs the requested agent on the task.
set -euo pipefail

export PATH=/opt/conda/bin:$PATH
export HOME=/home

# Conda envs go to workspace (persist across jobs); package cache to /tmp (ephemeral)
mkdir -p /workspace/conda_envs /tmp/conda_pkgs

AGENT="${AGENT:?AGENT env var not set}"
REPO_URL="${REPO_URL:-}"
MODEL="${AGENT_MODEL:-}"

TASK=$(cat /tmp/.task)
[[ -z "$TASK" ]] && { echo "ERROR: task is empty" >&2; exit 1; }

cd /workspace

# Clone repo into workspace if requested (persists after job)
if [[ -n "$REPO_URL" ]]; then
    REPO_NAME=$(basename "$REPO_URL" .git)
    echo "=== Cloning $REPO_URL ==="
    git clone "$REPO_URL" "$REPO_NAME"
    cd "$REPO_NAME"
fi

case "$AGENT" in
    codex)
        MODEL="${MODEL:-gpt-5.4}"
        echo "=== Running Codex (model=$MODEL) ==="
        echo "--- Task ---"
        echo "$TASK"
        echo "------------"
        codex exec \
            --json \
            --model "$MODEL" \
            --dangerously-bypass-approvals-and-sandbox \
            --skip-git-repo-check \
            "$TASK"
        ;;
    claude)
        echo "ERROR: Claude agent not yet implemented" >&2
        exit 1
        ;;
    *)
        echo "ERROR: Unknown agent '$AGENT'" >&2
        exit 1
        ;;
esac
