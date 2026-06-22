#!/bin/bash
#SBATCH -J test_medium_gpu
#SBATCH --cpus-per-task=4
#SBATCH --mem-per-cpu=8G
#SBATCH --gpus=a100:1
#SBATCH --gres=gpumem:40g
#SBATCH -p gpupr.4h
#SBATCH --tmp=50G
#SBATCH --time=00:05:00
#SBATCH -o /cluster/home/buhmanju/src/euler_agents/test_slurm/test_medium_gpu_%j.out
#SBATCH -e /cluster/home/buhmanju/src/euler_agents/test_slurm/test_medium_gpu_%j.err

echo "Hello from Euler!"
echo "Running on node: $(hostname)"
echo "Date and time:   $(date)"
echo "Job ID:          $SLURM_JOB_ID"
echo "CPUs allocated:  $SLURM_CPUS_ON_NODE"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
