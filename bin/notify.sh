#!/usr/bin/env bash
# Send a job completion or failure notification via email.
# Called by euler-agent-run after the agent finishes.
#
# Required env vars (set by euler-agent-run):
#   NOTIFY_EMAIL_ENABLED  — true|false
#   NOTIFY_EMAIL_ADDRESS  — recipient
#   NOTIFY_ON_FAILURE     — true|false
#   NOTIFY_ON_SUCCESS     — true|false
#   LOGS_DIR              — path to slurm log directory

AGENT_EXIT=0
WORKSPACE=""
AGENT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --exit-code) AGENT_EXIT="$2"; shift 2 ;;
        --workspace) WORKSPACE="$2";  shift 2 ;;
        --agent)     AGENT="$2";      shift 2 ;;
        *) shift ;;
    esac
done

[[ "${NOTIFY_EMAIL_ENABLED:-false}" != "true" ]] && exit 0

if [[ "$AGENT_EXIT" -eq 0 ]]; then
    [[ "${NOTIFY_ON_SUCCESS:-false}" != "true" ]] && exit 0
    STATUS="SUCCESS"
else
    [[ "${NOTIFY_ON_FAILURE:-true}" != "true" ]] && exit 0
    STATUS="FAILED"
fi

ADDRESS="${NOTIFY_EMAIL_ADDRESS:-}"
[[ -z "$ADDRESS" ]] && { echo "notify.sh: no email address configured" >&2; exit 0; }

JOB_ID="${SLURM_JOB_ID:-unknown}"
JOB_NAME="${SLURM_JOB_NAME:-unknown}"
NODE="${SLURMD_NODENAME:-unknown}"

REPORT_SUMMARY="(REPORT.md not found — agent may have crashed before writing it)"
if [[ -f "$WORKSPACE/REPORT.md" ]]; then
    START=$(grep -n "job=${JOB_ID}" "$WORKSPACE/REPORT.md" | cut -d: -f1)
    if [[ -n "$START" ]]; then
        REPORT_SUMMARY=$(tail -n +"$START" "$WORKSPACE/REPORT.md")
    else
        REPORT_SUMMARY="(no entry for job $JOB_ID found in REPORT.md — agent may have crashed before writing it)"
    fi
fi

ERR_TAIL=""
if [[ "$AGENT_EXIT" -ne 0 && -n "${LOGS_DIR:-}" && -f "$LOGS_DIR/slurm-${JOB_ID}.err" ]]; then
    ERR_TAIL=$(tail -n 10 "$LOGS_DIR/slurm-${JOB_ID}.err")
fi

BODY="Job:       $JOB_ID ($JOB_NAME)
Status:    $STATUS
Agent:     $AGENT
Node:      $NODE
Exit code: $AGENT_EXIT
Workspace: $WORKSPACE

--- Agent summary (REPORT.md) ---
$REPORT_SUMMARY"

if [[ -n "$ERR_TAIL" ]]; then
    BODY+="

--- Last 10 lines of stderr ---
$ERR_TAIL"
fi

/usr/sbin/sendmail -t << EOF
To: $ADDRESS
From: ${USER:-euler}@ethz.ch
Subject: Job ${STATUS}: $AGENT ($JOB_ID)

$BODY
EOF
