#!/bin/bash
# Generated with assistance of claude code.
#SBATCH -J lab1-sf
#SBATCH -p development
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 00:30:00
#SBATCH -o lab1-sf.%j.out
#SBATCH -A TRA25006
# Supplementary to Parts 2 and 4: the coarse and sharded:mutex sweeps
# again, pinned socket 0 first (jobs/sweep_socketfirst.sh), because
# Frontera numbers CPUs alternately by socket and the provided sweep.sh
# therefore spans both sockets from T=2.  The provided-sweep.sh CSVs from
# part2/part4 remain the protocol runs; plot these beside them.
# Expected node time: ~6 min.
PART=socketfirst
. "${SLURM_SUBMIT_DIR:-$PWD}/../jobs/lab1_common.sh"
setup_all
THREADS=${THREADS:-"1 2 4 8 16 28 40 56 84 112"}
SHARDS=${SHARDS:-256}
export SWEEP_SH="$LAB/jobs/sweep_socketfirst.sh"
run_sweep "$RES/sweep_socketfirst" coarse 1 $THREADS
run_sweep "$RES/sweep_socketfirst" sharded:mutex "$SHARDS" $THREADS
finish
