#!/bin/bash
# Generated with assistance of claude code.
#SBATCH -J lab1-p6
#SBATCH -p development
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 01:45:00
#SBATCH -o lab1-p6.%j.out
#SBATCH -A TRA25006
# Part 6: ttas / rw / rwp / shared_mutex x three mixes x two shard counts
# (each a pinned, median-of-3 thread sweep), then the WRITERS=n role runs.
# Requires HAVE_LOCKS=1 and HAVE_RW=1.
#   N=<your shard count> sbatch ../jobs/part6.slurm
# Expected node time: ~35-45 min; if it gets tight, SH_LIST="$N" and
# SH_LIST=1 as two jobs (but then the two halves come from different nodes).
PART=part6
. "${SLURM_SUBMIT_DIR:-$PWD}/../jobs/lab1_common.sh"
setup_all
N=${N:-256}
SH_LIST=${SH_LIST:-"$N 1"}
THREADS=${THREADS:-"1 2 4 8 16 28 40 56 84 112"}
MIXES=${MIXES:-"80/10/10 50/25/25 100/0/0"}
LOCKS6="ttas rw rwp shared_mutex"

for s in $SH_LIST; do
    for m in $MIXES; do
        for l in $LOCKS6; do
            # the directory carries what the CSV cannot: mix and shard count
            MIX=$m run_sweep "$RES/mix$(echo "$m" | tr / -)_shards$s" "sharded:$l" "$s" $THREADS
        done
    done
done

# WRITERS=n: n pure writers, T-n pure readers, MIX ignored.  sweep.sh keeps
# only the TOTAL Mops in its CSV (and still prints mix=80/10/10 in its
# header); the rd/wr split survives only in the .raw bench lines.
W_LIST=${W_LIST:-"1 4"}
TW_LIST=${TW_LIST:-"8 28 56"}
for s in $SH_LIST; do
    for w in $W_LIST; do
        for l in rw rwp; do
            WRITERS=$w run_sweep "$RES/writers${w}_shards$s" "sharded:$l" "$s" $TW_LIST
        done
    done
done
roles_table "$RES"/writers*/*.raw > "$RES/writers_table.tsv"
cat "$RES/writers_table.tsv"
finish
