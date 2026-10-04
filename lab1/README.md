# Lab 1 — A concurrent map: lock it, measure it, shard it, then build the locks

## Overview

You will take a container you already know — `std::map` — and make it safe for many threads to use at once. Then you will measure what that safety costs as the thread count grows, explain the cost from the cache-coherence material, and remove most of it by sharding: many small maps, each behind its own lock. That is the first half of the lab, and everything hard in it is in the locking and the measurement.

The second half takes away the standard library. You will write the locks yourself — four exclusive locks with different waiting strategies and two reader-writer locks — plug each into the sharded map through a template parameter, and measure what the waiting strategy costs when the machine has fewer cores than threads. Then you will replace `std::map` with a hash table of your own, striped with your own locks, and measure again. By the end, every line between the benchmark harness and the hardware is yours.

Throughout, you will use `perf stat` to count what the hardware did — cache misses, coherence transfers, context switches — per operation, so that your explanations rest on counters as well as on throughput curves. A throughput curve tells you that something got slower; the counters tell you what the machine was doing while it was slow.

This lab is done in pairs over three weeks. The measurement and the report are where the points are, and they need machine time on a many-core node that you cannot get the night before the due date.

## Objectives

By the end of this lab you will be able to:

- Wrap a sequential data structure for concurrent use with a lock and an RAII guard, and state precisely which data the lock protects.
- Use ThreadSanitizer to demonstrate the absence of data races, and explain why a passing test without TSan proves nothing.
- Run a pinned throughput sweep across thread counts, plot it, and identify the regimes of the curve — one thread per core, then oversubscribed — and mark where the second socket comes into play.
- Use `perf stat` to count cycles, instructions, cache misses, coherence transfers, and context switches per operation, and use those counts to tell an L2 hit from a coherence miss and a spinning thread from a sleeping one.
- Explain, in writing and in terms of cache lines and the MESI states, why one global lock stops scaling long before the cores run out.
- Reduce contention by sharding on a hash, choose a shard count from a collision argument, and re-measure to confirm the prediction.
- Build spinning, ticket, and parking locks from `std::atomic` with correct memory ordering, and show with TSan that the ordering matters.
- Measure and explain what each waiting strategy costs when threads outnumber cores.
- Build a reader-writer lock, and determine from measurement the conditions under which it beats an exclusive lock.
- Build a striped hash table, choose its bucket and stripe counts from measurement, and quantify the effect of padding its locks.

## Background

**The interface.** Every map you write has the same four operations, and all of them return values, not references:

```cpp
bool insert(const K& key, const V& value);   // true if key was new
bool find  (const K& key, V& out) const;     // copy out; false if absent
bool erase (const K& key);                   // true if it was present
std::size_t size() const;
```

`interface.h` states the contract as a C++20 concept, `ConcurrentMap<M, K, V>`, and the tests `static_assert` it, so a missing or mistyped method fails to compile with the concept's name in the error. 

**The lock protects data, not code.** A mutex is not attached to a map by the language; it is attached by a rule you enforce in every method. The compiler checks nothing. TSan checks it at run time, which is why the TSan run is required.

**The harness.** `bench.cpp` runs T threads for a fixed number of seconds, each with its own random-number generator, doing a mix of `find`, `insert`, and `erase` on a million-key space, and reports total throughput in millions of operations per second. `sweep.sh` runs it at each thread count, pinned one thread per core in CPU-number order so the first socket fills before the second, median of three runs, and writes a CSV. The implementation under test is selected by a string such as `sharded:ttas` or `hashed:rw:nopad`; the mix, a reader/writer split, and the hash table's bucket count are environment variables; the header comment in `bench.cpp` lists them. Do not modify the measurement. `parts.h` tells the harness and the tests which parts exist yet, so you can build and measure Part 1 before Part 7 is written.

**The machine.** All graded measurements are made on one Frontera compute node: two Intel Xeon Platinum 8280 sockets, 28 cores each, 56 cores in all. SMT is disabled on TACC nodes, so there is one hardware thread per core and T > 56 is oversubscribed. `sweep.sh` prints the core count, the socket boundary, and the pin order it used; record all three. Measure on a compute node (`idev` or a batch job), never on a login node. Your laptop is fine for developing and for the tests, but not for a graded curve: on macOS there is no `taskset`, and a laptop's core count shows none of the regimes the report asks about.

**The counters.** `perf stat` runs a program and, when it exits, prints how many times each requested hardware or software event happened while it ran. It needs no root and no special build:

```
$ perf list hw cache sw           # what this node can count
$ perf stat -e cycles,instructions,L1-dcache-load-misses,\
    cache-misses,context-switches -- taskset -c 0 ./bench coarse 1 1
```

The events this lab uses, and what each one means on this machine:

```
cycles, instructions        instructions/cycles is the IPC.  A core
                            stalled on memory retires little.
L1-dcache-loads             loads that executed.
L1-dcache-load-misses       lines brought INTO L1, whatever the
                            source: L2, L3, another core's cache, or
                            DRAM.  A coherence miss counts one, the
                            same as an L2 hit that costs 14 cycles.
cache-misses                last-level-cache misses: the line came
                            from DRAM or from the other socket.
                            A handoff between two cores on one
                            socket does NOT count here.
mem_load_l3_hit_retired.xsnp_hitm
                            a load that found its line Modified in
                            another core's cache on this socket and
                            had to snoop it out: a coherence handoff.
                            Loads only; a store that misses is not
                            counted.
mem_load_l3_miss_retired.remote_hitm
                            the same handoff, across the socket
                            boundary.
context-switches            the kernel took the CPU away from the
                            thread: it slept (a futex wait, a yield)
                            or its timeslice expired.
cpu-migrations              the thread moved to another CPU; should
                            be zero when pinned.
```

Raw counts mean nothing on their own; a two-second run of a fast map performs more of everything. Divide every count by the number of operations bench reports, and compare counts per operation. The one trap is the warm-up: bench fills the map single-threaded before the timed run starts, and those inserts miss the cache like anything else. `perf stat -D ms` starts counting `ms` milliseconds after the program starts; bench prints its warm-up time on stderr so you can choose a delay that skips it. `perfstat.sh` does all of this — pins the run the way `sweep.sh` would, runs it longer than a sweep point so start-up and join are negligible, skips the warm-up, divides by the operation count, and prints the IPC — and `make perf` calls it:

```
$ make perf IMPL=coarse T=8 SHARDS=1
$ make perf IMPL=sharded:tas T=32 SHARDS=256 CPUS=0-7      # 32 on 8
$ EVENTS=cycles,instructions,mem_load_l3_hit_retired.xsnp_hitm \
      make perf IMPL=hashed:ttas:nopad T=28 SHARDS=1024
```

Read `perfstat.sh` once; it is eighty lines, and you should be able to reproduce any row of its output with `perf stat` by hand. Before the first measurement, check that counting works on the compute node you are on: `perf stat -e cycles true` must print a number and not `<not supported>`, and `perf list | grep xsnp` must show the HITM event. If either fails, tell us before you spend a node-hour.

## Files
```
lab1/
  README.md                 this file
  starter_files/
    interface.h             PROVIDED: concepts, ReadGuard, CACHE_LINE
    parts.h                 PROVIDED: HAVE_* switches, all 0
    concurrent_map.h        stub: names and contract only  (Parts 1, 4)
    locks.h                 stub                            (Parts 5, 6)
    hash_map.h              stub                            (Part 7)
    bench.cpp               provided harness (do-not-modify)
    sweep.sh                pinned sweep -> CSV
    perfstat.sh             one pinned run under perf stat, per op
    Makefile                test / tsan / sweep / perf targets
  tests/
    test_map.cpp            every map x every lock, gated by parts.h
    test_locks.cpp          lock correctness, gated by parts.h
```

## Specifications

### Part 1 — One global lock

Implement `CoarseMap<K,V>` in `concurrent_map.h`: one `std::map`, one `std::mutex`, every method a `lock_guard` around the corresponding `std::map` call. `find` copies the value out under the lock. `size()` takes the lock too; the report asks you to explain why, and why the interface returns copies rather than references or iterators. The starter header gives you the names and the contract and nothing else.

Build and run the tests, then run them under ThreadSanitizer:

```
$ make test
$ make tsan
```

Both must pass with no reports. If TSan reports a race, it names the two lines involved; fix the locking, not the test as we will not be using your test file anyway.

### Part 2 — Measure it

Run the sweep on a full Frontera node, with thread counts below, at, and past the core count:

```
$ make sweep IMPLS=coarse THREADS="1 2 4 8 16 28 40 56 84 112"
```

Plot `coarse.csv`: throughput against thread count, on a linear axis, with a vertical line at the core count (56) and a lighter one at the socket boundary (28), where `sweep.sh` starts placing threads on the second socket. Before you run it, write down the shape you expect and where the peak will be; the report compares your prediction to the measurement. Two regimes matter for the explanation: up to 56 threads every thread has a core of its own, and past 56 the kernel is time-slicing. Note in the report whether anything happens at the socket boundary; you are not asked to explain it yet.

### Part 3 — Explain it

In the report, explain the shape of the Part 2 curve using cache lines and MESI states. Name the line that is being fought over, say what state it is in on each core between handoffs, and estimate the cost of one handoff from the coherence session's measurements. Then answer: why does adding threads make it worse rather than flat?

Now put counters under the prose. Run

```
$ make perf IMPL=coarse T=1  SHARDS=1
$ make perf IMPL=coarse T=8  SHARDS=1
$ make perf IMPL=coarse T=28 SHARDS=1
```

and add `mem_load_l3_hit_retired.xsnp_hitm` to the event list (the `EVENTS` variable). Tabulate, for each thread count: Mops/s, cycles per op, instructions per op, IPC, L1 misses per op, LLC misses per op, HITM per op, and context switches per op. Then answer, with the numbers in front of you: how many L1 misses does one operation cost at T=1, and is that consistent with the depth of a 512K-node red-black tree and what fits in a 1 MB L2? Between T=1 and T=8, by what factor did cycles per op grow, and by what factor L1 misses per op? Those two factors are very different; say why, using what one L1 miss costs when the line comes from L2 against what it costs when the line was Modified in another core, and check the HITM count against your estimate of handoffs per op. Finally, what do the context switches per op say about where the threads are spending their time, and how does that connect to the answer for "worse rather than flat"?

This part is prose with numbers in it, not code. A page is enough if every sentence is doing work.

### Part 4 — Shard it

Implement `ShardedMap<K,V,Lock,Padded>`: N independent `std::map`s, each with its own lock, with a key's shard chosen by `std::hash<K>{}(key) % N`. Each `insert` and `erase` locks exactly one shard. `find` takes its shard's lock through `ReadGuard<Lock>` from `interface.h`, which takes a shared lock when `Lock` offers one and an exclusive lock otherwise; that is what lets Part 6 drop in without touching the map.

`Lock` is any type satisfying `BasicLock` — `std::mutex` today, your own locks in Part 5. `Padded` is a `bool`; when true, each shard occupies a whole number of cache lines (`alignas(CACHE_LINE)`, and `static_assert` the size), and when false the shards are packed. Part 7 measures the difference.

`size()` must be exact: hold every shard's lock at once, acquired in index order, and sum under all of them. State in the report why index order is safe against a second concurrent caller of `size()`, and against a concurrent `insert`, and what an approximate version — lock each shard in turn and release it before taking the next — would be allowed to return. The tests call `size()` from several threads while others insert; an exact implementation with the wrong lock order deadlocks there rather than failing.

Run the tests and TSan again, then the sweep with sharding:

```
$ make sweep IMPLS=sharded:mutex SHARDS=256
```

Plot `sharded_mutex.csv` on the same axes as the coarse curve. Then choose the shard count from a measurement rather than a guess:

```
$ for n in 16 64 256 1024 4096; do ./bench sharded:mutex 32 $n; done
```

at a fixed thread count of your choosing, and at one thread for the same shard counts, so you can separate the contention effect from the effect of smaller trees. Report the curve and the shard count you would ship with, justified by a collision argument: at T threads and N shards, how often do two operations want the same shard at the same time, what does one such collision cost with this lock, and how does that product compare with the cost of an uncontended operation? Your numbers should let you put a figure on each term.

### Part 5 — Write the locks

Implement four locks in `locks.h`, each a class with `lock()` and `unlock()` built only from `std::atomic`:

`TASLock` — test-and-set. `lock()` loops on `exchange(true)` until it gets `false` back; `unlock()` stores `false`.

`TTASLock` — test-and-test-and-set with backoff. Waiters spin on a plain load until the lock looks free, and only then attempt the exchange; between failed attempts they back off, doubling a pause count up to a cap. The spin loop should call the processor's spin hint (`__builtin_ia32_pause()` on x86; `yield` on AArch64); the report asks what it is for.

`TicketLock` — a FIFO lock. `lock()` takes a ticket with `fetch_add` on one counter and spins until a second counter reaches that number; `unlock()` advances the second counter. After a bounded number of spins, a waiter must yield its timeslice (`std::this_thread::yield()`); the report asks why this lock needs that and the TTAS lock does not.

`ParkingLock` — spin briefly, then sleep. The lock word has three states: 0 free, 1 held with no waiters, 2 held and possibly with sleepers. The fast path is one compare-and-swap from 0 to 1. A waiter that loses spins a bounded number of times, then sets the state to 2 and sleeps on the atomic with `std::atomic::wait(2)`. `unlock()` exchanges the state to 0 and, only if the old state was 2, calls `notify_one()`. The tests run this lock with 64 threads.

Every lock must pass `make test` and `make tsan`. Then do this experiment and put it in the report: change one of your locks to use `memory_order_relaxed` everywhere, run `make test` and `make tsan`, and record what each does. Explain the result: what do the acquire and release orderings permit or forbid that relaxed does not, and why does one of the two runs not notice?

Now measure. At your chosen shard count, sweep every lock across thread counts from one to well past the core count:

```
$ make sweep IMPLS="sharded:mutex sharded:tas sharded:ttas \
                    sharded:ticket sharded:park" SHARDS=256
```

Plot all five on one set of axes. Then take two sets of counter measurements that isolate what the curves mix together.

The first isolates the waiting traffic. At one shard, so every operation contends, and eight threads on eight cores of one socket:

```
$ for l in mutex tas ttas ticket park; do
      EVENTS=cycles,instructions,L1-dcache-load-misses,\
  mem_load_l3_hit_retired.xsnp_hitm,context-switches \
      make perf IMPL=sharded:$l T=8 SHARDS=1 CPUS=0-7
  done
```

Before you run it, predict which lock will show the most L1 misses per op and which the most instructions per op, and why they are not the same lock.

The second isolates oversubscription. Thirty-two threads on eight cores, at your chosen shard count:

```
$ for l in mutex tas ttas ticket park; do
      make perf IMPL=sharded:$l T=32 SHARDS=256 CPUS=0-7
  done
```

For each lock, compute cycles per op × Mops/s and compare it with 8 cores × the clock: that ratio is the fraction of the eight cores that were busy. Report it next to the context switches per op.

The report should account for three things, from the coherence and scheduling material and with numbers from your curves and your tables: how TAS and TTAS differ, in terms of the state the lock's line is in on a waiting core under each and the traffic a release causes, with the L1-miss and HITM counts per op as the evidence; what happens to each lock once threads exceed cores, why they are not all affected equally, and which locks keep the cores busy doing nothing while others give them up, with the busy fraction and the context switches per op as the evidence; and where the parking lock sits relative to `std::mutex` at one thread per core and beyond, and why. Then redo the shard-count sweep from Part 4 with `sharded:ttas` and `sharded:park`, and redo the collision argument for each; say whether the shard count you would ship with changed, and why.

### Part 6 — Readers and writers

Eighty percent of the default workload is `find`, which modifies nothing, yet every `find` in Part 5 takes an exclusive lock. Implement `RWLock` in `locks.h`: a single atomic word where −1 means a writer holds the lock and a non-negative n means n readers hold it. Readers enter with a compare-and-swap from n to n + 1 when n ≥ 0, and leave with `fetch_sub`; a writer enters with a compare-and-swap from 0 to −1 and leaves with a store of 0. Provide `lock_shared()` / `unlock_shared()` alongside `lock()` / `unlock()`, so the type satisfies `SharedLock` and `std::shared_lock` works on it.

That lock is reader-preferring: a steady stream of readers keeps a writer out indefinitely. Implement `RWLockWP`, a writer-preferring variant, by adding a count of waiting writers that readers check before entering.

Both must pass the tests and TSan. Then measure. Compare `sharded:ttas`, `sharded:rw`, `sharded:rwp`, and `sharded:shared_mutex` at three mixes — `MIX=80/10/10`, `MIX=50/25/25`, and `MIX=100/0/0` — and at two shard counts: your chosen N, and 1. Use `WRITERS=n` to give n threads a pure-write role and the rest a pure-read role, which reports the two classes' throughput separately, and compare the reader-preferring and writer-preferring locks on it.

The report should answer, with numbers: under what combination of mix, shard count, and thread count does a reader-writer lock beat the exclusive spinlock it is built from, and what happens in the other cases? Account for the result in terms of what a reader pays to enter and leave and what it gains. Where does `std::shared_mutex` fall, and what does its behavior at one shard tell you about how it treats a waiting writer? What did the writer-preferring variant do to the writers' throughput, to the readers', and to the total?

### Part 7 — Your own hash table

Implement `StripedHashMap<K,V,Lock,Padded>` in `hash_map.h`: separate chaining, with B buckets fixed at construction and L stripes, each stripe a lock guarding a contiguous range of buckets. `insert`, `find`, and `erase` lock exactly one stripe; `size()` is exact, taking all stripes in index order. Nodes are heap-allocated and freed by the destructor. There is no resize; the harness sizes B for the key count, and the tests also build one with 7 buckets and 3 stripes and fill it with thousands of keys, so long chains must work.

You choose how buckets map to stripes. Whatever you choose, be able to say in the report what two different stripes share in memory, and whether that matters.

Run the tests and TSan. Then measure three things.

First, the container. At one thread, compare `hashed:ttas` against `sharded:ttas` at the same stripe and shard count, and then vary `BUCKETS` from 2 × KEYS down by factors of four until the hash table loses. Report the crossover and explain it. Do not go below 1024 buckets; the warm-up becomes quadratic. At each bucket count also run `make perf` with `BUCKETS` set, and record L1 misses per op and cycles per op; the warm-up grows as the bucket count shrinks, so watch the printed warm-up time and raise `DELAY` when `perfstat.sh` warns. Before you run it, predict the L1 misses per op as a function of the mean chain length, counting the bucket head and the nodes a lookup visits; then plot the measured misses per op against chain length and report the slope. From cycles per op and misses per op, estimate what one miss cost on the long chains and say which level of the hierarchy that latency belongs to.

Second, the stripes. At your chosen thread count, sweep L for `hashed:ttas` and `hashed:park` the way you swept N in Part 4, and report the L you would ship with, with the collision argument redone for this container.

Third, padding. Compare `hashed:ttas` with `hashed:ttas:nopad`, and `sharded:ttas` with `sharded:ttas:nopad`, across the thread sweep. Before you run it, write down how many stripe locks share one cache line when unpadded, using `sizeof` your lock, and predict where in the sweep the difference will show. Report the difference at the thread count where it is largest, explain what bounds it, and state your run-to-run spread; a difference inside the spread is a result, if you say so. Then measure what throughput may not resolve: at 28 threads on one socket and 1024 stripes, run `make perf` on `hashed:ttas` and `hashed:ttas:nopad` with `mem_load_l3_hit_retired.xsnp_hitm` in the event list, and report HITM per op and L1 misses per op for each. Two stripes that share a line but never share a key still hand the line back and forth; the HITM counter sees every such handoff whether or not the throughput does. Say whether the counters resolved a difference that the throughput did not, and what that tells you about how much of an operation's time the lock accounts for.

## Deliverables

- `concurrent_map.h`, `locks.h`, `hash_map.h`, and `parts.h` with every switch set to 1.
- Every CSV the harness produced for the report, named as `make sweep` names them, plus the shard-count, stripe-count, bucket-count, and mix data as produced by `bench`, and the `make perf` output for every counter table in the report.
- A report (PDF, eight pages or fewer) containing: the predicted and measured coarse curve; the Part 3 explanation with its counter table; the sharded curve on the same axes and the shard-count choice with its justification; the five-lock sweep with the two counter tables and the three explanations Part 5 asks for, the relaxed-ordering experiment, and the revised shard count; the reader-writer comparison with the questions in Part 6 answered from your numbers; the three Part 7 measurements with the bucket-count crossover and its misses-per-op slope, the stripe count, and the padding result with its HITM counts; and the TSan summary lines for `test_map_tsan` and `test_locks_tsan` with every part enabled.
- The machine you measured on: `lscpu` output for the core and socket counts, and the pin order and socket boundary `sweep.sh` printed.
- One paragraph on who did what. Both partners must be able to explain every part.

## Checklist

- [ ] `CoarseMap` passes `make test` and `make tsan` with no reports.
- [ ] Coarse sweep run pinned, median of three, on a full Frontera node, with the core count, socket boundary, and pin order recorded.
- [ ] Coarse curve plotted with the core count and the socket boundary marked, alongside your written prediction.
- [ ] Part 3 explanation names the contended line, its MESI state on each core, and a per-handoff cost estimate; the counter table at T=1, 8, 28 is present and the cycles-per-op versus misses-per-op question is answered.
- [ ] `ShardedMap` passes `make test` and `make tsan`; `size()` is exact and its lock order is justified.
- [ ] Sharded sweep on the same axes as the coarse sweep; shard-count sweep at one thread and at your chosen thread count; N chosen and justified.
- [ ] All four Part 5 locks pass `make test` and `make tsan`; the relaxed-ordering experiment is in the report.
- [ ] Five-lock sweep past the core count, with the three explanations; the one-shard counter table and the 32-on-8 oversubscription table are present with the busy fraction computed.
- [ ] Both reader-writer locks pass `make test` and `make tsan`; the mix × shard-count comparison is in the report with the questions answered.
- [ ] `StripedHashMap` passes `make test` and `make tsan`, including the 7-bucket case.
- [ ] Bucket-count crossover with the misses-per-op slope, stripe-count choice, and padding comparison with HITM per op in the report, with the noise stated.
- [ ] Report is eight pages or fewer and contains both TSan summary lines with every part enabled.

## Grading

100 points. Code is graded by our tests, not yours, with every switch in `parts.h` set to 1; the report is graded against the questions each part asks. The measurement and the report carry most of the weight, and a measurement without its protocol (pinned, median of three, machine recorded) earns the protocol points only.

**Rules that apply before points are counted.** A part whose code is not TSan-clean under our tests earns zero code points for that part; its report points still count. A report over eight pages loses 5 points. A partner who cannot explain a part at the checkoff loses that part's code points for the pair. Missing `lscpu` output or pin order costs the 2 points under Report quality and makes every sweep in the report unverifiable, which is graded as unpinned. A counter table without its operation count, or with raw counts in place of counts per operation, earns no points for that table.

| Part | Item | Points |
|---|---|---|
| 1 — One global lock (8) | `CoarseMap` passes `make test` and `make tsan` | 4 |
| | Report: why `size()` needs the lock; why the interface returns copies | 4 |
| 2 — Measure it (8) | Protocol: pinned, median of three, on a full Frontera node, core count, socket boundary, and pin order recorded | 3 |
| | Written prediction of the curve's shape and peak, made before the run | 2 |
| | Coarse curve plotted on a linear axis with the core count and socket boundary marked, prediction compared to measurement | 3 |
| 3 — Explain it (12) | The contended cache line named | 2 |
| | Its MESI state on the holding core and on every other core between handoffs, and what a handoff moves | 3 |
| | Per-handoff cost estimate in the right order of magnitude, tied to the coherence session's measurements | 2 |
| | Why adding threads makes it worse rather than flat | 2 |
| | Counter table at T=1, 8, 28 with per-op figures; misses per op at T=1 checked against the tree; cycles-per-op versus misses-per-op growth explained through what a miss costs by source; HITM and context switches per op read correctly | 3 |
| 4 — Shard it (14) | `ShardedMap` passes `make test` and `make tsan`, including the concurrent `size()` test | 4 |
| | Report: index-order argument for two `size()` callers and for `size()` against `insert`; what an approximate `size()` may return | 4 |
| | Sharded curve on the same axes as the coarse curve | 2 |
| | Shard-count sweep at one thread and at the chosen thread count; N chosen with the collision argument, each term given a figure | 4 |
| 5 — Write the locks (20) | `TASLock`, `TTASLock`, `TicketLock`, `ParkingLock` each pass `make test` and `make tsan` (1.5 each) | 6 |
| | Relaxed-ordering experiment: both runs recorded; what acquire/release forbid; why one run does not notice | 3 |
| | Five-lock sweep past the core count, all on one set of axes | 1 |
| | One-shard counter table with the prediction made before the run; TAS vs TTAS explained from the lock line's state on a waiting core and the traffic a release causes, with L1-miss and HITM per op as evidence | 3 |
| | 32-on-8 table with the busy fraction; oversubscription explained per lock, including why they are not affected equally and which locks burn the cores | 3 |
| | Parking lock vs `std::mutex` at one thread per core and beyond, explained | 2 |
| | What the spin hint is for; why the ticket lock needs the yield and TTAS does not | 1 |
| | Shard-count sweep redone with `ttas` and `park`; collision argument redone; shipped N stated with reason | 1 |
| 6 — Readers and writers (14) | `RWLock` and `RWLockWP` pass `make test` and `make tsan` | 4 |
| | All measurements present: four locks × three mixes × two shard counts, plus the `WRITERS=n` comparison | 3 |
| | Conditions under which the RW lock beats the spinlock, with numbers, accounted for by what a reader pays and gains | 3 |
| | `std::shared_mutex` placed, and its one-shard behavior explained in terms of a waiting writer | 2 |
| | Writer-preferring variant's effect on writers, readers, and total | 2 |
| 7 — Your own hash table (16) | `StripedHashMap` passes `make test` and `make tsan`, including the 7-bucket / 3-stripe case | 4 |
| | Bucket-to-stripe mapping stated; what two stripes share in memory and whether it matters | 1 |
| | Bucket-count crossover against `sharded:ttas` measured and explained; misses per op predicted from chain length, measured slope reported, per-miss cost placed in the hierarchy | 4 |
| | Stripe-count sweep for `ttas` and `park`; L chosen with the collision argument redone for this container | 2 |
| | Padding: locks-per-line computed from `sizeof` and the difference predicted before the run; largest difference reported; what bounds it; run-to-run spread stated; HITM and L1 misses per op for padded and unpadded, and whether the counters resolved what the throughput did not | 5 |
| Report quality (8) | Prose that does work: numbers where the questions ask for numbers, no restating of the assignment | 3 |
| | Plots labeled, comparable curves on shared axes, noise or spread stated wherever a difference is claimed | 3 |
| | TSan summary lines for both test programs, `lscpu` output, pin order and socket boundary, who-did-what paragraph | 2 |
| **Total** | | **100** |
