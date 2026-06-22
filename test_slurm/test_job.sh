#!/bin/bash
#SBATCH -J test_job
#SBATCH -n 1
#SBATCH --mem-per-cpu=1g
#SBATCH --time=00:05:00
#SBATCH -o /cluster/home/buhmanju/src/euler_agents/test_slurm/test_job_%j.out
#SBATCH -e /cluster/home/buhmanju/src/euler_agents/test_slurm/test_job_%j.err

echo "Hello from Euler!"
echo "Running on node: $(hostname)"
echo "Date and time:   $(date)"
echo "Job ID:          $SLURM_JOB_ID"
