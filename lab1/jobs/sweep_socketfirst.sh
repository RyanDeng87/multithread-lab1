#!/usr/bin/env bash
# Generated with assistance of claude code.
# sweep_socketfirst.sh -- SUPPLEMENTARY copy of the provided sweep.sh.
# Identical except for the lines marked CHANGED: cores are ordered by
# socket, then CPU number, so socket 0 really fills before socket 1.
# On Frontera's CLX nodes the CPU numbers alternate between sockets
# (NUMA node0 = 0,2,4,...), so the provided sweep.sh's CPU-number order
# spans both sockets from T=2 on.  The provided sweep.sh stays the
# protocol run; this one shows what happens at the real socket boundary.
#
# (original header follows)
# sweep.sh -- throughput vs thread count for the Lab 1 bench, pinned.
#
#   bash sweep.sh ./bench IMPL SHARDS T1 T2 T3 ...  > out.csv
#
# IMPL is any bench implementation string (coarse, sharded:ttas,
# hashed:rw:nopad, ...).  MIX, WRITERS and BUCKETS pass through the
# environment to bench unchanged:
#
#   MIX=50/25/25 bash sweep.sh ./bench sharded:rw 256 1 2 4 8 > x.csv
#
# Threads are pinned one per physical core, in CPU-number order, so
# the first socket fills before the second (the socket boundary is
# printed).  On a machine with SMT the sibling hardware threads come
# last; the TACC nodes have SMT disabled, so there the core count and
# the hardware-thread count coincide and T > cores is oversubscribed.
# Each point is the median of three runs.  CSV on stdout:
# threads,mops,cpus; progress on stderr.
#
# Runs bench as:  taskset -c <cpus> ./bench IMPL T SHARDS
# and reads the Mops/s figure from its output line.

prog=${1:?usage: $0 PROG IMPL SHARDS T...}
impl=${2:?}; shards=${3:?}; shift 3
threads=("$@")
[ ${#threads[@]} -eq 0 ] && threads=(1 2 4 8 16 32 64 128)
sysfs=${SWEEP_SYSFS:-/sys/devices/system/cpu}   # CHANGED: overridable for testing

# ---- pin order: first sibling of every core, then second siblings ---
declare -A seen; groups=()
for d in "$sysfs"/cpu[0-9]*; do
    sib=$(tr -d '\n' < "$d/topology/thread_siblings_list")
    [ -z "${seen[$sib]}" ] && { seen[$sib]=1; groups+=("$sib"); }
done
# CHANGED: socket-major order (package id of the core's first CPU, then
# that CPU's number) instead of CPU-number order.
mapfile -t groups < <(for g in "${groups[@]}"; do f=${g%%[,-]*}
    echo "$(cat "$sysfs/cpu$f/topology/physical_package_id") $f $g"
    done | sort -k1,1n -k2,2n | awk '{print $3}')
expand() { local p; IFS=, read -ra ps <<< "$1"
    for p in "${ps[@]}"; do
        if [[ $p == *-* ]]; then seq -s ' ' "${p%-*}" "${p#*-}"
        else printf '%s ' "$p"; fi; done; }
order=(); maxw=0
for g in "${groups[@]}"; do read -ra e <<< "$(expand "$g")"
    (( ${#e[@]} > maxw )) && maxw=${#e[@]}; done
for (( w=0; w<maxw; w++ )); do for g in "${groups[@]}"; do
    read -ra e <<< "$(expand "$g")"
    [ -n "${e[$w]:-}" ] && order+=("${e[$w]}"); done; done
ncpu=${#order[@]}; ncore=${#groups[@]}
# ---- socket boundary: cores whose first CPU is in package 0 --------
nsock=$(cat "$sysfs"/cpu[0-9]*/topology/physical_package_id | sort -u | wc -l)
csock=0
for g in "${groups[@]}"; do
    f=${g%%[,-]*}
    [ "$(cat "$sysfs/cpu$f/topology/physical_package_id")" = "0" ] && ((csock++))
done

median3() {
    printf '%s\n' "$@" | sort -n | sed -n "$(( ($# + 1) / 2 ))p"
}

echo "# $prog $impl shards=$shards mix=${MIX:-80/10/10}" \
     "writers=${WRITERS:-0}" >&2
echo "# cores=$ncore hwthreads=$ncpu sockets=$nsock" \
     "cores/socket=$csock pin order: ${order[*]}" >&2
echo "threads,mops,cpus"
for t in "${threads[@]}"; do
    if (( t > ncpu )); then
        cpus=$(IFS=,; echo "${order[*]}")      # oversubscribed: all
    else
        cpus=$(IFS=,; echo "${order[*]:0:$t}")
    fi
    m=()
    for r in 1 2 3; do
        line=$(taskset -c "$cpus" "$prog" "$impl" "$t" "$shards" 2>/dev/null)
        m+=( "$(echo "$line" | awk '{print $(NF-1)}')" )
    done
    med=$(median3 "${m[@]}")
    tag=""
    (( nsock > 1 && t == csock )) && tag="  <- first socket full"
    (( t == ncore )) && tag="  <- every core busy"
    (( t == ncpu && ncpu != ncore )) && tag="  <- every hw thread busy"
    (( t > ncpu )) && tag="  <- oversubscribed"
    printf '%d,%s,"%s"\n' "$t" "$med" "$cpus"
    printf 'T=%-4d %8s Mops/s  (%s)%s\n' "$t" "$med" "${m[*]}" "$tag" >&2
done
