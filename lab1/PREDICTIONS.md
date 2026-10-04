# Lab 1 — predictions, written before any Frontera run

<!-- Generated with assistance of claude code. -->

Commit this file **before** submitting the first Frontera job; the commit
date is the evidence that each prediction came first.  Edit anything you
disagree with before committing.  Numbers are estimates unless marked
*published* (vendor or widely reproduced figure) or *measured* (run here).

## Machine facts the estimates use

| item | value | source |
|---|---|---|
| cores | 2 × 28 (Xeon Platinum 8280, Cascade Lake), SMT off | README |
| clock | 2.7 GHz base, ~3.3 GHz all-core turbo, 4.0 GHz single-core | *published* (Intel ARK); turbo on Frontera unverified |
| L1d / L2 / L3 | 32 KB / 1 MB per core; 38.5 MB per socket, non-inclusive | *published* |
| latency | L2 hit ~14 cycles; L3 hit ~50–70 cycles; local DRAM ~80–90 ns | *published* (approximate) |
| line handoff, same socket (Modified in another core → load) | ~40–70 ns ≈ 130–230 cycles | *published* range; **replace with the coherence session's number** |
| line handoff, across the socket boundary (UPI) | ~110–150 ns ≈ 350–500 cycles | *published* range; same caveat |
| PAUSE latency | ~140 cycles (Skylake and later; ~10 before) | *published* (Intel optimization manual) |

**Tree geometry.** A `std::map<long,long>` node is 48 B (32 B of
colour/parent/left/right + 16 B key/value). glibc's malloc rounds it to a
64 B chunk, so about one cache line per node.  The warm-up leaves 2¹⁹ ≈ 512K
nodes: depth ≈ 19–20, and the nodes take ~32 MB, which fits (mostly) in the
38.5 MB L3.  Assuming random lookups and LRU-like caching:

- L1 (512 lines) keeps about the top 8–9 levels.
- L2 (16K lines) keeps about the top 14 levels.
- A lookup therefore misses L1 on about levels 9–19: ≈ 10–12 L1 misses, of which ≈ 5 hit L2 and ≈ 5–6 come from L3 or DRAM.

## Part 2 — coarse curve (prediction)

- **T = 1 is the peak**, at ≈ 2–3.5 Mops/s. That is ≈ 900–1400 cycles per operation: 5 L2 hits, 5–6 L3 hits, 1–3 DRAM misses, and ~19 levels of branch mispredictions.
- **T = 2–4 drops to ≈ 40–60 % of T = 1.** Every operation now runs while other cores pull the lock line and the map's header line away, and contended acquisitions go through futex sleep/wake, which costs microseconds.
- **T = 8–28 gives a slowly falling plateau (≈ 0.5–1.2 Mops/s).** glibc's mutex lets a running thread barge in, so the thread that just unlocked often re-acquires before a woken sleeper runs. That keeps the curve from collapsing completely.
- **Past 28 (the second socket) there is a further step down of ≈ 20–40 %.** Some handoffs now cross UPI, which costs ≈ 2–3× more per transfer.
- **Past 56 it is roughly flat or slightly lower.** std::mutex waiters sleep, so oversubscription adds scheduler work but no spinning.

## Part 3 — counter expectations (sanity checks, not graded predictions)

| | T=1 | T=8 (one socket) | T=28 (one socket) |
|---|---|---|---|
| Mops/s | 2–3.5 | 0.7–1.5 | 0.5–1.2 |
| cycles/op | 900–1400 | 2–4× T=1 | ≥ T=8 |
| instructions/op | 300–600 | +10–30 % (futex path, retries) | similar to T=8 |
| IPC | 0.3–0.6 | lower | lower |
| L1 misses/op | 10–14 | +3–6 (lock line, header line, recently written nodes) | similar to T=8 |
| LLC misses/op | 1–4 | similar | similar |
| HITM/op | ≈ 0 | 1–4 | 1–4 |
| context switches/op | ≈ 0 | 0.1–1 | 0.3–1 |

Reading the table:

- **Cycles grow far faster than misses.** An L2 hit costs ~14 cycles; a load that finds the line Modified in another core costs ~150–250. A few extra misses therefore show up as hundreds of extra cycles.
- **HITM/op can be below 1.** Barging means consecutive operations often run on the same core, so no handoff happens.
- **If perf can only count user mode** (`perf_event_paranoid=2` makes it add `:u`), the kernel's futex time is missing from cycles/op. `perf_checks.txt` records this.

## Part 4 — shard count (prediction)

- **Collision model.** Almost all of an operation runs inside its shard's lock, so each thread holds some lock for a fraction f ≈ 0.9 of the time. A new operation then finds its shard busy with probability p ≈ 1 − (1 − f/N)^(T−1) ≈ (T−1)·f/N.
  - At T = 32: p ≈ 11 % at N = 256, 2.7 % at N = 1024, 0.7 % at N = 4096.
  - At T = 56: p ≈ 19 % at N = 256 and 4.8 % at N = 1024.
- **Cost of a collision with std::mutex:** a futex sleep and wake, ≈ 2–5 µs. An uncontended operation costs ≈ 0.3–0.4 µs, so one collision costs ≈ 10 operations.
- **Expected cost per operation ≈ t₀·(1 + 10p).** At T = 32 that is ≈ 2.1× t₀ at N = 256, 1.27× at N = 1024 and 1.07× at N = 4096.
- **Prediction: throughput at T = 32 rises steeply up to N ≈ 1024 and is flat within noise after that. Ship N = 1024** (or 4096 if its gain is larger than the run-to-run spread).
- **At T = 1 the curve is roughly flat (±15 %).**
  - Smaller trees save a few L1-resident levels (and their branch mispredictions).
  - Each operation adds one `div` (~40 cycles) for `% N`.
  - Very large N (≥ 4096 × 64 B = 256 KB of shard headers) adds a miss on the shard array itself.
- **Measurement caveat.** `std::hash<long>` is the identity and the warm-up inserts only even keys. So for every even N, the odd shards start empty and the even ones hold 2²⁰/N keys. Any shard-depth argument should say so.

## Part 5 — locks

### One shard, 8 threads on 8 cores of one socket (graded prediction)

- **Most L1 misses/op: TAS.** Every waiter spins on `exchange`, a write, so each attempt pulls the line in M state away from whoever had it. During one critical section (~0.5 µs) the line moves ~5–15 times, and each move is an L1 miss.
- **TTAS has fewer.** Its waiters sit on a Shared copy in their own L1 (hits, no traffic). Each release costs a burst of about one miss per waiter (7) plus one or two exchange attempts, after which backoff spreads out the retries.
- **Most instructions/op: TTAS or Ticket.** Their waiters spin on L1 hits, so their loops keep retiring instructions (load, compare, pause, backoff counter) instead of stalling on misses. TAS waiters stall ~100–300 cycles per exchange, so they retire few instructions.
  - **Caveat:** PAUSE (~140 cycles) slows every spin loop, so the instruction gap may be modest.
- **std::mutex and Parking show the fewest of both.** Their waiters sleep and retire nothing; Parking spins first (≤ 100 pauses), then sleeps.
- **HITM/op:** TTAS ≈ one per waiter per release (each re-read finds the line M in the releaser's cache).
  - **Caveat:** if the HITM event counts only plain loads and not the load half of `xchg`, TAS shows *few* HITM despite the most L1 misses. That is worth one sentence if it happens.

### 32 threads on 8 cores (prediction)

- **Busy fraction** (cycles/op × ops/s ÷ (8 × clock)): ≈ 0.95–1.0 for TAS, TTAS and Ticket, whose spinning keeps the cores busy. ≈ 0.8–1.0 for mutex and Parking, whose waiters sleep. Runnable threads usually remain, so their cores also stay mostly busy.
- **Throughput:** mutex ≈ Parking > TTAS ≥ TAS > Ticket.
  - A spinlock whose holder is preempted (probability ≈ f per timer tick) makes every thread that later hashes to that shard spin through the rest of its timeslice. With 256 shards and ~1000 operations per ms, that happens within a fraction of a millisecond.
  - Ticket also suffers from **waiter** preemption. The lock is handed to one specific waiter in FIFO order; if that waiter is off-CPU, the free lock sits idle while everyone behind it spins and yields.
- **Context switches/op:** Ticket highest (yields), then mutex and Parking (futex sleeps on collisions), then TAS/TTAS (only timeslice expiry, ≈ 10⁻⁴/op).

### The other Part 5 questions

- **Parking vs std::mutex.** At one thread per core, Parking ≥ mutex: it spins briefly before sleeping, while glibc's default mutex sleeps after one failed CAS, so short waits never pay for a futex. Past the core count they come out ≈ equal: Parking wastes at most ~4 µs of spinning before it too sleeps.
- **Spin hint (PAUSE).** It tells the core it is in a spin-wait. The core stops speculatively issuing the loop's loads, which avoids the memory-order pipeline flush when the line finally changes. It also saves power and leaves pipeline resources to an SMT sibling. On CLX it lasts ~140 cycles, which also throttles how often the watched line is polled.
- **Why Ticket needs yield and TTAS doesn't.** TTAS hands the lock to whichever waiter is running, so a preempted waiter costs nothing. Ticket hands it to the next ticket; if that thread is descheduled, nobody can take the lock until it runs, and yielding is how the spinners give it a CPU.
- **Relaxed experiment** (*measured* locally, g++ 13.3, x86: TTASLock with every order made relaxed):
  - `make test`: still passes.
  - `test_locks_tsan`: data race at `test_locks.cpp:62`, exit 66.
  - `test_map_tsan`: race inside `ShardedMap<TTAS>::insert`.
  - Why plain doesn't notice: on x86 every locked RMW is a full barrier and plain stores are not reordered with other stores (TSO), so the hardware still behaves. GCC did not happen to move the critical-section accesses across the relaxed atomics.
  - Why TSan notices: it checks the C++ model, in which relaxed creates no happens-before edge, so the counter accesses race. Run `./test_map_tsan` and `./test_locks_tsan` separately: `make tsan` stops at the first race.

## Part 6 — reader-writer (prediction)

- **At the chosen N (≥ 256), every mix:** rw ≈ TTAS, rwp ≈ rw, shared_mutex lowest.
  - Collisions are rare, so sharing gains nothing.
  - A reader pays two locked RMWs (CAS in, `fetch_sub` out), where TTAS pays one exchange and a plain store.
  - `pthread_rwlock` (which std::shared_mutex wraps) runs more instructions per acquisition.
- **One shard, MIX = 100/0/0:** RW ≫ TTAS, and the gap grows with T. TTAS serializes ~0.3 µs lookups, while RW lets them overlap and pays only the reader-count line transfer (~2 per operation). It scales until that line's ping-pong saturates. shared_mutex scales similarly, at lower absolute throughput.
- **One shard, 80/10/10:** RW > TTAS at moderate T, with a narrowing gap as writers (every thread writes 20 % of the time) wait for a moment with zero readers.
- **One shard, 50/25/25:** RW ≈ or < TTAS.
- **shared_mutex at one shard:** writer starvation. glibc's default rwlock prefers readers, so a waiting writer does not stop new readers. *Measured locally* (WRITERS=1 and WRITERS=4 at 32 threads, 1 shard): `wr = 0.0 Mops/s` while readers run 12–13 Mops/s. Our RWLock does the same (`wr = 0.0`).
- **RWLockWP:** writer throughput goes from ≈ 0 to substantial, reader throughput collapses (*measured locally:* `rd = 0.0–0.3` with 1–4 writers), and the total is lower because readers lose their parallelism.
