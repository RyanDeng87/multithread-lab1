#!/bin/bash
# Generated with assistance of claude code.
#SBATCH -J lab1-tsan
#SBATCH -p development
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -t 01:30:00
#SBATCH -o lab1-tsan.%j.out
#SBATCH -A TRA25006
# make test + make tsan on a Lonestar6 COMPUTE node (TSan cannot run on
# Frontera; a long TSan run on a login node gets killed by the admins).
# Submit from lab1/starter_files on LS6:  sbatch ../jobs/ls6_tsan.slurm
#
# The two TSan programs are run separately (make tsan stops at the first
# failure), each under its own timeout, line-buffered so a hang still shows
# which test it was in.  A clean TSan run prints NO "SUMMARY:" line; the
# evidence kept for the report is listed at the bottom (tsan_summary.txt).
set -u
SF=$(cd "${SLURM_SUBMIT_DIR:-$PWD}" && pwd)
[ -f "$SF/Makefile" ] || { echo "submit from lab1/starter_files" >&2; exit 2; }
OUT=$(dirname "$SF")/results/tsan_ls6_$(date +%Y%m%d-%H%M%S)_${SLURM_JOB_ID:-nojob}
mkdir -p "$OUT"
exec > >(tee -a "$OUT/job.log") 2>&1
TSAN_TIMEOUT=${TSAN_TIMEOUT:-600}     # 5 runs x 10 min fits the 1:30 limit

if command -v module >/dev/null 2>&1; then
    set +u                                   # Lmod is not 'set -u' clean
    module unload xalt >/dev/null 2>&1       # xalt LD_PRELOADs a library into every exec
    for m in ${GCC_MODULE:-} $(module -t avail gcc 2>&1 |
             grep -E '^gcc/[0-9]' | sed 's/(.*)//' | sort -t/ -k2,2Vr); do
        module load "$m" >/dev/null 2>&1 || continue
        v=$(g++ -dumpversion 2>/dev/null)
        [ "${v%%.*}" -ge 11 ] 2>/dev/null && break
    done
    set -u
fi
v=$(g++ -dumpversion); [ "${v%%.*}" -ge 11 ] || { echo "g++ $v < 11" >&2; exit 2; }
{
    date -Is; hostname; uname -r; g++ --version | head -1
    echo "LD_PRELOAD=${LD_PRELOAD:-}"
    grep -E '^#define HAVE_' "$SF/parts.h"
    ( cd "$SF" && md5sum interface.h parts.h concurrent_map.h locks.h hash_map.h ../tests/*.cpp )
} > "$OUT/provenance.txt" 2>&1
if grep -E '^#define HAVE_' "$SF/parts.h" | grep -q -v ' 1 '; then
    echo "WARNING: not every parts.h switch is 1 -- staff grade with all of them on"
fi

cd "$SF" || exit 2
make -B CXX=g++ test_map test_locks test_map_tsan test_locks_tsan > "$OUT/build.txt" 2>&1 ||
    { echo "build failed (build.txt)"; exit 1; }
ldd ./test_locks_tsan | grep -i tsan > "$OUT/ldd_tsan.txt"

# Positive control: the same flags must REPORT a race on this node, or a
# silent run proves nothing.
cat > "$OUT/race.cpp" <<'EOF'
#include <thread>
long x = 0;
int main() { std::thread a([] { for (int i = 0; i < 100000; ++i) ++x; });
             for (int i = 0; i < 100000; ++i) ++x; a.join(); return x == 0; }
EOF
g++ -std=c++20 -O1 -g -fsanitize=thread -pthread "$OUT/race.cpp" -o "$OUT/race_tsan"

run() {   # run NAME CMD... ; plain or TSan, line-buffered, timed, kept
    local name=$1; shift
    local t0=$SECONDS
    timeout "$TSAN_TIMEOUT" stdbuf -oL "$@" > "$OUT/$name.stdout" 2> "$OUT/$name.stderr"
    local rc=$?
    echo "$name: exit=$rc  wall=$((SECONDS - t0)) s" | tee -a "$OUT/exit_codes.txt"
}
# setarch -R: no ASLR, which avoids TSan's "unexpected memory mapping" on
# kernels with high mmap randomisation; harmless where not needed.
NOASLR="setarch $(uname -m) -R"
run test_map         ./test_map
run test_locks       ./test_locks
TSAN_OPTIONS="halt_on_error=1 verbosity=1" run test_map_tsan   $NOASLR ./test_map_tsan
TSAN_OPTIONS="halt_on_error=1 verbosity=1" run test_locks_tsan $NOASLR ./test_locks_tsan
TSAN_OPTIONS="halt_on_error=1"             run race_control    $NOASLR "$OUT/race_tsan"

{
    echo "== TSan evidence for the report (LS6 $(hostname), $(g++ --version | head -1)) =="
    for p in test_map_tsan test_locks_tsan; do
        echo "--- $p"
        grep "^$p:" "$OUT/exit_codes.txt"
        echo "last line: $(tail -n 1 "$OUT/$p.stdout")"
        echo "TSan banner: $(grep -m1 -i 'Running under ThreadSanitizer' "$OUT/$p.stderr" || echo '(none printed by this TSan version; see ldd_tsan.txt)')"
        echo "ThreadSanitizer WARNING/SUMMARY lines: $(grep -c -E 'WARNING: ThreadSanitizer|SUMMARY: ThreadSanitizer' "$OUT/$p.stderr")"
    done
    echo "--- iteration counts under TSan (SCALE=4 => 'x 5000', plain build 'x 20000'):"
    grep -m2 'threads x' "$OUT/test_locks_tsan.stdout"
    echo "--- linked runtime: $(cat "$OUT/ldd_tsan.txt")"
    echo "--- positive control (must show a race, exit 66):"
    grep '^race_control:' "$OUT/exit_codes.txt"
    grep -m1 'SUMMARY: ThreadSanitizer' "$OUT/race_control.stderr"
} | tee "$OUT/tsan_summary.txt"
