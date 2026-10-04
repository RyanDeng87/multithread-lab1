#!/bin/bash
# Generated with assistance of claude code.
#SBATCH -J lab1-p3u
#SBATCH -p development
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 00:30:00
#SBATCH -o lab1-p3u.%j.out
#SBATCH -A TRA25006
# Part 3 again with USER-MODE-ONLY hardware counters (':u').  Frontera has
# perf_event_paranoid=0, so part3's counters include the kernel's futex
# and scheduler work (0.5+ context switches per op at T=8), which swamps
# the map's own misses.  Report both: part3 = everything, part3u = the
# operations' own user-mode cost.  Software events (context switches,
# task-clock) are unchanged.
# Expected node time: ~4 min.
PART=part3u
. "${SLURM_SUBMIT_DIR:-$PWD}/../jobs/lab1_common.sh"
setup_all
uev() { case "$1" in ''|*/*) echo "$1" ;; *) echo "$1:u" ;; esac; }
EV3U=$(evlist cycles:u instructions:u L1-dcache-loads:u L1-dcache-load-misses:u cache-misses:u \
              "$(uev "$HITM")" "$(uev "$RHITM")" context-switches cpu-migrations task-clock)
mux_check "$EV3U" "$S0_8"
run_perf "$RES/perf/coarse_T1_S1"  coarse 1  1 "$S0_1"  "$EV3U"
run_perf "$RES/perf/coarse_T8_S1"  coarse 8  1 "$S0_8"  "$EV3U"
run_perf "$RES/perf/coarse_T28_S1" coarse 28 1 "$S0_28" "$EV3U"

perf_table "$RES"/perf/*.txt > "$RES/part3u_all_reps.tsv"
median_by_config "$RES/part3u_all_reps.tsv" > "$RES/part3u_table.tsv"
column -t -s "$(printf '\t')" "$RES/part3u_table.tsv" 2>/dev/null || cat "$RES/part3u_table.tsv"
finish
