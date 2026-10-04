**Part 1**

*Code.* `CoarseMap` is one `std::map` and one `std::mutex`, with a `lock_guard` in every method. `insert` uses `insert_or_assign`, because the tests require an existing key's value to be overwritten. `make test` and `make tsan` pass (TSan lines in the appendix).

*Why `size()` needs the lock.* `std::map::size()` reads the tree's element count (`_M_node_count`). Every insert of a new key increments it, and every successful erase decrements it. Reading it while another thread writes it is a data race, which is undefined behaviour in C++. There is no happens-before edge between the write and the read, so the compiler may keep a stale value, and TSan reports the race. With the lock, the previous holder's unlock (a release) happens-before our lock (an acquire). `size()` therefore returns the exact count at one instant between operations.

*Why the interface returns copies.* A reference or iterator into the map would outlive the `lock_guard` that made reading it safe. As soon as `find` returns, another thread could:
- erase that key and free the node, leaving a dangling reference (the freed chunk can be reused at once by the next insert, so the caller would read some other key's value);
- overwrite the value with `insert`, a race that tears a non-trivial `V`;
- rebalance the tree, so an iterator's `++` follows pointers that are being rewritten.

Copying `out = it->second` while the lock is held gives the caller a private value.

**Part 2**

*Prediction* (committed 15:07, before the 15:20 run; `PREDICTIONS.md`):
- the peak is at T = 1, at 2–3.5 Mops/s;
- at T = 2–4, throughput falls to 40–60 % of T = 1;
- a plateau of 0.5–1.2 Mops/s holds through T = 28;
- once threads reach the second socket, there is a further 20–40 % step down;
- the curve is flat past 56, because std::mutex waiters sleep instead of spinning.

*Protocol.* One Frontera compute node: c207-021, job 7972219, 2 × Xeon Platinum 8280, 28 cores per socket, SMT off (`lscpu` is in the appendix). The run used `sweep.sh`: taskset-pinned, median of three 2-s runs. It printed:
`# cores=56 hwthreads=56 sockets=2 cores/socket=28 pin order: 0 1 2 3 … 55`, with `<- first socket full` at T = 28 and `<- every core busy` at T = 56.

*Topology caveat.* `lscpu` shows `NUMA node0 CPU(s): 0,2,4,…,54` and `node1: 1,3,…,55`; Frontera numbers its CPUs alternately by socket. sweep.sh pins in CPU-number order, so **from T = 2 its threads already span both sockets**, and the "first socket full" tag at T = 28 is wrong: at T = 28 the threads are split 14 + 14. We also ran a copy of sweep.sh with only the pin order changed to socket 0 first (0, 2, …, 54, then 1, 3, …), on node c208-017. It shows where the real socket boundary is. The two curves agree to within 0.6 % wherever they use the same CPU set (T = 1, 56, 84).

| T | 1 | 2 | 4 | 8 | 16 | 28 | 40 | 56 | 84 | 112 |
|---|---|---|---|---|---|---|---|---|---|---|
| sweep.sh order | 2.088 | 1.048 | 0.712 | 0.678 | 0.682 | 0.687 | 0.671 | 0.671 | 0.672 | 0.716 |
| socket 0 first | 2.084 | 1.108 | 0.954 | 1.054 | 1.060 | 1.046 | 0.695 | 0.672 | 0.676 | 0.705 |

Values are Mops/s, median of three. Every three-run spread is within ±2 %, except sweep.sh T = 2 (1.045–1.313) and T = 4 (0.710–0.744).

![Part 2 coarse curve](results/figs/part2_coarse.png)

*Prediction vs measurement.*
- **Peak:** at T = 1 (2.09 Mops/s), as predicted, at the low end of the range.
- **T = 2–4:** 53 % and 46 % of T = 1 on one socket (predicted 40–60 %).
- **Plateau:** flat at 1.05 Mops/s on one socket (T = 8–28), inside the predicted 0.5–1.2.
- **Socket boundary:** in the socket-first curve, throughput **drops 34 % from T = 28 to 40** (1.046 → 0.695), as predicted. In sweep.sh order, the same cross-socket penalty already appears at T = 4 (0.712 vs 0.954), so that curve shows nothing at 28.
- **Past 56:** flat (0.67–0.72), as predicted. T = 112 is 5–7 % higher on both nodes, which we cannot explain.

**Part 3**

*The contended line.* `CoarseMap`'s mutex is `alignas(64)`, so its cache line is the same in every run.
- **Line 0** holds the pthread mutex word (bytes 0–39) and the map's root pointer (byte 56). Every operation reads and writes it: the lock CAS, the root read, and the unlock.
- **Line 1** holds leftmost, rightmost and the element count. It is written by the ≈10–15 % of operations that change the size.
- The tree's upper levels are read-mostly. They sit in S in every core's cache and cause no traffic.

*MESI states between handoffs.*
- On the holder's core, line 0 is **Modified**: its CAS wrote it, and its unlock writes it again.
- On every other core it is **Invalid**, because the holder's read-for-ownership invalidated their copies. Sleeping waiters hold nothing.
- A handoff goes like this. The next acquirer's load misses. The snoop finds the line Modified in the previous holder's cache (a HITM) and forwards the 64-B line. The acquirer's CAS then upgrades its copy to M, and the old copy becomes I.
- What moves is one line: the lock word plus the root pointer, and line 1 on size-changing operations.

*Cost of one handoff.* [Insert the coherence session's measured core-to-core number here.] Published Cascade Lake figures are ≈40–70 ns (≈130–230 cycles at the measured 3.3 GHz) on one socket and ≈110–150 ns across sockets. Our counters agree in order of magnitude. From T = 1 to T = 8, user cycles per op rise by ≈1000 while user L1 misses rise by 9.6, about one of which is a HITM. Charging the other misses as L3 hits leaves ≈400–570 cycles (≈130–190 ns) per handoff. This is an estimate and an upper bound, since misses can overlap.

*Counters.* All runs are on one socket (CPUs 0; 0,2,…,14; 0,2,…,54) with 5-s runs, and every value is per operation.
- "all" counts user and kernel events (Frontera has `perf_event_paranoid=0`); ":u" repeats the run with user-mode hardware counters only.
- Values are perfstat's printed per-op numbers. Counting starts just after the warm-up, so the counters cover 94.8 % of the timed run, and true per-op values are ≈5.5 % higher.

| | T=1 all | T=1 :u | T=8 all | T=8 :u | T=28 all | T=28 :u |
|---|---|---|---|---|---|---|
| operations | 10,908,672 | 10,643,456 | 5,204,992 | 5,092,352 | 5,087,232 | 5,074,944 |
| Mops/s | 2.182 | 2.129 | 1.040 | 1.018 | 1.014 | 1.012 |
| cycles/op | 1,445 | 1,465 | 11,110 | 2,469 | 65,810 | 2,889 |
| instructions/op | 330.5 | 323.6 | 4,907 | 353.5 | 11,060 | 361.4 |
| IPC | 0.229 | 0.221 | 0.442 | 0.143 | 0.168 | 0.125 |
| L1 misses/op | 25.29 | 24.26 | 143.7 | 33.84 | 225.4 | 38.18 |
| LLC misses/op | 0.489 | 0.508 | 0.975 | 0.911 | 0.829 | 0.843 |
| HITM/op | 0.0003 | 0.0000 | 17.74 | 0.93 (0.93–1.32) | 37.39 | 1.55 (1.18–1.55) |
| context switches/op | 0.0000003 | 0.0000008 | 0.528 | 0.544 | 0.759 | 0.766 |

*L1 misses per operation at T = 1.*
- **Estimate from the tree:** the tree holds 2¹⁹ ≈ 512K nodes, so a lookup walks ≈19–20 levels. The 32 KB L1 holds about the top 8 levels, and the 1 MB L2 about the top 13–14. That leaves ≈11–12 levels missing L1: ≈5–6 of them hit L2 and the rest come from L3.
- **What we measured:** 24–25 L1 misses per op, about twice that estimate. LLC misses are only 0.5 per op, because the ≈32 MB tree fits in the 38.5 MB L3.
- **Likely reason for the factor of two:** each missing level costs two line fills. The counter also counts lines brought in by prefetch, and a node's child pointers and key can sit on different lines. This is untested.

*Cycles vs L1-miss growth from T = 1 to T = 8.*
- In user mode, cycles per op grow ×1.69 while L1 misses grow only ×1.39. In all mode the factors are ×7.7 and ×5.7, and at T = 28 they are ×45.5 and ×8.9.
- The extra misses are expensive ones. Each costs ≈105 cycles (1004 extra cycles / 9.6 extra misses), against ≈14 for an L2 hit, because they are coherence misses that find the line Modified in another core, plus L3 refills.
- In all mode, the kernel's futex and scheduler work adds ≈8,600 cycles per op at T = 8 (78 % of all cycles) and ≈63,000 at T = 28 (96 %).

*HITM vs handoffs.* We expect up to one counted handoff per acquisition that comes from another core (≤ 7/8 at T = 8). Add one for each arriving thread that fails and goes to sleep (≈0.53 per op), plus line 1 (≈0.1). That gives ≈0.9–1.7 per op. The user-mode HITM of 0.93–1.32 (T = 8) and 1.18–1.55 (T = 28) falls inside that range. The all-mode HITM (17.7 and 37.4) is mostly kernel lines: ≈32–47 per context switch.

*Context switches, and why throughput gets worse instead of flat.*
- **Where the time goes:** at T = 8, about every second operation puts a thread to sleep in the futex (0.53 per op); at T = 28 it is three in four (0.76). Threads are on-CPU only 55 % and 80 % of the time, and the map work adds up to about one core's worth; the rest is kernel time.
- **Why it gets worse:**
  - Pure serialization would hold the T = 1 rate. Instead, every critical section now starts with a coherence miss and an ownership upgrade.
  - Every unlock with a sleeper makes a `futex_wake` system call that takes microseconds, against an operation that takes ≈0.46 µs.
  - Across sockets every transfer crosses UPI, which gives the 0.7 Mops/s plateau of the sweep.sh curve. That part is a hypothesis: the perf runs were one-socket only.

**Part 7**
