#!/usr/bin/env bash
#SBATCH --job-name=euler-agent
#SBATCH --time=4:00:00
#SBATCH --mem-per-cpu=8G
#SBATCH --cpus-per-task=2
#SBATCH --output=/cluster/project/beltrao/jbuhmann/agentic_ai/logs/slurm-%j.out
#SBATCH --error=/cluster/project/beltrao/jbuhmann/agentic_ai/logs/slurm-%j.err
#
# Usage: sbatch slurm/run-agent.sh [--agent codex|claude] [--task "..."] [--repo URL] [--model MODEL]
# Prefer using euler-agent-submit which sets --output/--error from config/settings.json.
set -euo pipefail

module load eth_proxy

REPO_DIR="${EULER_AGENTS_DIR:?EULER_AGENTS_DIR not set — submit via euler-agent-submit}"

echo "SLURM job $SLURM_JOB_ID on $(hostname)"
exec "$REPO_DIR/bin/euler-agent-run" "$@"
