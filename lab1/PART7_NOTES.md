# Notes for Part 7 (StripedHashMap) — constraints found while doing Parts 1–6

<!-- Generated with assistance of claude code. -->

All verified against the provided tests (g++ 13.3, plain and TSan).

1. **`insert` must overwrite.** `test_sequential` checks `insert(1,10)==true`,
   `insert(1,11)==false`, then `find` gives **11**. An existing key: overwrite
   the value, return false. New key: new node, return true.
2. **One binary for everything.** `test_map.cpp` and `bench.cpp` compile
   `concurrent_map.h`, `locks.h` and `hash_map.h` together. A compile error
   anywhere in `hash_map.h`, even in a member nobody calls, breaks every
   part's tests and bench. Build against our real `locks.h` and `parts.h`
   (`HAVE_SHARDED/LOCKS/RW = 1`, then `HAVE_HASHED = 1`) before handing it over.
3. **Your tests use our locks.** `StripedHashMap<…, TTASLock>`, `<ParkingLock>`,
   `<RWLock>` and `<RWLockWP, false>` are all instantiated, so test with those,
   not only `std::mutex`.
4. **The (7, 3) test.** `stripe = b / (B / L)` indexes past the stripe array
   (bucket 6 → stripe 3 when B=7, L=3). Use `stripe = b * L / B` (contiguous,
   valid for any B, L) or `b % L`, and say which in the report.
5. **`find` through `ReadGuard<Lock>`** (shared mode for shared_mutex, RW, RWWP).
   The tests don't catch a `lock_guard` here, but Part 6-style data would be wrong.
6. **Padding.** `static_assert(!Padded || sizeof(Stripe) % CACHE_LINE == 0)`.
   It must be conditional, because `Padded=false` is instantiated. Use
   member-level `alignas`. A struct-level `alignas(Padded ? 64 : 1)` is
   ill-formed C++ (clang rejects it; GCC silently accepts it).
7. **Exact `size()`:** take every stripe lock in index order, sum, release.
   Under TSan, one thread holding **more than 64** `std::mutex`/`shared_mutex`
   at once crashes TSan's deadlock detector and then hangs. The test's 64 stripes
   are exactly at the limit, so `size()` must hold the stripe locks and nothing else.
8. **Destructor frees every node.** Nothing tests for leaks, but the README requires it.
9. **ShardedMap layout, for the padding comparison.** A padded `ShardedMap` shard
   is 128 B: the lock alone on line 0, the `std::map` header on line 1. A nopad
   shard of a ≤ 8 B lock is 56 B, so shard *i*'s lock shares a line with shard
   *i−1*'s map header. `sizeof(TTASLock)` = 1, `TicketLock` = 8,
   `ParkingLock` = 4, `RWLock` = 4, `RWLockWP` = 8.
10. **Measurements.** The scripts in `jobs/` (sourcing `lab1_common.sh`) already
    handle pinning, median of three, raw bench lines, `DELAY` and per-op tables.
    A Part 7 job can reuse `run_sweep` and `run_perf`; set `BUCKETS=b` per call
    (`BUCKETS=$b run_sweep …`). `EVENTS` *replaces* perfstat's default list, so
    list every event you need (e.g. add `L1-dcache-load-misses` to the README's
    padding example).
