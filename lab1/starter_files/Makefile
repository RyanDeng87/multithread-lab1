# Lab 1 -- concurrent map, locks, and a hash table.
#
#   make            build bench and both test programs
#   make test       run the correctness tests (plain build)
#   make tsan       run them under ThreadSanitizer  <-- required
#   make sweep      throughput vs threads for each IMPL, one CSV each
#   make perf       one pinned run under perf stat, counters per op
#   make clean
#
# The tests live in ../tests; your code is the headers in this
# directory.  parts.h says which parts are compiled in.

CXX      ?= g++
CXXFLAGS ?= -std=c++20 -O2 -Wall -Wextra -pthread
TSAN     := -std=c++20 -O1 -g -fsanitize=thread -pthread
HDRS     := parts.h interface.h concurrent_map.h locks.h hash_map.h

all: bench test_map test_locks

bench: bench.cpp $(HDRS)
	$(CXX) $(CXXFLAGS) -o $@ $<

test_map: ../tests/test_map.cpp $(HDRS)
	$(CXX) $(CXXFLAGS) -I. -o $@ $<

test_locks: ../tests/test_locks.cpp $(HDRS)
	$(CXX) $(CXXFLAGS) -I. -o $@ $<

test_map_tsan: ../tests/test_map.cpp $(HDRS)
	$(CXX) $(TSAN) -I. -o $@ $<

test_locks_tsan: ../tests/test_locks.cpp $(HDRS)
	$(CXX) $(TSAN) -I. -o $@ $<

test: test_map test_locks
	./test_map
	./test_locks

tsan: test_map_tsan test_locks_tsan
	TSAN_OPTIONS=halt_on_error=1 ./test_map_tsan
	TSAN_OPTIONS=halt_on_error=1 ./test_locks_tsan

# One CSV per implementation, named after it with ':' -> '_'.  The
# default THREADS suit a 56-core Frontera node (socket boundary at
# 28, every core busy at 56, oversubscribed beyond); edit them for
# another machine.  The report wants points below, at, and above the
# core count.
#
#   make sweep IMPLS="coarse sharded:mutex sharded:ttas" SHARDS=256
#   MIX=50/25/25 make sweep IMPLS="sharded:rw sharded:shared_mutex"
THREADS ?= 1 2 4 8 16 28 40 56 84 112
SHARDS  ?= 256
IMPLS   ?= coarse sharded:mutex
sweep: bench
	@for impl in $(IMPLS); do \
	    out=$$(echo $$impl | tr ':' '_').csv; \
	    bash sweep.sh ./bench $$impl $(SHARDS) $(THREADS) > $$out; \
	    echo "wrote $$out"; \
	done

# One run under perf stat with the counters reported per operation.
# CPUS is a taskset list; fewer CPUs than T oversubscribes on purpose.
# EVENTS, DELAY and RUN_SECONDS pass through to perfstat.sh.
#
#   make perf IMPL=coarse T=8 SHARDS=1
#   make perf IMPL=sharded:tas T=32 SHARDS=256 CPUS=0-7
#   EVENTS=cycles,instructions,mem_load_l3_hit_retired.xsnp_hitm \
#       make perf IMPL=hashed:ttas:nopad T=28 SHARDS=1024
IMPL   ?= coarse
T      ?= 1
CPUS   ?=
perf: bench
	bash perfstat.sh ./bench $(IMPL) $(T) $(SHARDS) $(CPUS)

clean:
	rm -f bench test_map test_locks test_map_tsan test_locks_tsan *.csv

.PHONY: all test tsan sweep clean
