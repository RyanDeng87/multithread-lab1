# Generated with assistance of claude code.
# lab1_common.sh -- sourced by jobs/part{2..6}.slurm.  Submit every job FROM
# lab1/starter_files:   cd lab1/starter_files && sbatch ../jobs/part2.slurm
#
# Uses the provided bench, sweep.sh and perfstat.sh UNMODIFIED.  Everything
# here only wraps them: it records the machine, keeps every raw bench line,
# picks socket-0 CPU lists from sysfs, sets DELAY from the measured warm-up,
# and refuses to call a silent failure a result.
#
# Knobs (environment; sbatch passes your shell's environment through):
#   GCC_MODULE   module to load, e.g. gcc/13.2.0 (default: whatever `module
#                load gcc` gives; the job aborts if that g++ is older than 11)
#   REPS         perfstat repetitions per configuration (default 3)
#   RUN_SECONDS  perfstat run length (default 5, as perfstat.sh)
#   BENCH_TIMEOUT  per-bench-run kill switch in seconds (default 300)

set -u
SF=$(cd "${SLURM_SUBMIT_DIR:-$PWD}" && pwd)
if [ ! -f "$SF/sweep.sh" ] || [ ! -f "$SF/bench.cpp" ]; then
    echo "lab1_common: submit from lab1/starter_files (SLURM_SUBMIT_DIR=$SF)" >&2
    exit 2
fi
LAB=$(dirname "$SF")
PART=${PART:?set PART before sourcing}
RES=${RES:-$LAB/results/${PART}_$(date +%Y%m%d-%H%M%S)_${SLURM_JOB_ID:-nojob}}
mkdir -p "$RES/bin"
exec > >(tee -a "$RES/job.log") 2>&1
export REPS=${REPS:-3} RUN_SECONDS=${RUN_SECONDS:-5} BENCH_TIMEOUT=${BENCH_TIMEOUT:-300}
export BENCH_BIN="$SF/bench"
FAIL=0
note() { echo "[$(date +%T)] $*"; }
bad()  { echo "[$(date +%T)] ERROR: $*"; echo "$*" >> "$RES/FAILURES.txt"; FAIL=1; }

# sbatch hands the job the submitting shell's environment.  A MIX or
# WRITERS left exported from an interactive experiment would silently
# change every sweep, and a CXXFLAGS would change the build; drop them.
# (part6 sets MIX / WRITERS per call, after this.)
for v in MIX WRITERS BUCKETS DELAY EVENTS CPUS CXXFLAGS; do
    if [ -n "${!v+x}" ]; then note "ignoring inherited $v=${!v}"; unset "$v"; fi
done

# ---------------------------------------------------------------- toolchain
setup_toolchain() {
    if command -v module >/dev/null 2>&1; then
        set +u                                 # Lmod is not 'set -u' clean
        module unload xalt >/dev/null 2>&1     # xalt LD_PRELOADs into every exec
        # Frontera's default gcc module is 9.1.0, too old for atomic::wait.
        # Try GCC_MODULE if given, then every installed gcc, newest first,
        # and keep the first one whose g++ is 11 or newer.
        local m cand v
        cand="${GCC_MODULE:-} $(module -t avail gcc 2>&1 |
                 grep -E '^gcc/[0-9]' | sed 's/(.*)//' | sort -t/ -k2,2Vr)"
        for m in $cand; do
            module load "$m" >/dev/null 2>&1 || continue
            v=$(g++ -dumpversion 2>/dev/null)
            [ "${v%%.*}" -ge 11 ] 2>/dev/null && { note "module $m"; break; }
        done
        set -u
    fi
    local v; v=$(g++ -dumpversion 2>/dev/null); v=${v%%.*}
    if [ -z "$v" ] || [ "$v" -lt 11 ]; then
        bad "g++ $(g++ -dumpversion 2>&1) is too old: need >= 11 (-std=c++20," \
            "<concepts>, std::jthread, atomic::wait).  module spider gcc; GCC_MODULE=gcc/<ver>"
        exit 2
    fi
    note "compiler: $(g++ --version | head -1)"
    # sweep.sh pins with taskset to any CPU of the node; a job confined to
    # fewer CPUs (a cgroup) would make every pinned run fail.
    local allowed n_allowed
    allowed=$(taskset -pc $$ | awk '{print $NF}')
    n_allowed=$(echo "$allowed" | awk -F, '{n = 0
        for (i = 1; i <= NF; i++) { k = split($i, r, "-"); n += (k == 2 ? r[2] - r[1] + 1 : 1) }
        print n}')
    if [ "$n_allowed" -lt "$(nproc --all)" ]; then
        bad "job is confined to CPUs $allowed of $(nproc --all); sweeps need the whole node"
        exit 2
    fi
}

build() {
    # -B: the binary must match the headers being measured.  CXX forced to
    # g++ in case a loaded module exported CXX=icpc.
    ( cd "$SF" && make -B CXX=g++ bench ) > "$RES/build.txt" 2>&1 ||
        { bad "build failed, see build.txt"; exit 2; }
    grep -E '^#define HAVE_' "$SF/parts.h" | tee "$RES/parts_switches.txt"
}

provenance() {
    {
        echo "date:      $(date -Is)"
        echo "host:      $(hostname)"
        echo "job:       ${SLURM_JOB_ID:-none} partition=${SLURM_JOB_PARTITION:-?}"
        echo "kernel:    $(uname -r)"
        grep PRETTY_NAME /etc/os-release 2>/dev/null
        echo "compiler:  $(g++ --version | head -1)"
        echo "perf:      $(perf --version 2>&1)"
        echo "LD_PRELOAD=${LD_PRELOAD:-}"
        echo "job shell $(grep Cpus_allowed_list /proc/self/status)"
        echo "scaling governor cpu0: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
        echo "intel_pstate no_turbo: $(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || echo n/a)"
        echo "--- modules"; ( set +u; module list 2>&1 ) || true
        echo "--- git"; ( cd "$LAB" && git rev-parse HEAD && git status --short ) 2>&1
        echo "--- md5 (provided files must match the handout)"
        ( cd "$SF" && md5sum bench.cpp sweep.sh perfstat.sh Makefile interface.h \
                             parts.h concurrent_map.h locks.h hash_map.h )
    } > "$RES/provenance.txt" 2>&1
}

# ---------------------------------------------------------------- topology
# sweep.sh pins the first hardware thread of each core in CPU-number order
# and labels T=(cores in package 0) "first socket full" WITHOUT checking that
# those CPUs are on package 0.  Record the real map and derive socket-0 lists.
topology() {
    lscpu > "$RES/lscpu.txt" 2>&1
    command -v numactl >/dev/null && numactl -H > "$RES/numactl_H.txt" 2>&1
    local d c sib
    for d in /sys/devices/system/cpu/cpu[0-9]*; do
        c=${d##*cpu}
        sib=$(cat "$d/topology/thread_siblings_list"); sib=${sib%%[,-]*}
        [ "$sib" = "$c" ] || continue           # first hw thread of each core only
        echo "$c $(cat "$d/topology/physical_package_id")"
    done | sort -n > "$RES/cpu_socket_map.txt"
    S0_LIST=$(awk '$2==0 {printf "%s%s", s, $1; s=","}' "$RES/cpu_socket_map.txt")
    S0_1=$(echo "$S0_LIST" | cut -d, -f1)
    S0_8=$(echo "$S0_LIST" | cut -d, -f1-8)
    S0_28=$(echo "$S0_LIST" | cut -d, -f1-28)
    NS0=$(awk '$2==0' "$RES/cpu_socket_map.txt" | wc -l)
    local wrong; wrong=$(head -n "$NS0" "$RES/cpu_socket_map.txt" | awk '$2!=0' | wc -l)
    if [ "$wrong" -eq 0 ]; then LAYOUT=contiguous; else LAYOUT=interleaved; fi
    {
        echo "layout:        $LAYOUT"
        echo "cores:         $(wc -l < "$RES/cpu_socket_map.txt")   cores in package 0: $NS0"
        echo "socket-0 CPUs: $S0_LIST"
        echo "S0_1=$S0_1  S0_8=$S0_8"
        echo "S0_28=$S0_28"
        if [ "$LAYOUT" = interleaved ]; then
            echo "WARNING: CPU numbers alternate between sockets.  sweep.sh's pin order"
            echo "  is CPU-number order, so from T=2 its threads span BOTH sockets and its"
            echo "  '<- first socket full' tag at T=$NS0 is wrong.  Say so in the report;"
            echo "  the perf runs in these jobs use the socket-0 lists above instead of 0-7."
        fi
    } | tee "$RES/topology.txt"
}

# ---------------------------------------------------------------- perf checks
perf_checks() {
    local f="$RES/perf_checks.txt"
    {
        echo "perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid)"
        echo "--- perf stat -e cycles true";        perf stat -x, -e cycles true 2>&1
        echo "--- -D honoured?";                    perf stat -x, -D 100 -e task-clock -- sleep 0.3 2>&1
        echo "--- context switches visible? (5 sleeps => >= 5)"
        perf stat -x, -e context-switches -- bash -c 'for i in 1 2 3 4 5; do sleep 0.02; done' 2>&1
        echo "--- HITM events known to this perf"
        perf list 2>/dev/null | grep -i -E 'xsnp_hitm|remote_hitm'
    } > "$f" 2>&1
    local cs
    cs=$(perf stat -x, -e context-switches -- bash -c 'for i in 1 2 3 4 5; do sleep 0.02; done' 2>&1 |
         awk -F, '/context-switches/ {print $1}')
    CS_FALLBACK=0
    if [ "${cs:-0}" = 0 ]; then
        CS_FALLBACK=1
        note "perf counts 0 context switches for a sleeping program (paranoid>=2 -> ':u')."
        note "  perfstat runs go through bin/benchru, which adds kernel rusage counts."
    fi
    HITM=mem_load_l3_hit_retired.xsnp_hitm
    RHITM=mem_load_l3_miss_retired.remote_hitm
    if ! perf list 2>/dev/null | grep -q -i "$HITM"; then
        if grep -q GenuineIntel /proc/cpuinfo; then
            # SKX/CLX encodings (EventSel D2/D3, umask 04) -- confirm against
            # `perf list -v` or the SDM before trusting them.  name= keeps the
            # event label comma-free so perfstat.sh's CSV parsing survives.
            HITM='cpu/event=0xd2,umask=0x04,name=xsnp_hitm/'
            RHITM='cpu/event=0xd3,umask=0x04,name=remote_hitm/'
            note "perf does not know the HITM names; using raw encodings (verify!)"
        else
            HITM=""; RHITM=""
            note "not an Intel CPU: HITM events dropped (dry run only)"
        fi
    fi
    # ref-cycles (Intel fixed counter: unhalted cycles at the constant TSC
    # rate, 2.7 GHz on an 8280) gives the busy fraction without knowing what
    # turbo clock the cores ran at.
    REFCYC=""
    perf stat -x, -e ref-cycles true 2>&1 | grep -q '^[0-9]' && REFCYC=ref-cycles
    note "perf: paranoid=$(cat /proc/sys/kernel/perf_event_paranoid) CS_FALLBACK=$CS_FALLBACK HITM=${HITM:-none} REFCYC=${REFCYC:-none}"
}

# events list without empty entries (HITM may be empty off-Intel)
evlist() { local IFS=,; local out="" e; for e in "$@"; do [ -n "$e" ] && out+="${out:+,}$e"; done; echo "$out"; }

# One run with the event set under perf -x: field 5 is the percentage of
# the run each event was really counted; below 100 it was multiplexed and
# SCALED -- perfstat.sh discards that field, so check it here.
MUXN=0
mux_check() {   # mux_check EVENTS CPUS  -> mux_check_<k>.txt
    local ev=$1 cpus=$2 n f
    MUXN=$((MUXN + 1)); f="$RES/mux_check_$MUXN.txt"
    ( cd "$SF" && perf stat -x, -e "$ev" -- taskset -c "$cpus" ./bench coarse 8 1 1 ) > "$f" 2>&1
    n=$(awk -F, 'NF>=5 && $5 != "" && $5+0 < 99.5' "$f" | wc -l)
    if [ "$n" -gt 0 ]; then
        bad "event set is multiplexed ($n events < 100% enabled): $ev -- split it (see $f)"
    else
        note "mux check: every event counted 100% of the time"
    fi
}

# ---------------------------------------------------------------- wrappers
make_wrappers() {
    # benchlog: what sweep.sh runs.  Same args, env and affinity as bench;
    # bench's own line is appended verbatim to $BENCH_RAW and echoed back so
    # sweep.sh parses it exactly as before.
    cat > "$RES/bin/benchlog" <<'EOF'
#!/usr/bin/env bash
: "${BENCH_RAW:?}" "${BENCH_BIN:?}"
e=$(mktemp)
o=$(timeout "${BENCH_TIMEOUT:-300}" "$BENCH_BIN" "$@" 2>"$e"); rc=$?
printf '%s\n' "$o" >> "$BENCH_RAW"
printf 'rc=%s cpus=%s args=[%s] MIX=%s WRITERS=%s BUCKETS=%s stderr=[%s]\n' \
    "$rc" "$(taskset -pc $$ | awk '{print $NF}')" "$*" "${MIX:-}" \
    "${WRITERS:-}" "${BUCKETS:-}" "$(tr '\n' ' ' < "$e")" >> "$BENCH_RAW.meta"
rm -f "$e"
printf '%s\n' "$o"
exit "$rc"
EOF
    # benchru: what perfstat.sh runs when perf cannot see context switches.
    # Runs bench as a child and adds the kernel's per-process counts (all
    # threads, whole run including the warm-up) to stderr, which
    # perfstat.sh copies into its output.  Compiled, so it needs nothing
    # beyond the g++ the job already checked.
    cat > "$RES/bin/benchru.cpp" <<'CPP'
#include <cstdio>
#include <cstdlib>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
int main(int, char** argv)
{
    const char* bin = std::getenv("BENCH_BIN");
    if (!bin) return 2;
    pid_t p = fork();
    if (p == 0) { argv[0] = const_cast<char*>(bin); execv(bin, argv); _exit(127); }
    int st = 0;
    waitpid(p, &st, 0);
    rusage r{};
    getrusage(RUSAGE_CHILDREN, &r);
    std::fprintf(stderr, "rusage: voluntary_cs=%ld involuntary_cs=%ld user_s=%.2f sys_s=%.2f\n",
                 r.ru_nvcsw, r.ru_nivcsw,
                 r.ru_utime.tv_sec + r.ru_utime.tv_usec / 1e6,
                 r.ru_stime.tv_sec + r.ru_stime.tv_usec / 1e6);
    return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
}
CPP
    g++ -O2 -o "$RES/bin/benchru" "$RES/bin/benchru.cpp" ||
        { bad "could not build bin/benchru"; exit 2; }
    chmod +x "$RES/bin/benchlog"
}

# ---------------------------------------------------------------- sweeps
# run_sweep DIR IMPL SHARDS T...  -- one sweep.sh call; MIX/WRITERS/BUCKETS
# come from the caller's environment (MIX=50/25/25 run_sweep ...).
# Output: DIR/<impl with : -> _>.csv (make sweep's name), .log (sweep.sh
# stderr: pin order, socket boundary, the three runs per point), .raw (every
# bench line as printed), .raw.meta (rc, affinity, env, warm-up per run).
run_sweep() {
    local dir=$1 impl=$2 shards=$3; shift 3
    local name; name=$(echo "$impl" | tr ':' '_')
    mkdir -p "$dir"
    note "sweep $impl shards=$shards MIX=${MIX:-} WRITERS=${WRITERS:-} BUCKETS=${BUCKETS:-} T=[$*]"
    ( cd "$SF" && BENCH_RAW="$dir/$name.raw" \
          bash "${SWEEP_SH:-sweep.sh}" "$RES/bin/benchlog" "$impl" "$shards" "$@" \
          > "$dir/$name.csv" 2> "$dir/$name.log" )
    # sweep.sh exits 0 and writes an empty mops field when bench fails, and
    # takes the "median" of fewer than three numbers when one run fails.
    local got; got=$(awk -F, 'NR>1 && $2 != ""' "$dir/$name.csv" | wc -l)
    [ "$got" -eq $# ] || bad "$dir/$name.csv: $got of $# points have a value"
    if grep -q -v '^rc=0 ' "$dir/$name.raw.meta" 2>/dev/null; then
        bad "$dir/$name.raw.meta: a bench run failed or hit BENCH_TIMEOUT"
    fi
}

# ---------------------------------------------------------------- perf runs
# run_perf OUTBASE IMPL T SHARDS CPUS EVENTS  -> OUTBASE.r<k>.txt (perfstat
# stdout+stderr, verbatim) for k=1..REPS.
# perfstat counts from DELAY ms after start but divides by ALL operations
# of the timed run (bench's "NNNN ms"), so every per-op figure is scaled by
#   f = (run_ms + warm-up - DELAY) / run_ms
# (0.72 with the default DELAY=1500, a 5 s run and a 100 ms warm-up).
# Start counting shortly after this configuration's measured warm-up instead
# (f ~ 0.95), and let perf_table print f next to every row.
run_perf() {
    local out=$1 impl=$2 t=$3 shards=$4 cpus=$5 ev=$6
    local first=${cpus%%[,-]*} warm delay r prog=./bench
    [ "${CS_FALLBACK:-0}" = 1 ] && prog="$RES/bin/benchru"
    mkdir -p "$(dirname "$out")"
    warm=$(cd "$SF" && timeout "$BENCH_TIMEOUT" taskset -c "$first" ./bench "$impl" 1 "$shards" 1 \
               2>&1 >/dev/null | awk '/^warm-up/ {print $2}')
    delay=$(( ${warm:-1000} * 3 / 2 + 200 ))
    for r in $(seq 1 "$REPS"); do
        note "perf $impl T=$t shards=$shards cpus=$cpus DELAY=$delay rep $r"
        ( cd "$SF" && DELAY=$delay EVENTS=$ev timeout $(( BENCH_TIMEOUT + 60 )) \
              bash perfstat.sh "$prog" "$impl" "$t" "$shards" "$cpus" ) \
            > "$out.r$r.txt" 2>&1 || bad "perfstat failed: $out.r$r.txt"
        if grep -q '^perfstat: WARNING warm-up' "$out.r$r.txt"; then
            # warm-up ran longer than the probe said: keep the evidence, redo
            mv "$out.r$r.txt" "$out.r$r.txt.warmup_counted"
            warm=$(awk '/^warm-up/ {print $2}' "$out.r$r.txt.warmup_counted")
            delay=$(( warm * 3 / 2 + 200 ))
            note "  warm-up ${warm} ms overlapped the count; rerun with DELAY=$delay"
            ( cd "$SF" && DELAY=$delay EVENTS=$ev timeout $(( BENCH_TIMEOUT + 60 )) \
                  bash perfstat.sh "$prog" "$impl" "$t" "$shards" "$cpus" ) \
                > "$out.r$r.txt" 2>&1 || bad "perfstat failed: $out.r$r.txt"
        fi
        grep -q '<not counted>\|<not supported>' "$out.r$r.txt" &&
            bad "$out.r$r.txt: an event was not counted"
    done
}

# perf_table FILES... -> TSV, one row per perfstat output, per-op columns as
# perfstat printed them plus the window factor f.  Divide per-op by f to
# correct.  Mops is recomputed as ops/ms (bench prints one decimal, which is
# no precision at all for an oversubscribed lock at 0.1 Mops/s).
# busy = cyc/op / f * Mops*1e6 / (ncpus * CLK_GHZ*1e9), the README's busy
# fraction (needs CLK_GHZ); busy_ref = the same with ref-cycles and the TSC
# rate TSC_GHZ (2.7 on an 8280), independent of turbo; taskclk_cpus = CPUs'
# worth of on-CPU time (user+kernel) during the counted window.
perf_table() {
    awk -v clk="${CLK_GHZ:-0}" -v tsc="${TSC_GHZ:-2.7}" '
    function ncpu(l,   a, n, i, b, c) { n = split(l, a, ","); c = 0
        for (i = 1; i <= n; i++) if (split(a[i], b, "-") == 2) c += b[2] - b[1] + 1; else c++
        return c }
    function emit(   f, w, busy, bref, tc, flag, mops) {
        if (impl == "") return
        mops = (ms > 0) ? ops / ms / 1000 : 0
        w = ms + warm - delay; flag = "ok"
        if (warm >= delay) { flag = "WARMUP_COUNTED"; w = ms }
        f = (ms > 0) ? w / ms : 0
        busy = (clk > 0 && f > 0) ? per["cycles"] / f * mops * 1e6 / (ncpu(cpus) * clk * 1e9) : ""
        bref = (per["ref-cycles"] != "" && f > 0) ? per["ref-cycles"] / f * mops * 1e6 / (ncpu(cpus) * tsc * 1e9) : ""
        tc = (w > 0 && cnt["task-clock"] != "") ? cnt["task-clock"] / w : ""
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.4g\t%d\t%.3f", fname, flag, impl, T, sh, mix, cpus, mops, ops, f
        printf "\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", per["cycles"], per["instructions"], \
               (cnt["cycles"] > 0 ? sprintf("%.3f", cnt["instructions"] / cnt["cycles"]) : ""), \
               per["L1-dcache-load-misses"], per["cache-misses"], per["xsnp_hitm"], \
               per["remote_hitm"], per["context-switches"]
        printf "\t%s\t%s\t%s\t%s\n", (ru != "" && ops > 0) ? sprintf("%.4g", ru / ops) : "", \
               (busy == "" ? "" : sprintf("%.2f", busy)), (bref == "" ? "" : sprintf("%.2f", bref)), \
               (tc == "" ? "" : sprintf("%.2f", tc))
        impl = ""; ru = ""; delete per; delete cnt }
    FNR == 1 { emit(); fname = FILENAME; warm = 0; delay = 0; ms = 0; cpus = "" }
    /^# perf stat/ { for (i = 1; i <= NF; i++) { if ($i == "-D") delay = $(i+1); if ($i == "-c") cpus = $(i+1) } }
    /^warm-up/     { warm = $2 }
    /^rusage:/     { for (i = 2; i <= NF; i++) { split($i, kv, "="); if (kv[1] ~ /_cs$/) ru += kv[2] } }
    / Mops\/s$/    { for (i = 1; i <= NF; i++) { if ($i == "ops") ops = $(i-1); if ($i == "ms") ms = $(i-1) }
                     impl = $1; T = $2; sub(/^T=/, "", T); sh = $3; sub(/^shards=/, "", sh)
                     mix = $4; sub(/^mix=/, "", mix) }
    NF == 3 && $2 ~ /^[0-9.]+$/ {
        n = $1; sub(/:u$/, "", n); sub(/^.*xsnp_hitm.*$/, "xsnp_hitm", n); sub(/^.*remote_hitm.*$/, "remote_hitm", n)
        cnt[n] = $2; per[n] = $3 }
    END { emit() }' "$@" |
    { printf 'file\tflag\timpl\tT\tshards\tmix\tcpus\tMops\tops\tf\tcyc/op\tins/op\tIPC\tL1miss/op\tLLCmiss/op\tHITM/op\trHITM/op\tcs/op(perf)\tcs/op(rusage)\tbusy\tbusy_ref\ttaskclk_cpus\n'; cat; }
}

# median_by_config TSV -> for each (impl,T,shards,mix,cpus) the row whose
# Mops is the median of its reps, plus the Mops min..max spread.
median_by_config() {
    awk -F'\t' 'NR == 1 { print $0 "\tMops_min\tMops_max\treps"; next }
    { k = $3 FS $4 FS $5 FS $6 FS $7; n[k]++; row[k, n[k]] = $0; m[k, n[k]] = $8 + 0
      if (!(k in order)) { order[k] = ++nk; keys[nk] = k } }
    END { for (j = 1; j <= nk; j++) { k = keys[j]; c = n[k]; lo = 1e300; hi = -1
            for (i = 1; i <= c; i++) { if (m[k,i] < lo) lo = m[k,i]; if (m[k,i] > hi) hi = m[k,i] }
            best = 1
            for (i = 1; i <= c; i++) { below = 0; above = 0
                for (q = 1; q <= c; q++) { if (m[k,q] < m[k,i]) below++; if (m[k,q] > m[k,i]) above++ }
                if (below <= int(c/2) && above <= int(c/2)) { best = i; break } }
            print row[k, best] "\t" lo "\t" hi "\t" c } }' "$1"
}

# collect_count ROOT NAME -> threads,count,mops,cpus from ROOT/T*/N*/NAME.csv
collect_count() {
    local root=$1 name=$2 f n
    echo "threads,count,mops,cpus"
    for f in "$root"/T*/N*/"$name.csv"; do
        [ -f "$f" ] || continue
        n=$(basename "$(dirname "$f")"); n=${n#N}
        awk -F, -v n="$n" 'NR > 1 { rest = $0; sub(/^[^,]*,[^,]*,/, "", rest)
                                     print $1 "," n "," $2 "," rest }' "$f"
    done | sort -t, -k1,1n -k2,2n
}

# roles_table DIR... -> per point, the WRITERS=n split (rd, wr, total) of the
# run whose total is sweep.sh's median, from the .raw logs.
roles_table() {
    printf 'file\timpl\tT\tshards\trd_Mops\twr_Mops\ttotal_Mops\n'
    local f
    for f in "$@"; do
        awk -v file="$f" '/mix=roles/ {
              T = $2; sub(/^T=/, "", T); sh = $3; sub(/^shards=/, "", sh)
              rd = $5; sub(/^rd=/, "", rd); wr = $6; sub(/^wr=/, "", wr)
              k = $1 FS T FS sh; n[k]++; tot[k, n[k]] = $(NF-1); r[k, n[k]] = rd; w[k, n[k]] = wr
              if (n[k] == 1) keys[++nk] = k }
            END { for (j = 1; j <= nk; j++) { k = keys[j]; c = n[k]; best = 1
                    for (i = 1; i <= c; i++) { below = 0; above = 0
                        for (q = 1; q <= c; q++) { if (tot[k,q]+0 < tot[k,i]+0) below++; if (tot[k,q]+0 > tot[k,i]+0) above++ }
                        if (below <= int(c/2) && above <= int(c/2)) { best = i; break } }
                    split(k, p, FS)
                    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", file, p[1], p[2], p[3], r[k,best], w[k,best], tot[k,best] } }' "$f"
    done
}

setup_all() {
    note "results -> $RES"
    setup_toolchain
    build
    provenance
    topology
    perf_checks
    make_wrappers
}

finish() {
    if [ "$FAIL" -ne 0 ]; then
        note "FINISHED WITH ERRORS -- see $RES/FAILURES.txt"
    else
        note "finished cleanly; artifacts in $RES"
    fi
}
