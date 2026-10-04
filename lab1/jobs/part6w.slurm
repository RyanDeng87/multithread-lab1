#!/bin/bash
# Generated with assistance of claude code.
#SBATCH -J lab1-p6w
#SBATCH -p development
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 00:20:00
#SBATCH -o lab1-p6w.%j.out
#SBATCH -A TRA25006
# Part 6 supplement: WRITERS=n role runs for sharded:shared_mutex (part6
# ran them only for rw and rwp), so the report can show directly how
# std::shared_mutex treats a waiting writer at one shard.
#   N=4096 PARTS="part6w" sbatch ../jobs/parts.slurm        (~3 min)
PART=part6w
. "${SLURM_SUBMIT_DIR:-$PWD}/../jobs/lab1_common.sh"
setup_all
N=${N:-4096}
SH_LIST=${SH_LIST:-"1 $N"}
W_LIST=${W_LIST:-"1 4"}
TW_LIST=${TW_LIST:-"8 28 56"}
for s in $SH_LIST; do
    for w in $W_LIST; do
        WRITERS=$w run_sweep "$RES/writers${w}_shards$s" sharded:shared_mutex "$s" $TW_LIST
    done
done
roles_table "$RES"/writers*/*.raw > "$RES/writers_table.tsv"
cat "$RES/writers_table.tsv"
finish
