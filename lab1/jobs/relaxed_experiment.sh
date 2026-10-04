#!/bin/bash
# Generated with assistance of claude code.
# relaxed_experiment.sh -- Part 5's memory-ordering experiment, run on a
# throwaway copy so the relaxed lock can never reach the submitted locks.h.
#
#   cd lab1/starter_files && bash ../jobs/relaxed_experiment.sh
#   (on Lonestar6: inside idev, or as the last step of ls6_tsan.slurm)
#
# Copies starter_files and tests to a temp dir, rewrites every
# memory_order_* in TTASLock to memory_order_relaxed, then runs the four
# test programs ONE BY ONE (make tsan stops at the first race, so
# test_locks_tsan would never run).  Everything lands in
# ../results/relaxed_<date>/: the diff, each program's output and exit code.
set -u
SF=$(pwd)
[ -f "$SF/locks.h" ] && [ -d "$SF/../tests" ] ||
    { echo "run from lab1/starter_files" >&2; exit 2; }
OUT=$(cd "$SF/.." && pwd)/results/relaxed_$(date +%Y%m%d-%H%M%S)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"
cp -r "$SF" "$TMP/starter_files"
cp -r "$SF/../tests" "$TMP/tests"
cd "$TMP/starter_files" || exit 2
rm -f bench test_map test_locks test_map_tsan test_locks_tsan

# relax TTASLock only: the text between its class line and the next class
awk '/^class TTASLock/ {in_ttas = 1}
     /^class TicketLock/ {in_ttas = 0}
     { if (in_ttas) gsub(/std::memory_order_[a-z_]+/, "std::memory_order_relaxed"); print }' \
    locks.h > locks.relaxed && mv locks.relaxed locks.h
diff -u "$SF/locks.h" locks.h > "$OUT/locks_relaxed.diff"
echo "== change applied (TTASLock, all orders -> relaxed):"
grep -n 'memory_order' "$OUT/locks_relaxed.diff" | grep '^[0-9]*:+'

make test_map test_locks test_map_tsan test_locks_tsan > "$OUT/build.txt" 2>&1 ||
    { echo "build failed: $OUT/build.txt"; exit 1; }

NOASLR="setarch $(uname -m) -R"
run() {   # run NAME CMD...
    local name=$1; shift
    timeout 1200 stdbuf -oL "$@" > "$OUT/$name.txt" 2>&1
    local rc=$?
    echo "$name: exit=$rc" | tee -a "$OUT/summary.txt"
}
run make_test_test_map   ./test_map
run make_test_test_locks ./test_locks
TSAN_OPTIONS=halt_on_error=1 run tsan_test_map   $NOASLR ./test_map_tsan
TSAN_OPTIONS=halt_on_error=1 run tsan_test_locks $NOASLR ./test_locks_tsan

{
    echo "== $(hostname)  $(g++ --version | head -1)"
    for f in make_test_test_map make_test_test_locks tsan_test_map tsan_test_locks; do
        echo "--- $f: $(grep "^$f:" "$OUT/summary.txt")"
        grep -m1 -E 'all checks passed|FAILURES' "$OUT/$f.txt"
        grep -m1 'SUMMARY: ThreadSanitizer' "$OUT/$f.txt"
        grep -m3 -E '#[0-9]+ .*(test_locks\.cpp|test_map\.cpp|locks\.h|concurrent_map\.h)' "$OUT/$f.txt"
    done
} | tee "$OUT/report_lines.txt"
echo "artifacts: $OUT   (the submitted locks.h was not touched)"
