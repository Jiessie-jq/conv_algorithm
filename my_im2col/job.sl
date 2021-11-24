#!/bin/bash
#SBATCH --ntasks-per-node=1
#SBATCH --mem=2GB
#SBATCH --nodes=1
#SBATCH --time=02:00:00
#SBATCH --output=im2col.out
#SBATCH --error=im2col.err
#SBATCH --gres=gpu:1
./a.out
