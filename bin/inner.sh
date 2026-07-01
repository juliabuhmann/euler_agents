#!/usr/bin/env bash
# Runs inside the Singularity container.
# Optionally clones a repo, then runs the requested agent on the task.
set -euo pipefail

export PATH=/opt/conda/bin:$PATH
export HOME=/home

mkdir -p /workspace/conda_envs /tmp/conda_pkgs

AGENT="${AGENT:?AGENT env var not set}"
REPO_URL="${REPO_URL:-}"
GIT_AUTH="${GIT_AUTH:-}"
MODEL="${AGENT_MODEL:-}"
MAX_BUDGET_USD="${AGENT_MAX_BUDGET_USD:-}"
AGENT_EFFORT="${AGENT_EFFORT:-}"
JOB_ID="${SLURM_JOB_ID:-interactive}"

# Remote Control mode: launch a long-running, steerable Claude session instead of the
# headless one-shot task flow. Steer it from claude.ai/code or the Claude mobile app.
# Verified: the `remote-control` subcommand runs headless (no TTY), unlike the
# `--remote-control` flag which falls through to --print and demands stdin input.
if [[ "${REMOTE_CONTROL:-}" == "true" ]]; then
    RC_NAME="${RC_SESSION_NAME:-euler-rc}"
    cd /workspace
    if [[ "$GIT_AUTH" == "true" ]]; then
        git config --global user.name  "$GIT_USER_NAME"
        git config --global user.email "$GIT_USER_EMAIL"
        git config --global url."https://${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
    fi
    if [[ -n "$REPO_URL" ]]; then
        REPO_NAME=$(basename "$REPO_URL" .git)
        [[ -d "$REPO_NAME" ]] || git clone "$REPO_URL" "$REPO_NAME"
        cd "$REPO_NAME"
    fi
    # Pre-accept the per-directory workspace-trust dialog. Remote Control (unlike `claude -p`)
    # prompts for trust and has no --dangerously-skip-permissions; trust is stored per path
    # in ~/.claude.json. Verified: without this it aborts with "Workspace not trusted".
    python3 - "$PWD" <<'PY'
import json, os, sys
cwd = sys.argv[1]
p = os.path.expanduser("~/.claude.json")
d = json.load(open(p)) if os.path.exists(p) else {}
d.setdefault("projects", {}).setdefault(cwd, {})["hasTrustDialogAccepted"] = True
json.dump(d, open(p, "w"))
PY
    echo "=== Claude Remote Control  (session: $RC_NAME) ==="
    echo "Steer from https://claude.ai/code or the Claude mobile app (find it by name, or use"
    echo "the claude.ai/code URL printed below once it connects)."
    echo "Live until this SLURM job ends; a >10-min network drop also ends it."
    echo "Model is chosen per-session in the app; --model/--effort/--max-budget-usd do not apply."
    echo "------------"
    # Auto-answer the 'Enable Remote Control?' prompt (no TTY under SLURM), and bypass
    # per-action approvals so the agent can work unattended while you steer intermittently.
    set +e
    printf 'y\n' | claude remote-control --name "$RC_NAME" --permission-mode bypassPermissions
    RC_EXIT=$?
    set -e
    exit "$RC_EXIT"
fi

TASK=$(cat /tmp/.task)
[[ -z "$TASK" ]] && { echo "ERROR: task is empty" >&2; exit 1; }

TASK_WITH_FOOTER="${TASK}

---
After completing the above task, write a concise summary (max 20 lines) to /tmp/run-summary.txt covering:
- what you did
- key outputs created (paths and sizes if relevant)
- any errors or limitations encountered"

cd /workspace

git config --global core.hooksPath /repo/config/git-hooks

if [[ "$GIT_AUTH" == "true" ]]; then
    git config --global user.name  "$GIT_USER_NAME"
    git config --global user.email "$GIT_USER_EMAIL"
    git config --global url."https://${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
    echo "=== GitHub auth configured for ${GIT_USER_NAME} <${GIT_USER_EMAIL}> ==="
fi

if [[ -n "$REPO_URL" ]]; then
    REPO_NAME=$(basename "$REPO_URL" .git)
    [[ -d "$REPO_NAME" ]] && rm -rf "$REPO_NAME"
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
        CLAUDE_ARGS=(--dangerously-skip-permissions --model "$MODEL" -p --output-format json)
        [[ -n "$MAX_BUDGET_USD" ]] && CLAUDE_ARGS+=(--max-budget-usd "$MAX_BUDGET_USD")
        [[ -n "$AGENT_EFFORT"   ]] && CLAUDE_ARGS+=(--effort "$AGENT_EFFORT")
        echo "=== Running Claude Code (model=$MODEL effort=${AGENT_EFFORT:-default} budget=\$${MAX_BUDGET_USD:-unlimited}) ==="
        echo "--- Task ---"
        echo "$TASK"
        echo "------------"
        set +e
        claude "${CLAUDE_ARGS[@]}" "$TASK_WITH_FOOTER" > /tmp/claude-output.json
        AGENT_EXIT=$?
        set -e
        ;;
    *)
        echo "ERROR: Unknown agent '$AGENT'" >&2
        exit 1
        ;;
esac

# Extract cost and summary from Claude JSON output
AGENT_COST=""
if [[ "$AGENT" == "claude" ]]; then
    AGENT_COST=$(python3 -c '
import json, sys
try:
    data = json.load(open("/tmp/claude-output.json"))
    cost = data.get("total_cost_usd")
    if cost is not None:
        print("%.4f" % cost)
except Exception as e:
    print("Warning: could not parse claude-output.json: %s" % e, file=sys.stderr)
')
    # If agent didn't write a summary file, extract it from the JSON result field
    if [[ ! -f /tmp/run-summary.txt ]]; then
        python3 -c '
import json, sys
try:
    data = json.load(open("/tmp/claude-output.json"))
    result = data.get("result", "").strip()
    if result:
        open("/tmp/run-summary.txt", "w").write(result + "\n")
except Exception as e:
    print("Warning: could not extract summary from claude-output.json: %s" % e, file=sys.stderr)
'
    fi
    # On failure, surface Claude's raw JSON to the job log — otherwise the stop
    # reason (budget cap, max turns, API/auth error) dies with the container tmpdir.
    if [[ "$AGENT_EXIT" -ne 0 ]]; then
        echo "=== Claude exited $AGENT_EXIT — result JSON follows ===" >&2
        python3 -c '
import json, sys
try:
    d = json.load(open("/tmp/claude-output.json"))
    for k in ("type", "subtype", "is_error", "num_turns", "total_cost_usd", "result"):
        if k in d:
            print("  %s: %s" % (k, d[k]), file=sys.stderr)
except Exception as e:
    sys.stderr.write("  (could not parse claude-output.json: %s)\n" % e)
    try:
        sys.stderr.write(open("/tmp/claude-output.json").read()[:4000] + "\n")
    except Exception:
        pass
' >&2
    fi
fi

# Append agent-written summary to REPORT.md
MODEL="${MODEL:-unknown}"
if [[ -f /tmp/run-summary.txt ]]; then
    {
        printf '\n## Run %s  (job=%s  model=%s  exit=%s%s)\n\n' \
            "$RUN_TS" "$JOB_ID" "$MODEL" "$AGENT_EXIT" "${AGENT_COST:+  cost=\$$AGENT_COST}"
        cat /tmp/run-summary.txt
    } >> /workspace/REPORT.md
    echo "=== Summary appended to /workspace/REPORT.md ==="
fi

exit "$AGENT_EXIT"
