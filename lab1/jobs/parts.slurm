#!/bin/bash
# Generated with assistance of claude code.
#SBATCH -J lab1-parts
#SBATCH -p development
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 02:00:00
#SBATCH -o lab1-parts.%j.out
#SBATCH -A TRA25006
# Several parts back to back in ONE allocation, so curves that share axes
# come from the same physical node (two separate jobs are two nodes).
#   PARTS="part2 part3 part4" sbatch ../jobs/parts.slurm          # ~10 min
#   N=256 PARTS="part5 part6" sbatch ../jobs/parts.slurm          # ~60-90 min
# The #SBATCH lines inside the part scripts are plain comments here.
# Frontera's development queue allows 2 jobs per user, queued + running,
# and an idev session counts as one: exit idev before submitting, and
# prefer one parts.slurm job over several part jobs.  (To queue more,
# override the queue: sbatch -p small ../jobs/parts.slurm.)
set -u
for p in ${PARTS:?set PARTS, e.g. PARTS=\"part2 part3 part4\"}; do
    echo "=== $p on $(hostname) at $(date +%T)"
    bash "${SLURM_SUBMIT_DIR:-$PWD}/../jobs/$p.slurm" || echo "=== $p exited with $?"
done
