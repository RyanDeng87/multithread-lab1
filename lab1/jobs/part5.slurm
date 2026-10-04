#!/bin/bash
# Generated with assistance of claude code.
#SBATCH -J lab1-p5
#SBATCH -p development
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 01:15:00
#SBATCH -o lab1-p5.%j.out
#SBATCH -A TRA25006
# Part 5: five-lock sweep at your shard count, the one-shard 8-on-8 counter
# table, the 32-on-8 oversubscription table with the busy fraction, and the
# shard-count redo for ttas and park.  Requires HAVE_LOCKS=1.
#   N=<your Part 4 choice> sbatch ../jobs/part5.slurm
# Expected node time: ~20-30 min (oversubscribed spinning points overshoot).
PART=part5
. "${SLURM_SUBMIT_DIR:-$PWD}/../jobs/lab1_common.sh"
setup_all
THREADS=${THREADS:-"1 2 4 8 16 28 40 56 84 112"}
N=${N:-256}
N_LIST=${N_LIST:-"1 4 16 64 256 1024 4096 16384"}
T_LIST=${T_LIST:-"1 32"}
LOCKS="mutex tas ttas ticket park"

for l in $LOCKS; do
    run_sweep "$RES/sweep_shards$N" "sharded:$l" "$N" $THREADS
done

# Table 1: one shard, 8 threads on 8 cores of ONE socket (README: CPUS=0-7,
# which is one socket only if CPUs are numbered socket by socket).
EV5A=$(evlist cycles instructions L1-dcache-load-misses "$HITM" "$RHITM" \
              context-switches task-clock)
mux_check "$EV5A" "$S0_8"
for l in $LOCKS; do
    run_perf "$RES/perf_1shard_8on8/sharded_$l" "sharded:$l" 8 1 "$S0_8" "$EV5A"
done

# Effective clock for the busy fraction: 8 spinning threads on the same 8
# cores, no syscalls, so cycles / task-clock = the clock those cores ran at.
run_perf "$RES/clock/sharded_tas_8on8" sharded:tas 8 "$N" "$S0_8" "$(evlist cycles instructions task-clock "$REFCYC")"
CLK_GHZ=$(awk '/^cycles/ {c = $2} /^task-clock/ {t = $2} END {if (t > 0) printf "%.3f", c / (t * 1e6)}' \
          "$RES/clock/sharded_tas_8on8.r1.txt")
note "effective clock with 8 busy cores: ${CLK_GHZ:-?} GHz (nominal 2.7)"
export CLK_GHZ

# Table 2: 32 threads on those 8 cores.  The README uses perfstat's default
# events; EVENTS replaces them, so they are spelled out, plus task-clock
# and (Intel) ref-cycles for a turbo-independent busy fraction.
EV5B=$(evlist cycles instructions L1-dcache-loads L1-dcache-load-misses cache-misses \
              context-switches cpu-migrations task-clock "$REFCYC")
mux_check "$EV5B" "$S0_8"
for l in $LOCKS; do
    run_perf "$RES/perf_32on8/sharded_$l" "sharded:$l" 32 "$N" "$S0_8" "$EV5B"
done

for p in perf_1shard_8on8 perf_32on8; do
    perf_table "$RES/$p"/*.txt > "$RES/${p}_all_reps.tsv"
    median_by_config "$RES/${p}_all_reps.tsv" > "$RES/${p}_table.tsv"
done

# Shard-count redo with ttas and park
for l in ttas park; do
    for t in $T_LIST; do
        for n in $N_LIST; do
            run_sweep "$RES/shardcount_$l/T$t/N$n" "sharded:$l" "$n" "$t"
        done
    done
    collect_count "$RES/shardcount_$l" "sharded_$l" > "$RES/shardcount_sharded_$l.csv"
done
finish
