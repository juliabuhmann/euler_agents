#!/usr/bin/env bash
# Runs inside the Singularity container.
# Optionally clones a repo, then runs the requested agent on the task.
set -euo pipefail

export PATH=/opt/conda/bin:$PATH
export HOME=/home

mkdir -p /workspace/conda_envs /tmp/conda_pkgs

AGENT="${AGENT:?AGENT env var not set}"
REPO_URL="${REPO_URL:-}"
MODEL="${AGENT_MODEL:-}"
JOB_ID="${SLURM_JOB_ID:-interactive}"

TASK=$(cat /tmp/.task)
[[ -z "$TASK" ]] && { echo "ERROR: task is empty" >&2; exit 1; }

TASK_WITH_FOOTER="${TASK}

---
After completing the above task, write a concise summary (max 20 lines) to /tmp/run-summary.txt covering:
- what you did
- key outputs created (paths and sizes if relevant)
- any errors or limitations encountered"

cd /workspace

if [[ -n "$REPO_URL" ]]; then
    REPO_NAME=$(basename "$REPO_URL" .git)
    echo "=== Cloning $REPO_URL ==="
    git clone "$REPO_URL" "$REPO_NAME"
    cd "$REPO_NAME"
fi

RUN_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
AGENT_EXIT=0

case "$AGENT" in
    codex)
        MODEL="${MODEL:-gpt-5.4}"
        echo "=== Running Codex (model=$MODEL) ==="
        echo "--- Task ---"
        echo "$TASK"
        echo "------------"
        set +e
        codex exec \
            --json \
            --model "$MODEL" \
            --dangerously-bypass-approvals-and-sandbox \
            --skip-git-repo-check \
            "$TASK_WITH_FOOTER"
        AGENT_EXIT=$?
        set -e
        ;;
    claude)
        MODEL="${MODEL:-claude-sonnet-4-6}"
        echo "=== Running Claude Code (model=$MODEL) ==="
        echo "--- Task ---"
        echo "$TASK"
        echo "------------"
        set +e
        claude \
            --dangerously-skip-permissions \
            --model "$MODEL" \
            -p "$TASK_WITH_FOOTER"
        AGENT_EXIT=$?
        set -e
        ;;
    *)
        echo "ERROR: Unknown agent '$AGENT'" >&2
        exit 1
        ;;
esac

# Append agent-written summary to REPORT.md
if [[ -f /tmp/run-summary.txt ]]; then
    {
        printf '\n## Run %s  (job=%s  model=%s  exit=%s)\n\n' \
            "$RUN_TS" "$JOB_ID" "$MODEL" "$AGENT_EXIT"
        cat /tmp/run-summary.txt
    } >> /workspace/REPORT.md
    echo "=== Summary appended to /workspace/REPORT.md ==="
fi

exit "$AGENT_EXIT"
