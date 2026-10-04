#!/bin/bash
# Generated with assistance of claude code.
#SBATCH -J lab1-p3
#SBATCH -p development
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 00:30:00
#SBATCH -o lab1-p3.%j.out
#SBATCH -A TRA25006
# Part 3: coarse map under perf stat at T=1, 8, 28, all on socket 0.
# README: make perf IMPL=coarse T={1,8,28} SHARDS=1 with xsnp_hitm added.
# EVENTS *replaces* perfstat's default list, so every wanted event is listed.
# Expected node time: ~4 min (3 configs x REPS=3 x ~7 s + warm-up probes).
PART=part3
. "${SLURM_SUBMIT_DIR:-$PWD}/../jobs/lab1_common.sh"
setup_all

# remote_hitm should be ~0 on one socket: it is the check that the CPUs
# really are one socket.  task-clock gives the counted window's CPU time.
EV3=$(evlist cycles instructions L1-dcache-loads L1-dcache-load-misses cache-misses \
             "$HITM" "$RHITM" context-switches cpu-migrations task-clock)
mux_check "$EV3" "$S0_8"
run_perf "$RES/perf/coarse_T1_S1"  coarse 1  1 "$S0_1"  "$EV3"
run_perf "$RES/perf/coarse_T8_S1"  coarse 8  1 "$S0_8"  "$EV3"
run_perf "$RES/perf/coarse_T28_S1" coarse 28 1 "$S0_28" "$EV3"

perf_table "$RES"/perf/*.txt > "$RES/part3_all_reps.tsv"
median_by_config "$RES/part3_all_reps.tsv" > "$RES/part3_table.tsv"
column -t -s "$(printf '\t')" "$RES/part3_table.tsv" 2>/dev/null || cat "$RES/part3_table.tsv"
finish
