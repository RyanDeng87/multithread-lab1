#!/bin/bash
# Generated with assistance of claude code.
#SBATCH -J lab1-p7
#SBATCH -p development
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 01:00:00
#SBATCH -o lab1-p7.%j.out
#SBATCH -A TRA25006
# Part 7: the three measurements, all pinned and median of three.
#   1. container: hashed:ttas vs sharded:ttas at ONE thread and the same
#      stripe/shard count N, BUCKETS from 2*KEYS down by 4x (>= 1024),
#      plus perf (cycles, L1 misses per op) at every bucket count.
#   2. stripes: hashed:ttas and hashed:park, stripe count L swept at T=1
#      and T=32, as Part 4 swept N.
#   3. padding: hashed:ttas vs :nopad and sharded:ttas vs :nopad across the
#      thread sweep at L=1024, then perf at 28 threads on ONE socket with
#      HITM and L1 misses (README: hashed:ttas vs hashed:ttas:nopad).
# Requires HAVE_HASHED=1.  Commit the Part 7 predictions BEFORE submitting.
#   N=4096 sbatch ../jobs/part7.slurm          (~25 min)
PART=part7
. "${SLURM_SUBMIT_DIR:-$PWD}/../jobs/lab1_common.sh"
setup_all
THREADS=${THREADS:-"1 2 4 8 16 28 40 56 84 112"}
N=${N:-4096}                                   # stripes = shards for item 1
B_LIST=${B_LIST:-"2097152 524288 131072 32768 8192 2048"}
L_LIST=${L_LIST:-"1 4 16 64 256 1024 4096 16384"}
T_LIST=${T_LIST:-"1 32"}
PAD_L=${PAD_L:-1024}
PRESENT=524288                                 # keys present: half of 2^20
# long-chain warm-ups run for seconds; start counting just after them
export DELAY_NUM=11 DELAY_DEN=10 DELAY_ADD=300

# ---- 1. container ---------------------------------------------------
for b in $B_LIST; do
    BUCKETS=$b run_sweep "$RES/buckets/B$b" hashed:ttas "$N" 1
done
run_sweep "$RES/buckets/sharded_ref" sharded:ttas "$N" 1
EVB=$(evlist cycles instructions L1-dcache-loads L1-dcache-load-misses cache-misses)
for b in $B_LIST; do
    BUCKETS=$b run_perf "$RES/buckets_perf/hashed_ttas_B$b" hashed:ttas 1 "$N" "$S0_1" "$EVB"
done
run_perf "$RES/buckets_perf/sharded_ttas_ref" sharded:ttas 1 "$N" "$S0_1" "$EVB"
# one table: B, mean chain length, sweep Mops, then the median perf row
{
    first=1
    for b in $B_LIST sharded_ref; do
        if [ "$b" = sharded_ref ]; then
            files=("$RES"/buckets_perf/sharded_ttas_ref.r*.txt); chain=NA
            mops=$(awk -F, 'NR > 1 {print $2}' "$RES/buckets/sharded_ref/sharded_ttas.csv")
        else
            files=("$RES"/buckets_perf/hashed_ttas_B$b.r*.txt)
            chain=$(awk -v p=$PRESENT -v b=$b 'BEGIN {printf "%.4g", p / b}')
            mops=$(awk -F, 'NR > 1 {print $2}' "$RES/buckets/B$b/hashed_ttas.csv")
        fi
        perf_table "${files[@]}" > "$RES/buckets_perf/$b.tsv"
        median_by_config "$RES/buckets_perf/$b.tsv" > "$RES/buckets_perf/$b.median.tsv"
        if [ $first = 1 ]; then
            head -1 "$RES/buckets_perf/$b.median.tsv" | sed 's/^/buckets\tchain\tsweep_Mops\t/'
            first=0
        fi
        tail -n +2 "$RES/buckets_perf/$b.median.tsv" | sed "s/^/$b\t$chain\t$mops\t/"
    done
} > "$RES/bucket_table.tsv"
column -t -s "$(printf '\t')" "$RES/bucket_table.tsv" 2>/dev/null | cut -c1-220

# ---- 2. stripes ------------------------------------------------------
for l in ttas park; do
    for t in $T_LIST; do
        for n in $L_LIST; do
            run_sweep "$RES/stripecount_$l/T$t/N$n" "hashed:$l" "$n" "$t"
        done
    done
    collect_count "$RES/stripecount_$l" "hashed_$l" > "$RES/stripecount_hashed_$l.csv"
    cat "$RES/stripecount_hashed_$l.csv"
done

# ---- 3. padding ------------------------------------------------------
for impl in hashed:ttas hashed:ttas:nopad sharded:ttas sharded:ttas:nopad; do
    run_sweep "$RES/padding_L$PAD_L" "$impl" "$PAD_L" $THREADS
done
unset DELAY_NUM DELAY_DEN DELAY_ADD
EVP=$(evlist cycles instructions L1-dcache-load-misses "$HITM" "$RHITM" context-switches)
mux_check "$EVP" "$S0_28"
for impl in hashed:ttas hashed:ttas:nopad sharded:ttas sharded:ttas:nopad; do
    run_perf "$RES/padding_perf/$(echo "$impl" | tr ':' '_')" "$impl" 28 "$PAD_L" "$S0_28" "$EVP"
done
perf_table "$RES"/padding_perf/*.txt > "$RES/padding_perf_all_reps.tsv"
median_by_config "$RES/padding_perf_all_reps.tsv" > "$RES/padding_perf_table.tsv"
column -t -s "$(printf '\t')" "$RES/padding_perf_table.tsv" 2>/dev/null | cut -c1-220
finish
