#!/bin/bash
# Generated with assistance of claude code.
#SBATCH -J lab1-p2
#SBATCH -p development
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 00:30:00
#SBATCH -o lab1-p2.%j.out
#SBATCH -A TRA25006
# Part 2: coarse sweep on one Frontera node (+ the day-one perf checks).
# Submit from lab1/starter_files:  sbatch ../jobs/part2.slurm
# Commit your written prediction BEFORE submitting this.
# Expected node time: ~3 min (10 points x 3 runs x ~2.3 s, plus build/checks).
PART=part2
. "${SLURM_SUBMIT_DIR:-$PWD}/../jobs/lab1_common.sh"
setup_all
THREADS=${THREADS:-"1 2 4 8 16 28 40 56 84 112"}

# make sweep IMPLS=coarse THREADS="..." == this (SHARDS is ignored for coarse)
run_sweep "$RES/sweep" coarse 1 $THREADS

# Day-one sanity for Part 3's event set: one counted run, checked for
# multiplexing (perfstat.sh hides perf's enabled-% column).
EV3=$(evlist cycles instructions L1-dcache-loads L1-dcache-load-misses cache-misses \
             "$HITM" "$RHITM" context-switches cpu-migrations task-clock)
mux_check "$EV3" "$S0_8"
finish
