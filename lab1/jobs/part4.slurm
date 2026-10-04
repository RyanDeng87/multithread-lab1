#!/bin/bash
# Generated with assistance of claude code.
#SBATCH -J lab1-p4
#SBATCH -p development
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 00:45:00
#SBATCH -o lab1-p4.%j.out
#SBATCH -A TRA25006
# Part 4: sharded:mutex sweep (+ a coarse reference sweep on the SAME node,
# for the shared axes), then the shard-count measurement at one thread and
# at a chosen T -- pinned and median of three via sweep.sh, instead of the
# README's unpinned single-shot  ./bench sharded:mutex 32 $n.
# Expected node time: ~12 min.
PART=part4
. "${SLURM_SUBMIT_DIR:-$PWD}/../jobs/lab1_common.sh"
setup_all
THREADS=${THREADS:-"1 2 4 8 16 28 40 56 84 112"}
SHARDS=${SHARDS:-256}
N_LIST=${N_LIST:-"1 4 16 64 256 1024 4096 16384"}
T_LIST=${T_LIST:-"1 32"}             # 1 and "a fixed thread count of your choosing"

run_sweep "$RES/sweep_shards$SHARDS" sharded:mutex "$SHARDS" $THREADS
run_sweep "$RES/sweep_coarse_ref"    coarse 1 $THREADS

for t in $T_LIST; do
    for n in $N_LIST; do
        run_sweep "$RES/shardcount/T$t/N$n" sharded:mutex "$n" "$t"
    done
done
collect_count "$RES/shardcount" sharded_mutex > "$RES/shardcount_sharded_mutex.csv"
cat "$RES/shardcount_sharded_mutex.csv"
finish
