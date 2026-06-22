#!/bin/bash
#SBATCH -J test_medium_cpu
#SBATCH --cpus-per-task=4
#SBATCH --mem-per-cpu=8G
#SBATCH --time=00:05:00
#SBATCH -o /cluster/home/buhmanju/src/euler_agents/test_slurm/test_medium_cpu_%j.out
#SBATCH -e /cluster/home/buhmanju/src/euler_agents/test_slurm/test_medium_cpu_%j.err

echo "Hello from Euler!"
echo "Running on node: $(hostname)"
echo "Date and time:   $(date)"
echo "Job ID:          $SLURM_JOB_ID"
echo "CPUs allocated:  $SLURM_CPUS_ON_NODE"
