#!/usr/bin/env bash
# perfstat.sh -- one pinned bench run under perf stat, counters per op.
#
#   bash perfstat.sh ./bench IMPL THREADS SHARDS [CPUS]
#
#   CPUS     a taskset list ("0-7", "0,1,2"); default: the first
#            THREADS cores in sweep.sh's pin order.  Give fewer CPUs
#            than THREADS to oversubscribe on purpose:
#                bash perfstat.sh ./bench sharded:tas 32 256 0-7
#
# Environment (all optional):
#   EVENTS   comma-separated perf events; default below
#   RUN_SECONDS  bench run length (default 5; longer than a sweep
#            point so the counting window dwarfs start-up and join)
#   DELAY    ms before perf starts counting (default 1500).  bench
#            prints "warm-up NNN ms" on stderr; DELAY must exceed it,
#            or the single-threaded warm-up is counted with the run.
#   MIX, WRITERS, BUCKETS pass through to bench as usual.
#
# Prints bench's own line, then one row per event: raw count, count
# per operation, and for cycles/instructions the IPC.  Events perf
# reports as <not supported> or <not counted> are shown as such;
# check `perf list` for the names your node knows.
#
# Runs:  perf stat -x, -D DELAY -e EVENTS -- taskset -c CPUS ./bench ...

prog=${1:?usage: $0 PROG IMPL THREADS SHARDS [CPUS]}
impl=${2:?}; t=${3:?}; shards=${4:?}; cpus=${5:-}
secs=${RUN_SECONDS:-5}
delay=${DELAY:-1500}
default_events=cycles,instructions,L1-dcache-loads,L1-dcache-load-misses
default_events+=,cache-misses,context-switches,cpu-migrations
events=${EVENTS:-$default_events}
sysfs=/sys/devices/system/cpu

# ---- default CPU list: sweep.sh's pin order, first t entries --------
if [ -z "$cpus" ]; then
    declare -A seen; groups=()
    for d in "$sysfs"/cpu[0-9]*; do
        sib=$(tr -d '\n' < "$d/topology/thread_siblings_list")
        [ -z "${seen[$sib]}" ] && { seen[$sib]=1; groups+=("$sib"); }
    done
    mapfile -t groups < <(printf '%s\n' "${groups[@]}" | sort -t, -k1,1n)
    order=()
    for g in "${groups[@]}"; do order+=("${g%%[,-]*}"); done
    n=$t; (( n > ${#order[@]} )) && n=${#order[@]}
    cpus=$(IFS=,; echo "${order[*]:0:$n}")
fi

tmp=$(mktemp); err=$(mktemp); trap 'rm -f "$tmp" "$err"' EXIT
echo "# perf stat -x, -D $delay -e $events -- taskset -c $cpus" \
     "$prog $impl $t $shards $secs" >&2
line=$(perf stat -x, -D "$delay" -e "$events" -o "$tmp" -- \
           taskset -c "$cpus" "$prog" "$impl" "$t" "$shards" "$secs" \
           2> "$err") ||
    { echo "perfstat: bench or perf failed" >&2; cat "$tmp" "$err" >&2
      exit 1; }
cat "$err" >&2
# bench prints "warm-up NNN ms"; counting must not start before that
warm=$(awk '/^warm-up/ {print $2}' "$err")
if [ -n "$warm" ] && [ "$warm" -ge "$delay" ]; then
    echo "perfstat: WARNING warm-up ${warm} ms >= DELAY ${delay} ms;" \
         "the counts include the warm-up.  Rerun with DELAY=$((warm*2))" >&2
fi
echo "$line"
# the ops count is the field before the word "ops" on bench's line
ops=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="ops") print $(i-1)}')
[ -z "$ops" ] &&
    { echo "perfstat: could not read ops from bench" >&2; exit 1; }

# ---- perf -x, CSV: count,unit,event,run-time,pct,...  --------------
printf '%-28s %16s %14s\n' "event" "count" "per op"
cyc=""; ins=""
while IFS=, read -r cnt unit ev rest; do
    case "$cnt" in ''|'#'*) continue ;; esac
    if [[ $cnt == "<"* ]]; then
        printf '%-28s %16s\n' "$ev" "$cnt"; continue
    fi
    per=$(awk -v a="$cnt" -v b="$ops" 'BEGIN{print a/b}')
    printf '%-28s %16s %14.4g\n' "$ev" "$cnt" "$per"
    [[ $ev == cycles* ]]       && cyc=$cnt
    [[ $ev == instructions* ]] && ins=$cnt
done < "$tmp"
if [ -n "$cyc" ] && [ -n "$ins" ] && [ "$cyc" != 0 ]; then
    printf '%-28s %31.3f\n' "IPC (instructions/cycles)" \
           "$(awk -v a="$ins" -v b="$cyc" 'BEGIN{print a/b}')"
fi
