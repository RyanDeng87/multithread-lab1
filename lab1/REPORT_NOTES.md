# Lab 1 — report notes (numbers verified against results/)

<!-- Generated with assistance of claude code. Working notes, not the report. Each section: analyst notes, then independently re-derived and corrected by a checker. -->

# Parts 1–3: report notes (numbers, predictions, arguments)

**Conventions used throughout**
- **all** = `part3_20261004-152209_7972219`: host c207-021, job 7972219, the same node as the Part 2 sweep. Counts user+kernel, `perf_event_paranoid=0`.
- **:u** = `part3u_20261004-160032_7972388`: host c201-033, job 7972388. Hardware counters are user-only. `context-switches` is a software event, so it is the same event in both.
- Table cells come from the median-Mops row of `*_table.tsv`. Ranges come from `*_all_reps.tsv`.
- **[f] footnote (state it once).**
  - perfstat starts counting at DELAY = 1.5 × warm-up + 200 ms = 381–390 ms (`jobs/lab1_common.sh:298`). That skips the ~123 ms warm-up and also the first ≈260 ms of the timed run.
  - It still divides by all ops of the 5-s run. The window fraction is f = (run_ms + warm-up − DELAY)/run_ms = 0.947–0.948 in every Part 3 run (`lab1_common.sh:285-288`).
  - True per-op ≈ printed / f, i.e. 5.5 % higher. **All tables show printed values.**
  - Check: at T=1 on the same node, cycles/task-clock = 3.300 GHz in all three runs, and 1445/0.948 × 2.182 Mops/s = 3.33 GHz. The extra 0.8 % is ≈34 ms of teardown after the timed run that falls inside the count window (task-clock 4775.6 ms against a 4742 ms window). The f correction is therefore good to <1 %.
- *est.* marks an estimate. "all − :u" (kernel share) subtracts two different runs on **different hosts**: the :u T=1 run is 2.4 % slower (2.129 vs 2.182 Mops/s), so kernel shares are uncertain by at least ±50 cycles/op.
- The clock was not constant across runs. cycles/task-clock (all mode) is 3.30 GHz at T=1, **2.78 GHz at T=8** and 3.16 GHz at T=28. Any cycles→time conversion at T=8 is uncertain by up to ~20 %.

---
## Part 1: one global lock

**Code row (4 pts).**
- `make test`: `test_map` (-O2) exit 0, `all checks passed`.
- `make tsan`: `test_map_tsan` (g++ 15.2, TSan v3) exit 0, `ThreadSanitizer WARNING/SUMMARY lines: 0`. CoarseMap passes `sequential`, `disjoint keys, 8 threads`, `contended keys, 8 threads` and `concurrent size(), exact`.
- Positive control: `race.cpp` exits 66 with `SUMMARY: ThreadSanitizer: data race`.
- Sources: `tsan_ls6_20261004-165301_3488178/{tsan_summary.txt,exit_codes.txt,test_map*.stdout}`.
- The run was on Lonestar6 because TSan cannot run on Frontera (staff answer, `edposts.txt`). It used the same `concurrent_map.h` as the Frontera runs (md5 `efbf5aae…` in both provenance files), with TSan iteration counts scaled down (SCALE=4).

**Report row (4 pts).**
- **Why `size()` needs the lock.**
  - `std::map::size()` returns `_M_node_count`, a plain `size_t` at byte 80 of `CoarseMap`, on cache line 1 (`concurrent_map.h:69-75`).
  - A new-key insert does `++_M_node_count`, and an erase that finds its key does `--`.
  - An unlocked read concurrent with those writes is a data race, which is UB in C++. There is no happens-before edge, so the compiler may cache or hoist the load (a loop polling `size()` can become infinite) and the value can be stale.
  - On x86-64 an aligned 8-B load does not tear in hardware, but the language guarantees nothing, and TSan, which checks the C++ model, flags it.
  - Under `mu_`, unlock (release) → lock (acquire) orders `size()` after every completed insert/erase, so it returns the count at one instant between operations (linearizable).
  - Cite `concurrent_map.h:30-33` ("mu_ protects … the element count that size() reads") and `:60-61` ("without the lock that read is a data race").
- **Why the interface returns copies.** A `V&` or an iterator points into a tree node and outlives the `lock_guard`. After the guard is released:
  - a concurrent `erase(key)` frees the node, so the reference is a use-after-free. glibc can hand the same 64-B chunk to the next insert at once, so the caller reads another key's value.
  - a concurrent `insert_or_assign` on the same key overwrites the value non-atomically: a data race, or a torn `V` such as a `std::string`.
  - rebalancing rotations rewrite parent/left/right, so `++it` follows pointers that are being written.
  - `find` copies `out = it->second` inside the guard (`:44-51`). The header comment is at `:12-14`.
- **Optional, not run:** remove the guard in `size()` and run `test_map_tsan`. It should report the write to `_M_node_count` (stl_tree.h, insert/erase) against the read in `size()`. That would be measured evidence instead of argument alone.

---
## Part 2: measure it

**Protocol row (3 pts).** Quote verbatim:
- **Node** (`part2_*/provenance.txt`):
  - `host: c207-021.frontera.tacc.utexas.edu`
  - `job: 7972219 partition=development`
  - `Cpus_allowed_list: 0-55` (the whole node)
  - kernel `3.10.0-1160.90.1.el7`, g++ 13.2.0 `-O2` (`build.txt`)
  - `scaling governor cpu0: performance`, `intel_pstate no_turbo: 0`
- **lscpu:**
  - `Model name: Intel(R) Xeon(R) Platinum 8280 CPU @ 2.70GHz`
  - `CPU(s): 56`, `Thread(s) per core: 1`, `Core(s) per socket: 28`, `Socket(s): 2`
  - L1d 32K, L2 1024K, L3 39424K
  - `NUMA node0 CPU(s): 0,2,4,…,54`, `NUMA node1 CPU(s): 1,3,…,55`
- **sweep.sh** (`part2_*/sweep/coarse.log`):
  - `# cores=56 hwthreads=56 sockets=2 cores/socket=28 pin order: 0 1 2 3 … 55`
  - `T=28        0.7 Mops/s  (0.7 0.7 0.7)  <- first socket full`
  - `T=56 … <- every core busy`
- **Median of three:** sweep.sh `median3` of three 2-s runs. Each run is printed in parentheses.
- **Pinning:** `taskset -c <first T CPUs of the pin order>`. This is process-wide affinity to a CPU set, not per-thread pinning. Describe it as "pinned to the CPU set".
- **Caveat that must be in the report:**
  - CPU numbers alternate between sockets (NUMA lines, `cpu_socket_map.txt`). In CPU-number order, T=2 is CPUs 0 and 1, which are on different sockets.
  - The `<- first socket full` tag is therefore wrong: at T=28 the threads are split 14 + 14. `part2_*/job.log` flags this in its WARNING block.
- **Supplementary curve:**
  - A copy of sweep.sh whose only measurement change is the pin order: `pin order: 0 2 4 … 54 1 3 … 55`. It also has a sysfs-path override used only for testing.
  - It ran on host c208-017, job 7972291 (`socketfirst_*/sweep_socketfirst/coarse.log`). There the T=28 tag is correct.

**Measured** (Mops/s, median (min–max) of 3, ops/ms from `coarse.raw`; the CSV rounds to 0.1):

| T | sweep.sh order (spans both sockets from T=2) | socket 0 first |
|---|---|---|
| 1 | 2.088 (2.072–2.090) | 2.084 (2.077–2.088) |
| 2 | 1.048 (1.045–**1.313**) | 1.108 (1.100–1.118) |
| 4 | 0.712 (0.710–0.744) | 0.954 (0.949–0.959) |
| 8 | 0.678 (0.675–0.688) | 1.054 (1.052–1.057) |
| 16 | 0.682 (0.670–0.692) | 1.060 (1.055–1.060) |
| 28 | 0.687 (0.676–0.693) | 1.046 (1.040–1.050) |
| 40 | 0.671 (0.665–0.674) | 0.695 (0.695–0.708) |
| 56 | 0.671 (0.667–0.676) | 0.672 (0.671–0.676) |
| 84 | 0.672 (0.672–0.678) | 0.676 (0.676–0.677) |
| 112 | 0.716 (0.716–0.717) | 0.705 (0.703–0.712) |

**Plot (part of the 3-pt row).**
- Linear axes. Solid vertical line at 56 (core count) and a lighter one at 28.
- Label the 28 line "socket boundary (true only for the socket-first order)".
- Plot medians from `.raw` with min–max bars, and overlay the predicted band from PREDICTIONS.md.
- The current `figs/part2_coarse.png` should be replaced:
  - It plots the 0.1-rounded CSV, so socket-first T=28 shows 1.0 against T=16's 1.1 although the medians are 1.046 and 1.060.
  - It has no prediction.
  - Its x-label says "one per core", which is wrong for T>56.

**Prediction row (2 pts).**
- The prediction is `PREDICTIONS.md` § Part 2, committed in `33f916a` at 2026-10-04 15:07:52 −0500.
- The 15:51 commit `76656b7` changed only the Part 5 text (two hunks; `git diff`).
- The Part 2 job started at 15:20:41 and the sweep at 15:20:59 (`part2_*/job.log`).

**Comparison row (3 pts):**

| Prediction | Measured | Held? |
|---|---|---|
| Peak at T=1, 2–3.5 Mops/s, 900–1400 cyc/op | Peak at T=1: 2.088. Perf run: 1445 cyc/op printed, 1524 f-corrected. The sweep's 2.088 implies ≈1580 at 3.30 GHz (*est.*). | Shape and level yes (low end of the range). Cycles 3–13 % over the range |
| T=2–4 at 40–60 % of T=1 | Socket-first: 53 % / 46 %. sweep.sh order: 50 % / 34 % | Yes on one socket. sweep.sh T=4 is below the band (cross-socket) |
| T=8–28 slowly falling plateau, 0.5–1.2 | Socket-first: 1.054 / 1.060 / 1.046. T=28 is 1.3 % below T=16 and the ranges just separate. sweep.sh: 0.678–0.687, flat within the spread | Level yes. The fall is ≤1.3 %, essentially flat |
| Step down 20–40 % past 28 | Socket-first: 1.046 → 0.695 = **−34 %** (spreads do not overlap). sweep.sh: nothing at 28 (0.687 → 0.671, inside the noise) | Yes, but only in the socket-first order. In sweep.sh order the drop to the cross-socket plateau comes at T=2→4: 1.048 → 0.712 (−32 %) |
| Flat or slightly lower past 56 | sweep.sh 0.671 → 0.672 → 0.716; socket-first 0.672 → 0.676 → 0.705 | Flat to 84, yes. At T=112 throughput is **higher** on both nodes (+7 %, +5 %, outside the spreads). Unexplained |

- **Not predicted, unexplained:** socket-first T=4 (0.949–0.959) dips below both T=2 (1.100–1.118) and T=8 (1.052–1.057). The spreads do not overlap. Mention it or leave it unclaimed.
- **Socket boundary.**
  - The two curves agree at T=1 (2.088 vs 2.084) and at T=56/84, where the CPU set is the same (0–55), to within 0.6 %. They ran on different nodes, so the gap between them at T=4–40 comes from the pin order, not the node. At T=112 they differ by 1.6 %.
  - Once threads sit on both sockets (≥2 per socket), throughput settles at 0.67–0.71 Mops/s. That is about two-thirds of the one-socket plateau (T=4: 0.712 vs 0.954, −25 %; T=28 → 40 in socket-first order: −34 %).
  - With one thread per socket (sweep.sh T=2) the penalty is only −5 % (1.048 vs 1.108).
  - Hypothesis for Part 3 (*not measured*): coherence transfers, and the kernel futex/wake traffic, cross UPI (published ≈110–150 ns against ≈40–70 ns on one socket). The counters cannot show this: every perf run used socket-0 CPUs only, and `remote_hitm` = 0 in all 18 runs.
- **Past 56.** There is no collapse. std::mutex waiters sleep in the futex, so the extra threads are mostly blocked rather than runnable. This is an argument only; no counters were taken at T>56.

---
## Part 3: explain it

**Which curve the counters describe.**
- All perf runs are on socket 0 only. Perf T=8 gives 1.040 Mops/s, socket-first T=8 gives 1.054, and the graded sweep.sh order gives 0.678. **The tables explain the one-socket curve.** The cross-socket 0.68 plateau has no counter evidence.
- The 5-s perf T=1 run (2.18 Mops/s) is 4.5 % faster than the sweep's 2-s T=1 run (2.09) on the same node. The cause is unexplained.

**Contended line (2 pts).** Name **line 0 of the `CoarseMap` object**, which is `alignas(64)`, 128 B in total.
- It holds the `pthread_mutex_t` in bytes 0–39 (`__lock` at 0, `__owner` 8, `__nusers` 12, `__kind` 16) and the map's root pointer at byte 56 (`concurrent_map.h:69-75`).
- Every operation:
  - loads `__kind`;
  - does a CAS on `__lock` to acquire;
  - stores `__owner`/`__nusers`;
  - reads the root;
  - on unlock, stores `__owner` and does `lock decl` on `__lock` (glibc 2.17, CentOS 7).
- Secondary: **line 1** (bytes 64–87: leftmost, rightmost, `_M_node_count`).
  - A new-key insert reads leftmost (hint check) and increments the count.
  - libstdc++ 13's `erase(key)` reads `size()` and `begin()` on every call (equal_range + `_M_erase_aux(first,last)`).
  - That is ≈15 % of ops reading and ≈10 % writing (*est.*: 80/10/10 mix, half the keys present).
- Third-order: tree-node lines written by insert, erase and assign.

**MESI between handoffs (3 pts).**
- **States.**
  - On the holder, line 0 is **M**: its CAS wrote it, and its unlock writes it again.
  - On every other core it is **I**, because the holder's RFO invalidated their copies. Sleeping waiters hold nothing.
  - Line 0 is in S only transiently (see step 1 below), because every access sequence on it ends in a write.
  - Line 1 is M on the core that last changed the size and S/I elsewhere.
  - The top tree levels sit in **S** in every core's L1/L2. They are read-mostly, so they cause no traffic.
- **A handoff, step by step:**
  1. The next acquirer's first touch is glibc's plain load of `__kind`. It misses L1/L2, and that load is what `xsnp_hitm` counts.
  2. The CHA/snoop filter forwards the request to the previous holder's core, whose unlock left the line M.
  3. The previous holder supplies the 64-B data, and the line goes to S.
  4. The CAS then sends an upgrade (invalidate): the old copy goes to I, the requester's to M. That is a second coherence step, which HITM does not count.
- **What moves:** one line holding the lock word, owner, nusers and root pointer. On ≈10–15 % of ops line 1 moves too.
- **Extra transfers.** A thread that arrives while the lock is held also does the `__kind` load (counted), a failed CAS and an `xchg` (lock := 2) before it sleeps, so it steals line 0. The holder's unlock (a store, then `lock decl`) must pull it back. A woken thread retries with `xchg`. An op can therefore cost two or three transfers.

**Cost of one handoff (2 pts).**
- **Missing input:** no "coherence session" number is in the repo. The student must insert it if they have one.
- Otherwise use the published CLX core-to-core latency: ≈40–70 ns ≈ 130–230 cycles at 3.30 GHz on one socket, and ≈110–150 ns ≈ 350–500 cycles across sockets (PREDICTIONS.md machine-facts table).
- **Data cross-check** (:u, T=1→8): +1004 user cyc/op and +9.58 L1 misses/op, of which 0.93–1.32 are HITM.
  - Upper bound per counted HITM, run by run: 988/1.249 = 791, 1004/0.933 = 1076, 1009/1.315 = 767 → **≈770–1080 cyc (230–330 ns)**.
  - Charge the other ≈8.65 extra misses as L3 hits at 50–70 cyc (430–610 cyc). Using the median run, that leaves ≈400–570 cyc ≈ 430–610 cyc per HITM ≈ 130–190 ns. This assumes no overlap between misses and still includes uncounted upgrade/RFO transfers and waiters' failed CAS.
  - So the cost per transfer is of order 10² cycles, consistent with the published range (*est.*).

**Counter table (3 pts).** Printed per-op values [f].
- Events: `cycles, instructions, L1-dcache-loads, L1-dcache-load-misses, cache-misses, mem_load_l3_hit_retired.xsnp_hitm, mem_load_l3_miss_retired.remote_hitm, context-switches, cpu-migrations, task-clock`.
- CPU lists: `0` / `0,2,…,14` / `0,2,…,54` (socket 0). Runs are 5 s; per-op = count / ops of the timed run.

| | T=1 all | T=1 :u | T=8 all | T=8 :u | T=28 all | T=28 :u |
|---|---|---|---|---|---|---|
| ops (timed run) | 10,908,672 | 10,643,456 | 5,204,992 | 5,092,352 | 5,087,232 | 5,074,944 |
| Mops/s (min–max) | 2.182 (2.175–2.183) | 2.129 (2.126–2.131) | 1.040 (1.039–1.040) | 1.018 (1.017–1.019) | 1.014 (0.997–1.016) | 1.012 (0.997–1.023) |
| cycles/op | 1445 | 1465 | 11,110 | 2469 | 65,810 | 2889 |
| instructions/op | 330.5 | 323.6 | 4907 | 353.5 | 11,060 | 361.4 |
| IPC | 0.229 | 0.221 | 0.442 | 0.143 | 0.168 | 0.125 |
| L1 misses/op | 25.29 | 24.26 | 143.7 | 33.84 | 225.4 | 38.18 |
| LLC misses/op | 0.489 | 0.508 | 0.975 | 0.911 | 0.829 | 0.843 |
| HITM/op (min–max) | 0.0003 | 3.3e-6 | 17.74 (17.72–17.79) | **0.933 (0.93–1.32)** | 37.39 (37.25–37.43) | **1.548 (1.18–1.55)** |
| remote HITM/op | 0 | 0 | 0 | 0 | 0 | 0 |
| context switches/op | 2.8e-7 | 8.5e-7 | 0.528 | 0.544 | 0.759 | 0.766 |
| CPUs on-CPU (task-clock) | 1.01 | 1.01 | 4.38 / 8 | 4.35 / 8 | 22.28 / 28 | 22.21 / 28 |

- **Other spreads:**
  - all: cyc/op 1443–1449, 11,080–11,110 and 65,650–67,570. L1/op at T=1 is 24.48–25.29.
  - :u: cyc/op 1464–1468, 2453–2474 and 2854–2910.
- **cpu-migrations:** T=8 95–110 (all) and 306–322 (:u); T=28 677–952 (all) and 2252–2921 (:u) per 5-s run, ≤6e-4/op. They are nonzero because the pinning is to a CPU set.
- **Footnote:** in the :u files the `L1-dcache-*` lines print without the `:u` suffix, but the command line requests `:u`. The load counts (483 M vs 7,403 M at T=8) confirm they are user-only.
- **Against PREDICTIONS.md's Part 3 sanity table:**
  - Held: HITM 1–4 (measured at the low end) and context switches 0.1–1.
  - Missed: cycles 2–4× (:u 1.69×, all 7.7×), L1 +3–6 (+9.6) and LLC 1–4 (0.5).

**Q1: L1 misses per op at T=1.**
- Measured 24.26–24.31 (:u) and 24.48–25.29 (all); ≈25.6–26.7 after the f correction.
- The tree has 2¹⁹ = 524,288 nodes: warm-up inserts the even keys (`bench.cpp:122`), and the 80/10/10 mix keeps it about half full. A lookup walks ≈19–20 levels.
- L1d is 32 KB = 512 lines, enough for the top ≈8 levels (255 nodes) next to the stack and the 2.5 KB mt19937_64 state. That leaves ≈11–12 levels that miss L1.
- L2 is 1 MB = 16,384 lines, enough for about the top 13–14 levels. So ≈5–6 of those misses hit L2 and ≈6 go to L3.
- The nodes take ≈32 MB in 64-B chunks, which fits in the 38.5 MB L3. LLC misses of 0.48–0.51/op confirm that almost nothing goes to DRAM.
- The prediction was 10–14; the measurement is ≈2× that. It is consistent if each L1-missing level costs **two line fills**: 2 × (20 − 8) ≈ 24. Possible reasons:
  - the counter counts lines brought into L1, including L1 prefetch fills (README);
  - a lookup reads left/right (node+16..31) and the key (node+32), which sit on two lines when the node starts at byte 32 of a line. The warm-up nodes are 64 B apart, so either all straddle or none do;
  - inserts and erases add ≈1–2 misses per op of their own (*est.*).
- This is a hypothesis. It can be checked by printing node addresses mod 64.

**Q2: growth factors T=1→T=8 (and T=28).**
- :u: cycles/op ×**1.69** while L1 misses/op ×**1.39** (T=28: ×1.97 and ×1.57). Instructions/op rise only +9 %.
- all: cycles/op ×**7.69** while L1 misses/op ×**5.68** (T=28: ×**45.5** and ×**8.9**).
- **Why they differ: the marginal cost of a miss.**
  - At T=1 the average is 1465/24.26 ≈ 60 cyc of total time per miss, because most misses are L2 hits (~14 cyc) or L3 hits (50–70).
  - At T=8 each extra miss costs 1004/9.58 ≈ **105 cyc**. Priced as L2 hits, the 9.58 extra misses would add only 134 cyc (+9 %), not +1004 (+69 %).
- The extra misses are expensive kinds:
  - about one HITM per op on line 0 (≈130–230 cyc, published);
  - upgrade/RFO transfers, which are not counted;
  - L3 refills of tree lines this core lost. Two possible causes (*hypotheses, untested*): the kernel futex/scheduler code now running on the same cores (≈110 kernel L1 misses/op, *est.* all − :u), or idle cores dropping L1/L2 contents in deep C-states (cores are off-CPU 45 % of the time at T=8).
- **In all mode the kernel path dominates.**
  - Per op at T=8 it adds ≈+8,640 cyc, +4,550 instructions, +110 L1 misses and +16.8 HITM (*est.* all − :u). That is 78 % of cycles at T=8 and 96 % (≈62,900 cyc) at T=28.
  - Per context switch the kernel spends ≈16,400 cyc (≈5–6 µs, given the 2.78–3.3 GHz clock) at T=8 and ≈82,900 cyc (≈25–26 µs) at T=28.
  - Kernel IPC falls from ≈0.53 to ≈0.17, with ≈32 → 47 kernel HITM per context switch. That fits waiters contending inside the kernel on shared lines: they all sleep on the same futex word, so they share one futex hash-bucket lock, plus run-queue wakeups (*hypothesis*: no kernel profile was taken).
  - This is why at T=28 cycles grow 45× while misses grow only 9×.
  - The all-mode IPC rises to 0.442 at T=8 because the denser kernel code dilutes the pointer-chasing user code.

**Q3: HITM vs handoffs.**
- *Estimate* of counted line-0 misses per op:
  - one per acquisition whose previous owner was another core, at most (T−1)/T = 0.88 (T=8) and 0.96 (T=28). Barging re-acquisitions by the releasing core cost none;
  - plus one `__kind`-load miss per arriving thread that fails and sleeps (≈ sleeps/op = 0.53 and 0.76);
  - plus line 1 at ≈0.10–0.15;
  - plus a little allocator metadata.
  - Range: ≈0.9 up to ≈1.7 (T=8) and ≈1.9 (T=28).
- *Measured* (:u): 0.93–1.32 at T=8 and 1.18–1.55 at T=28, inside the range.
  - From T=8 to T=28, mean HITM rises by ≈0.25/op (1.17 → 1.42) while sleeps/op rise by ≈0.21 (0.544 → 0.754). That is consistent with one counted miss per failed arrival (*est.*).
  - Measured values below the upper bound mean some acquisitions are barging re-acquisitions with no transfer.
- Read the **all-mode** HITM (17.7 and 37.4) as mostly kernel lines (≈32–47 per context switch), not lock handoffs.
- The T=1 HITM is ≈0, as expected.

**Q4: what context switches per op say, and why worse rather than flat.**
- **Where the time goes.**
  - With T ≤ cores, context switches are futex sleeps (migrations ≤6e-4/op).
  - At T=8 (0.53/op) about every second operation puts a thread to sleep; at T=28 (0.76/op) about three in four do.
  - Threads are on-CPU only 55 % (T=8, 4.38/8) and 80 % (T=28, 22.3/28) of the time, and 78–96 % of those cycles are kernel (*est.*).
  - Summed user cycles (f-corrected) are ≈0.80 (T=8) and 0.94 (T=28) of one 3.3 GHz core: about one core's worth of map work. The threads mostly sleep on, or run kernel code for, the futex.
- **Why worse rather than flat.**
  - Pure serialization would hold the T=1 rate, 2.09 Mops/s.
  - **(a) The serialized path gets longer.** The acquirer's `__kind` load (HITM), the CAS upgrade, the unlock's pull-back after a waiter's `xchg`, and line-1 transfers all sit on the path from one critical section to the next. User cycles/op go 1465 → 2469 → 2889, and per-op time goes 0.47 → 0.98 µs.
    - The user-cycle growth (1059 f-corrected cyc ≈ 0.32 µs at 3.3 GHz, ≈63 % of the 0.51 µs loss) is an **upper bound** on that effect. Part of it is waiters' own stalls (failed CAS, `xchg`; ≈0.5 sleeps/op × 2–3 transfers), which overlap the holder.
    - A plausible share is ≈40–60 % of the loss (*est.*; more if the T=8 clock really was 2.78 GHz).
  - **(b) Futex round-trips cost µs, against a 0.46 µs operation.** Once a waiter has set the word to 2, every unlock makes a `futex_wake` syscall. The unlocker, the thread most likely to barge, is then in the kernel, so the free lock can sit idle until some thread gets back to user mode.
  - **(c) More threads means more sleepers and more kernel work,** but that extra work is mostly off the critical path. Throughput stays flat from T=8 to T=28 (1.04 → 1.01 Mops/s) while on-CPU cores grow from 4.4 to 22.3 and kernel cycles/op grow 7×. The cores burn, the map does not get faster.
  - **(d) Across sockets every transfer and wakeup crosses UPI.** This gives the 0.7 Mops/s plateau of the graded curve (*hypothesis*: no remote-HITM counts were taken, and at T=2 the cross-socket cost is only 5 %).



---

## Part 4: Shard it (report notes)

**Paths.** `P4` = `results/part4_20261004-152326_7972219` (host c207-021), `SF` = `results/socketfirst_20261004-153710_7972291` (c208-017), `P5` = `results/part5_20261004-160149_7972388` (c201-033), `TS` = `results/tsan_ls6_20261004-165301_3488178` (repeat: `tsan_ls6_20261004-161507_3488118`).

**Numbers.** Every throughput is the median of 3 runs, with (min..max) after it, recomputed from the `.raw` op counts and ms. All runs are pinned and 2 s long. Do not mix in the rounded CSV values: the coarse CSV shows 0.7 at T=56, but the raw median is 0.67.

**Nodes.** Three Frontera nodes were used, and where they overlap they agree within 0.5%. Say this once in the report:
- T=1, N=256: 2.95 (P4) vs 2.94 (SF)
- T=1, N=4096: 3.61 (P4) vs 3.61 (P5)
- T=56, N=256: 53.97 vs 53.81

### (a) Code passes `make test` and `make tsan` (4 pts)
- Evidence: `TS/tsan_summary.txt`. Built on LS6 with g++ 15.2.0 and the Makefile `TSAN` flags (`-std=c++20 -O1 -g -fsanitize=thread`). Staff confirmed that TSan cannot run on Frontera (`edposts.txt`, Q#19).
  - `test_map_tsan`: exit 0, "all checks passed", 0 ThreadSanitizer WARNING/SUMMARY lines.
  - `test_locks_tsan`, `test_map` and `test_locks` (plain builds) also exit 0.
  - `race_control` (the positive control) exits 66 with a TSan SUMMARY line, so TSan was active.
- `test_map_tsan.stdout` shows **"concurrent size(), exact"** passing for all 10 ShardedMap variants: mutex, mutex(1 shard), shared_mutex, mutex-nopad, TAS, TTAS, Ticket, Parking, RW, RWWP. The repeat run is identical.
- The tested code is the benchmarked code. `concurrent_map.h` (efbf5aae…) and `locks.h` (a68b2df2…) have the same md5 in both TSan runs, in every Frontera `provenance.txt`, and in the current `starter_files`.
- **Still to do.** The TSan runs used `parts.h` with **HAVE_HASHED = 0** (md5 9a87e01c…).
  - The current `parts.h` (HAVE_HASHED = 1, md5 2e7c9dd6…) and `hash_map.h` were edited at 17:02, after the last TSan run (16:56).
  - Rerun `make tsan` on LS6 with the final files and quote those summary lines, since graders build with every switch set to 1.
  - Part 4's code is unchanged, so the Part 4 evidence stands.

### (b) Lock order and approximate `size()` (4 pts)
The code is `concurrent_map.h` lines 120–133. `size()` locks shards 0..N−1 in ascending order, sums, then unlocks in reverse. Insert and erase take one shard with `lock_guard`; find takes one shard with `ReadGuard`, which for std::mutex is the same exclusive lock.

**General argument.** Suppose a waits-for cycle existed: T₁ waits for l₁, held by T₂; T₂ waits for l₂, held by T₃; and so on back to T₁.
- Every thread in such a cycle holds a lock while it waits.
- Only `size()` does that, and it only ever waits for a *higher* index than any lock it holds.
- So l₁ < l₂ < … < l₁, which is a contradiction.
- insert and erase can also take glibc malloc's arena lock inside `operator new`/`delete`. That is a leaf lock: no thread holding it ever requests a shard lock, so it adds no edge.

**Two `size()` callers.**
- Both start at shard 0. Whichever comes second blocks on lock 0 while holding nothing, so it cannot be part of a cycle.
- Unlocking is in reverse order, so lock 0 is released last. The second caller proceeds only after the first has finished.
- Example of the deadlock the README warns about (the example is ours): if A went 0→N−1 and B went N−1→0, A could hold 0 and wait for N−1 while B holds N−1 and waits for 0.

**`size()` against insert, erase and find.**
- Each of these holds exactly one shard lock and never waits for another shard lock while holding it.
- Each therefore either waits holding nothing, or runs to completion and releases. `size()` simply waits for it.

**Exactness.**
- Once the last lock is taken, no mutation can be in progress in any shard. The sum is the size at that instant, which is the linearization point.
- An op on shard i counts if and only if it released lock i before `size()` acquired lock i.

**Approximate version** (lock i, read, unlock, move on). It returns Σᵢ sᵢ(tᵢ), with each shard read at a different time t₀<…<t_{N−1}.
- It is still data-race-free.
- Bounds: Σᵢ min sᵢ ≤ result ≤ Σᵢ max sᵢ over the duration of the call.
- Against the true total S(t) at any instant in the call, the error is at most the number of successful inserts and erases that complete during the call.
- It can return a value the map **never held**:
  - Over-count: after the sweep passes shard 0, erase a from shard 0, then insert b into shard 5. The true size goes S → S−1 → S, but the result is S+1.
  - Under-count: insert b into shard 0 after the sweep has passed it, then erase a from shard 5 before the sweep reaches it. The true size goes S → S+1 → S, but the result is S−1.
- It is exact only with no concurrent mutation. With inserts only, it lies between S(start) and S(end).
- In the test, the sliding windows (insert base+64+r, erase base+r) *can* push it outside the exact bound [W·PAIRS, W·PAIRS+W] = [256, 260] (`tests/test_map.cpp` lines 111–159).
- Cost of exact `size()` at N=4096 (*estimate, not measured*):
  - 4096 lock acquisitions plus 4096 header reads, each touching a different shard's lines: roughly 0.1–0.5 ms.
  - Every op (finds included) on an already-locked shard is stalled for that time.
  - The cost is linear in N.

### (c) Sharded curve on the coarse axes (2 pts): `figs/part4_coarse_vs_sharded.png`
Sources: `P4/sweep_shards256/sharded_mutex.raw`, `P4/sweep_coarse_ref/coarse.raw`, `SF/sweep_socketfirst/{sharded_mutex,coarse}.raw`. "sweep.sh order" means CPU-number order, which on this node alternates sockets.

| T | coarse (sweep.sh order) | sharded N=256 (sweep.sh order) | sharded N=256 (socket-first) |
|---|---|---|---|
| 1 | 2.09 (2.08..2.09) | 2.95 (2.94..3.02) | 2.94 (2.94..2.95) |
| 2 | 0.99 | 3.84 (3.68..3.92) | 5.28 (5.25..5.42) |
| 8 | 0.68 | 12.65 (12.42..12.77) | 17.37 (17.33..17.38) |
| 28 | 0.68 | 34.73 (34.48..34.74) | **44.89 (44.82..44.94)** |
| 40 | 0.68 | 44.14 (44.08..44.39) | 43.86 (43.73..44.10) |
| 56 | 0.67 (0.67..0.68) | **53.97 (53.76..54.18)** = peak | 53.81 (53.77..53.87) |
| 84 / 112 | 0.68 / 0.70 | 52.65 (52.58..52.69) / 52.35 (52.28..52.46) | 52.60 / 52.40 |

**Peak at T=56.**
- 18.3× its own T=1 and about 80× coarse (53.97/0.67).
- At T=1 it is already 41% faster than coarse (2.95 vs 2.09). That is net of a sharding overhead: sharded N=1 is 5% *slower* than coarse (1.98 vs 2.09, non-overlapping spreads), i.e. +27 ns ≈ 88 cycles for the `% N` 64-bit divide plus the indirection. The smaller-tree gain from N=1 to 256 alone is +49% (see d).

**Why N=256 bends over.**
- At T=56, p = 1−(1−0.9/256)^55 = 17.6%.
- With c from (d), collisions cut per-thread throughput to e ≈ 0.49–0.52, roughly half.
- Cross-check: the N=4096 sweep reaches 115.6 (110.3..115.6) at T=56 (`P5/sweep_shards4096/sharded_mutex.raw`). That is 2.14× (2.04..2.15) the N=256 value. The model predicts 2.17× with c = 1.75 µs, or 2.29× with the self-consistent fit. Different node, same CPU set.

**Past 56 cores.**
- Throughput drops 2.4% at T=84 and 3.0% at T=112. The ranges do not overlap with T=56 (53.76..54.18).
- The drop is small because std::mutex waiters sleep rather than spin. Oversubscription adds only context switches and the occasional preempted lock holder.

**Interleaving effect.**
- sweep.sh order crosses the socket boundary from T=2.
- Socket-first is 29–38% higher for T=2..28. At T=28 it is 44.9 vs 34.7, i.e. 1.60 vs 1.24 Mops/s per thread.
- Cleanest figure: at T=2 the per-op time is 521 ns with CPUs 0 and 1 (different sockets) vs 379 ns with CPUs 0 and 2 (T=1: 339 ns).
- Reason: a shard's lock line (line 0, written by every op) and header line (line 1, written by every successful insert/erase), plus recently written nodes, often come from a core on the other socket over UPI. Remote cache-to-cache transfers take about 110–150 ns against about 60–70 ns on the same socket (*published figures, estimate; no counters for this config*).
- Socket-first T=40 (28+12 threads) gives 43.9 (43.73..44.10), *below* its T=28 value of 44.9 (44.82..44.94). Per-op time per thread rises from 624 to 912 ns once lines start crossing UPI.
- The two orders converge at T=40 (44.1 vs 43.9) and T=56 (same CPU set).
- **Fix the figure:**
  - The dashed T=28 "socket boundary" applies only to the socket-first curves.
  - Label the curves by pin order rather than by directory name.
  - The coarse curves (~0.7) are flattened against zero: annotate their values or add an inset.

### (d) Shard-count sweep, T=1 and T=32 (4 pts)
Sources: `P4/shardcount/T{1,32}/N*/sharded_mutex.raw` and `P4/shardcount_sharded_mutex.csv`. T=32 is pinned to CPUs 0–31, which is **16 cores on each socket**; say so, and say why T=32 was chosen. Measured e = R/R(4096). Predicted e uses convention A below (c = 1.75 µs, f = 0.9).

| N | keys/shard (eq.) | T=1 Mops/s | t₁ (ns) | T=32 Mops/s | R=T32/T1 | p=31·0.9/N | p·c/t₁ | predicted e | measured e |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 512K | 1.98 (1.98..1.98) | 505 | 0.73 (0.73..0.74) | 0.37 (0.37..0.37) | | | | |
| 4 | 128K | 2.42 (2.42..2.48) | 413 | 2.69 (2.69..2.70) | 1.11 (1.08..1.12) | | | | |
| 16 | 32K | 2.62 (2.61..2.65) | 382 | 8.68 (8.63..8.70) | 3.32 (3.26..3.33) | | | | |
| 64 | 8K | 2.78 (2.78..2.78) | 359 | 21.09 (21.02..21.13) | 7.57 (7.55..7.61) | 0.436 (exact 0.355) | 1.73 (exact p) | 0.37 | 0.375 (0.371..0.381) |
| 256 | 2K | 2.95 (2.94..2.95) | 339 | 38.11 (38.00..38.12) | 12.94 (12.89..12.99) | 0.109 | 0.56 | 0.64 (fit point) | 0.640 (0.634..0.650) |
| 1024 | 512 | 3.15 (3.14..3.16) | 318 | 54.12 (53.92..54.84) | 17.20 (17.07..17.47) | 0.027 | 0.15 | 0.87 | 0.851 (0.839..0.874) |
| 4096 | 128 | 3.61 (3.61..3.61) | 277 | 72.97 (72.25..73.39) | **20.20 (19.99..20.34)** | 0.0068 | 0.043 | 0.96 (but fit assumed 1) | 1 (by definition) |
| 16384 | 32 | 4.48 (4.46..4.48) | 223 | 91.09 (90.90..91.33) | **20.35 (20.29..20.46)** | 0.0017 | 0.013 | 0.99 | 1.007 (0.998..1.024) |

**Smaller-tree effect (T=1 column; no contention).**
- T=1 throughput rises ×2.26, from 1.98 to 4.48 Mops/s, as N goes from 1 to 16384.
- `std::hash<long>` is the identity, so `k % N` cuts each tree's depth by ≈log₂N levels of a ~19-level dependent pointer chase, at the price of one computed index. A shard is a residue class spanning the whole key range, not a subtree, so this is a depth equivalence rather than literally removing the top levels.
- Each removed level was a dependent load plus a roughly 50/50 compare branch. *Mispredicts are inferred; no branch-miss counter was collected.*
- Saving per removed level, from differences in t₁ at 2 levels per 4× step, at ≈3.3 GHz (*estimate*: Part 3 T=1 gives 1445 cyc/op printed ÷ f 0.948 × 2.182 Mops/s = 3.33 GHz):
  - **N=4→1024: 10–16 ns ≈ 33–51 cycles per level.** These are shallow levels, roughly L1/L2-resident.
  - **N=1024→16384: 20–27 ns ≈ 67–88 cycles per level.** These are deeper, L2/L3-resident levels. Part 3 measured ≈25 L1 misses/op at T=1 (`part3_table.tsv`, as printed), and that miss stream keeps evicting mid-tree lines.
- What is paid in exchange:
  - 1–2 lines of the shard array, which is N×128 B: 512 KB at N=4096, 2 MB at N=16384.
  - The `% N` divide runs at every N, including N=1, because the divisor is a runtime value. It is roughly constant, though 64-bit DIV latency on CLX is data-dependent; per-N cost not measured. Its total with the indirection is 27 ns (see c).
- **N=1→4 is an outlier: 92 ns, i.e. 46 ns per level, 3–5× the N=4..1024 steps.** It is *unexplained*. The warm-up artifact below is worth only about 6–9 ns at N=4 (≤27 ns at most). An odd-N control (N=3 or 4095) or a perf run at N=1 vs N=4 would settle it.
- *Footnote (Part 3 counters):* values are perfstat output as printed. The true per-op value is printed ÷ f (f=0.948), i.e. about +5.5%.

**Warm-up artifact** (*analytic model, not measured*).
- The warm-up inserts only even keys and the hash is the identity, so for every even N (every N here except 1) the odd shards start empty.
- Each key toggles at rate 0.1·X/2²⁰ each way, so the relaxation time is τ = 2²⁰/(0.2·X).
- **T=1: τ = 1.2–2.2 s**, comparable to the 2-s run.
  - Odd shards average only 17–26% full (equilibrium 50%), while even shards start over-full.
  - Averaged over all ops, the trees are 0.34–0.58 levels shallower.
- **T=32, N≥256: τ = 0.06–0.14 s**, i.e. 3–7% of the run.
  - The time-averaged odd-shard fill is 47–49%, and the depth effect is −0.02..−0.04 levels.
- Consequences:
  - (i) It speeds up T=1 at every even N but not at N=1. It is too small to explain the N=1→4 outlier.
  - (ii) It biases R low by about 1.5–3% at N=256, rising to about 4% at N=16384 (*estimate*). That flattens the measured 4096→16384 R step by about 1%. It does not change N.
  - (iii) It does not change p, because the shard is chosen by a uniform random key.

**Contention effect (the R column).**
- R rises steeply up to N=4096 and then stops: 20.20 → 20.35, a +0.7% change (range −0.2..+2.3%), i.e. equal within the spread.
  - The established "20.3 vs 20.2" came from rounded CSV values; the raw-file medians reverse the order but the ranges overlap.
- Raw T=32 throughput still rises ×1.248 from N=4096 to 16384, but T=1 rises ×1.239 over the same step. That gain is the tree effect, not contention.
- The plateau R ≈ 20.2 (63% of linear) means an op at T=32 takes 1.51–1.58× as long as at T=1, about +160 ns at N=4096. The range reflects whether the model's 4–5% collision term at 4096 is subtracted. The same slowdown appears at N=16384, where p is 4× smaller, so the plateau is not collisions.
  - *Likely cause (estimate, no counters at T=32):* coherence misses. Line 0 is written by every op and line 1 by every successful insert/erase, and about 31 other-thread visits happen between two visits by the same core. With 16+16 placement, about half of those transfers cross UPI. A socket-first T=32 sweep would give a different plateau.
  - Clock: about 3.33 GHz at T=1 (*estimate*) and 3.30 GHz with 8 busy cores (`P5/job.log`). The T=32 clock (16 busy cores per socket) was not measured.

**Collision argument (each term with a figure).**
- **Model.** Per-thread op time at T=32 = s·t₁ + p·c. Hence e = R/R∞ = 1/(1 + p·c/(s·t₁)).
- **Convention A (used in the table).** Absorb s into c: e = 1/(1+p·c/t₁), with R∞ taken as R(4096).
- **f ≈ 0.9 (estimate).** Outside the lock an op does two mt19937_64 draws, the `% N` divide (part of 27 ns) and loop overhead, about 25–35 ns, against t₁ = 223–339 ns.
  - Only f·c is identified, so f rescales c but leaves the predicted e and the choice of N unchanged. With f=1, c = 1.58 µs.
- **p ≈ (T−1)·f/N at T=32:** 10.9% (N=256), 2.7% (1024), 0.68% (4096), 0.17% (16384). At N=64 the exact form 1−(1−f/N)^31 = 35.5% is needed.
- **Collision cost c, fitted at N=256:**
  - Convention A: c = (20.20/12.94 − 1)·339 ns / 0.109 = **1.75 µs**, in T=1 time units.
  - In wall-clock time added to a T=32 op: c·s = 1.75 × 1.58 = **2.8 µs**.
  - Either way, **≈5.2 uncontended ops at the same T**: 339 ns at T=1, or 538 ns at T=32.
  - Other fits:
    - Self-consistent two-parameter fit through N=256 and 4096: c = 1.99 µs, R∞ = 21.2.
    - Least-squares fits over N=64..16384: c = 1.73–1.91 µs, R∞ = 20.2–20.7.
  - Interpretation: glibc's default mutex does not spin. After one failed CAS a collision costs a futex_wait sleep, the holder's futex_wake syscall, the wake-up latency and the rest of the holder's critical section.
- **Uncontended op cost:** t₁ = 339 / 318 / 277 / 223 ns at T=1 for N = 256 / 1024 / 4096 / 16384. At T=32, ×1.58: 538 ns at N=256, 439 ns at N=4096.
- **p·c compared with the uncontended op** (the same ratio in either convention): 56% at N=256, 15% at 1024, **4.3% at 4096** (4.9% with the self-consistent fit), 1.3% at 16384.
- **Predicted vs measured.**
  - Convention A: 0.87 vs 0.851 (0.839..0.874) at N=1024, and 0.37 vs 0.375 at N=64. These agree within the spread.
  - But A predicts +2.9% from N=4096 to 16384, while +0.7% (−0.2..+2.3%) was measured. A also predicts e(4096) = 0.96 after the fit assumed it was 1.
  - The self-consistent fit predicts R/R(4096) = 0.31 / 0.90 / 1.033 for N = 64 / 1024 / 16384, against 0.375 / 0.851 / 1.007 measured.
  - So the measured knee is sharper than 1/(1+pc/t). Every variant agrees on the conclusion: the collision term is 15–17% at N=1024 and 4–5% at N=4096.

**Choice: N = 4096.**
- It is the smallest N at which the collision term is a few percent, and its R equals N=16384's within the spread.
- N=16384 does give +25% raw T=32 throughput, but all of that is the T=1 tree effect, which Part 7's hash table gets more cheaply.
- Memory (128 B per shard) and the cost of exact `size()` grow linearly with N.

**Against `PREDICTIONS.md` Part 4.**
- **"T=1 flat ±15%" was wrong.** Measured: +126% from N=1 to 16384, and +49% even from N=4 to 4096.
  - The prediction assumed the removed levels were cheap L1 hits, and that a miss on the shard array would offset them. It also sized the shard at 64 B; it is 128 B.
  - In fact each level costs 33–51 cycles near the top and 67–88 deeper, while the shard array adds only 1–2 lines.
- **"Knee near 1024; ship 1024" was off by one step.** R gains +17% (+14..+19%) from N=1024 to 4096 and is flat after that.
  - The prediction's own model said N=1024 costs 1.27× vs 1.07× at 4096, i.e. +19% to gain. "Flat within noise after 1024" contradicted it. Measured costs: ×1.56 / 1.17 / 1.00 at N = 256 / 1024 / 4096, against ×2.09 / 1.27 / 1.07 predicted.
  - The fallback clause ("4096 if its gain is larger than the run-to-run spread") is what applies. Do not present N=4096 as the primary prediction.
- **Collision cost.**
  - The predicted 2–5 µs futex cost is a wall-clock figure. The measured wall-clock equivalent is 2.8 µs, *inside* that range.
  - What was over-predicted is the ratio: ≈10 ops predicted vs 5.2 measured. The prediction divided by the T=1 op cost (0.3–0.4 µs), whereas an uncontended op at T=32 costs 0.44–0.54 µs, and c is at the low end of the range.
  - Over-predicting c/t biases the predicted knee *upward*, so it cannot explain a predicted knee that was too low.
  - The miss came from the decision threshold and the T=1-flat assumption, since the tree effect keeps raw T=32 throughput rising.
- The p values the prediction used (11%, 2.7%, 0.7%) match those above.


---

## Part 5 notes: write the locks

Paths are relative to `lab1/results/`. P5 = `part5_20261004-160149_7972388` (Frontera c201-033, g++ 13.2, `locks.h` md5 a68b2df2…, the same as the TSan runs). The predictions were made before the runs: the Part 5 section of PREDICTIONS.md was committed at 15:51:29, the P5 job started at 16:01:49 and the 1-shard perf runs at 16:08.

**Footnote (state once):**
- perfstat per-op values are given as printed. The count window covers f = 0.947–0.962 of the run, so the true per-op value ≈ printed/f.
- The `busy` column already divides by f: busy = cyc/op ÷ f × Mops·1e6 ÷ (8 × 3.30 GHz). The README formula without f gives 0.88–0.95 instead of 0.92–1.00.
- The perf runs use the socket-0 list S0_8 = 0,2,…,14, not `CPUS=0-7`.
- The 32-on-8 runs use N = 4096, not the README's 256.
- The clock is 3.300–3.302 GHz in all 15 32-on-8 runs (cycles/ref-cycles × 2.7).
- Remote HITM/op is ≤ 6.3e-4 (all-modes) and ≤ 1.5e-6 (user) in the 1-shard tables, so all 8 CPUs are on one socket. HITM was not collected in the 32-on-8 runs.

### (1) Tests and TSan (6 pts)
- **Runs:** `tsan_ls6_*/tsan_summary.txt` covers two Lonestar6 runs with g++ 15.2 and every part enabled except Part 7 (HAVE_HASHED 0).
  - Both runs: `test_map_tsan` exit 0, `test_locks_tsan` exit 0, "all checks passed", 0 ThreadSanitizer WARNING/SUMMARY lines.
- **Under TSan:**
  - Each lock passes 8 threads × 5000 and **64 threads × 250**, each taking at most 0.4 s.
  - `ShardedMap<TAS|TTAS|Ticket|Parking>` passes the sequential, disjoint, contended and concurrent-`size()` tests.
- **Plain builds:** also exit 0 (8 × 20000, 64 × 1000).
- **Positive control:** `race.cpp` exits 66 with a race SUMMARY, so TSan was active.
- **Why the 64-thread test finishes:** TAS and Ticket spin with *relaxed* operations and pay one acquire load after winning.
  - According to the `locks.h` comment, spinning with acquire exchanges starves the unlocker inside TSan's per-address synchronization. That mechanism was not tested.
  - Ed #19, a student's question, reports 64 × 250 stalling for TAS and Ticket under TSan. Staff replied only that TSan slowdowns are expected.

### (2) Relaxed-ordering experiment (`relaxed_20261004-161717/`, LS6, g++ 11.2)
- **Change:** TTASLock is now all relaxed. The winning `exchange` went from acquire to relaxed and `unlock` from release to relaxed; the spin load was already relaxed (`locks_relaxed.diff`).
- **Plain `make test`:** `test_map` and `test_locks` both exit 0 with "all checks passed", so the counter was exact and there were 0 violations.
- **TSan (both programs run separately):** both exit 66 with one warning each.
  - `test_locks`: data race at `test_locks.cpp:62` (`if (++inside != 1)`), a 4-byte read by T2 against an earlier write by T1, inside `test_mutual_exclusion<TTASLock>`.
  - `test_map` (disjoint-keys test): T14's `std::map::lower_bound` inside `ShardedMap<…,TTASLock>::insert` (`concurrent_map.h:99`) reads a node key. TSan's "previous write" is T13's allocation of that node (`operator new` ← `_M_create_node`) in its own insert. The next holder walked into a node the previous holder had published with no happens-before edge between them.
- **What acquire/release forbid:**
  - Acquire on the winning RMW: no critical-section read or write may move above the acquisition.
  - Release on unlock: no critical-section access may move below the releasing store.
  - When the acquire reads the release's value (or a later RMW in its release sequence), it synchronizes-with it. Everything the previous holder did then happens-before everything the next holder does.
- **What relaxed allows:** the RMW is still atomic, so mutual exclusion on `held_` still holds. But the compiler and the CPU may move the protected accesses out of the locked region, and there is no happens-before edge. In the C++ model `inside` and `counter` race, which is undefined behaviour.
- **Why the plain run did not notice:** x86-64 is TSO.
  - `xchg` with a memory operand is implicitly LOCKed, which makes it a full barrier.
  - A plain `mov` store (the unlock) is never reordered with earlier loads or stores.
  - So relaxed and acq/rel compile to the same `xchg`/`mov`, and only compiler reordering could break the test.
  - We infer that GCC did not move the plain accesses across the atomics. The binary was not disassembled.
  - The same result was seen earlier locally with g++ 13.3 (recorded in PREDICTIONS as a measurement, not a prediction).
- **Why TSan noticed:** it checks the C++ model. It derives happens-before from the `memory_order` of each atomic, so relaxed operations give no edge, and it flags the race whatever the hardware did. On ARM or POWER the plain test could actually fail.

### (3) Five-lock sweep, N = 4096 (`figs/part5_five_locks.png`, P5 `sweep_shards4096/*.log`)
Mops/s, median (min..max of 3):

| T | mutex | TAS | TTAS | Ticket | Park |
|---|---|---|---|---|---|
| 1 | 3.6 (3.6..3.6) | 4.1 (4.1..4.1) | 4.1 (4.1..4.1) | 4.2 (4.2..4.2) | 4.1 (4.1..4.2) |
| 8 | 18.4 (18.2..18.5) | 24.1 (24.0..24.2) | 23.4 (23.2..24.1) | 23.6 (**12.4**..24.6) | 23.7 (23.6..23.9) |
| 56 | 115.6 (110.3..115.6) | 148.4 (142.8..154.6) | 139.3 (139.0..150.2) | 155.4 (153.0..156.0) | 152.5 (151.3..153.1) |
| 84 | 118.2 (118.2..118.4) | 10.6 (6.1..13.1) | 11.2 (10.5..11.5) | 31.4 (29.8..31.6) | 141.4 (139.9..141.6) |
| 112 | 116.9 (116.7..117.2) | 34.6 (**13.5**..36.8) | 33.7 (28.5..34.6) | 33.5 (30.6..35.5) | 138.7 (138.7..139.3) |

- **Up to T = 40:** the four custom locks track each other within run-to-run noise (medians within about 8%).
  - Single-run outliers: Ticket 12.4 at T = 8; TTAS 82.0 and Ticket 87.9 at T = 40. These are unexplained.
- **At T = 56:** TTAS is 6–10% below the others, and its range (139.0..150.2) does not reach Ticket's or Park's minimum (153.0 and 151.3). Two of three TTAS runs are at about 139. The deficit is small but real, and unexplained.
- **mutex** is 22–27% below Park from T = 8 to 56.
  - At N = 4096 collisions are rare (model p ≈ 0.15% at T = 8 and 1.2% at T = 56, estimate), so mutex's deficit is mostly its uncontended path (see item 6).
- **Past 56:**
  - TAS, TTAS and Ticket collapse by 4.9–14× at T = 84 (4.1–4.6× at T = 112) relative to T = 56. The cause is in item 5.
  - The raw timings corroborate holder preemption. TAS and TTAS runs at T = 84/112 took 2.5–4.1 s against the 2 s timer; Ticket took 2.02–2.11 s and Park/mutex at most 2.02 s.
  - Park loses 7% (T = 84) and 9% (T = 112). mutex gains 2% and 1%.
  - TAS and TTAS are non-monotonic (≈11 at T = 84, ≈34 at T = 112), and TAS has a 13.5..36.8 spread at T = 112. This is unexplained.
- **Pin order:** `sweep.sh` pins in CPU-number order, so from T = 2 the threads span both sockets. The `<- first socket full` tag at T = 28 is wrong. For T > 56 the process mask is 0-55 and the scheduler places the threads (`.raw.meta`).
- **Figure fixes needed:** relabel the dashed T = 28 line as "cores per socket (28)", not "socket boundary". Change the x-label "pinned, one per core" so that it does not claim pinning for T = 84/112.

### (4) One shard, 8 threads on 8 cores (P5 `perf_1shard_8on8{,_user}_table.tsv` median-Mops row; spreads from `*_all_reps.tsv`)

User-mode (`:u`) table:

| lock | ops | Mops | ins/op | L1 miss/op | HITM/op | cs/op |
|---|---|---|---|---|---|---|
| mutex | 5,215,232 | 1.042 (1.021..1.058) | 366 | 54.2 (53.5..54.6) | 1.59 | 0.585 |
| TAS | 8,010,752 | 1.598 (1.557..1.615) | 428 | 55.8 (55.3..56.8) | **11.61** (11.59..11.88) | 2.0e-5 |
| TTAS | 9,908,224 | 1.981 (1.974..2.004) | 1117 (1097..1117) | 49.75 (49.68..49.89) | **1.55** (1.52..1.57) | 1.7e-5 |
| Ticket | 6,414,336 | 1.282 (1.275..1.283) | **1235** | 48.5 (48.3..48.5) | 1.99 | 2.2e-5 |
| Park | 7,043,072 | 1.408 (1.406..1.428) | 703 | **74.0** (72.7..74.4) | 6.04 | 0.023 |

All-modes table:

| lock | ops | L1 miss/op | HITM/op | ins/op | busy (CPUs) |
|---|---|---|---|---|---|
| mutex | 5,233,664 | 159.8 | 20.2 | 5115 | **0.49** (4.52) |
| Park | 7,144,448 | 89.8 | 8.7 | 2610 | 0.97 |
| TAS | 8,252,416 | 55.5 | 11.5 | 449 | 1.00 |
| Ticket | 6,479,872 | 54.8 | 2.0 | **10,380** | 1.00 |
| TTAS | 10,074,112 | 50.5 | 1.5 | 1110 | 1.00 |

**Prediction vs measured (user table):**

| prediction | result |
|---|---|
| Most L1 misses: TAS | Wrong overall: Park is highest. Right among the spinlocks (TAS > TTAS by 6.0/op, non-overlapping spreads). |
| TAS line moves ~5–15× per critical section | Held: 11.6 HITM/op (11.59..11.88). |
| Most instructions: TTAS or Ticket | Held: Ticket 1235, TTAS 1117. |
| TAS waiters stall and retire few instructions | Held: 428/op, IPC 0.027. |
| mutex and Park show the fewest of both | Mostly wrong: only mutex's instruction count is lowest (366). Park is 3rd in instructions (703 > TAS 428) and 1st in L1 misses; mutex is 3rd in L1 misses. |
| TTAS ≈ one HITM per waiter per release (~7/op) | Wrong: 1.55. |
| HITM caveat (xchg's load half might not be counted) | Did not apply: TAS shows 11.6, so xchg's load half is counted. |
| Plain table: mutex and Park top in L1 misses | Held. |
| Plain table: mutex and Park top in instructions | Wrong: Ticket leads with 10,380 (kernel; see below). |

**TAS vs TTAS: what the lock line does on a waiting core.**
- **TAS:** every waiter's `xchg` is a write. Each attempt needs the line in M, so the line ping-pongs among the spinners, and every transfer is a load that finds it Modified in another core (HITM).
  - The shard completes one op every 1/1.598 Mops = 626 ns ≈ 2065 cycles, and in that time the line moves 11.6 times.
  - That gives ≈178 cycles (54 ns) per transfer, or ≈205 cycles if the ~1.5 non-lock HITM/op seen under TTAS are subtracted. Both are inside the 130–230-cycle same-socket handoff range in PREDICTIONS, so the line is in flight continuously (estimate).
- **TTAS:** waiters hold the line in S and spin on L1 hits with no traffic.
  - The release store invalidates every copy.
  - The first re-reader finds the line M in the releaser's cache (1 HITM), which downgrades it to S.
  - The other re-readers get clean shared copies (L1 misses, not HITM).
  - The winner's `xchg` is an upgrade from S, which is not a HITM. But it invalidates the other S copies again, and any late loser's `xchg` would be a HITM.
  - Measured: 1.55 HITM/op in total, so few waiters are polling at any moment. Hypothesis: most of them sit in exponential backoff (up to 128 pauses ≈ 5.4 µs ≈ 10 ops).
- **Why TAS's L1-miss excess (55.77 − 49.75 = 6.0/op) is much smaller than its HITM excess (11.61 − 1.55 = 10.1/op):**
  - TTAS does not remove the misses a release causes; it changes their kind from dirty to clean.
  - `L1-dcache-load-misses` counts every line fill, including the unlock store's RFO. perf maps it to L1D.REPLACEMENT on SKX; that mapping is from the kernel's event table and was not checked on the node.
  - `xsnp_hitm` counts only retired loads served from another core's M copy.
  - So TAS's lock-line fills ≈ 11–12.6/op, almost all HITM. TTAS's ≈ 5–6.6/op, about one clean refill per waiter, with only ~1.5 of them HITM.
  - Estimate, assuming equal tree misses under both locks.
- **Throughput:** TTAS's 1.98 Mops equals the single-thread one-shard rate of 1.97 (`shardcount_ttas` N = 1, T = 1), so the lock adds no serialization loss. TAS reaches 1.60, 19% lower. Hypothesis: the holder's unlock RFO and tree accesses queue behind the spinners' RFOs.

**Ticket and Park enter the kernel without switching (kernel ≈ all-modes − user, from different runs, so approximate).**
- **Ticket:** ≈9,150 kernel instructions and ≈9,660 kernel cycles per op, at cs/op 2.5e-5 (user busy 0.50, all-modes 1.00).
  - With 7 ops ahead, a waiter waits 7/1.282 Mops ≈ 5.5 µs. That is about the 128-spin budget (128 × ~140 cycles ≈ 5.4 µs at 3.30 GHz, estimate).
  - So waiters reach `sched_yield`, which returns at once because no other thread is runnable.
  - If the next ticket's owner is in that syscall at handoff time, the lock sits idle. That, plus strict FIFO with no barging, explains Ticket's 1.28 Mops (inference from the counters).
- **Park has the most user L1 misses (+24/op over TTAS) and 6.0 HITM/op.** Hypothesis, not evidenced in this run:
  - (a) Its CAS, the `exchange(2)` of woken waiters and the unlock `exchange(0)` are RFOs.
  - (b) libstdc++'s `atomic::wait`/`notify_one` keep a waiter count in a shared table line: an RMW on entering and leaving the wait, and a seq_cst load in notify. The wait also spins 12 pauses and 4 `sched_yield`s before the futex.
  - (c) Kernel entries evict user lines. ≈1,900 kernel instructions/op at only 0.023 cs/op is consistent with (b) and (c).
- mutex's 54 user misses, despite sleeping waiters, fit (c) too (hypothesis).

### (5) 32 threads on 8 cores, N = 4096 (P5 `perf_32on8_table.tsv`, `perf_32on8/*.r*.txt`)

| lock | ops | Mops (min..max) | cyc/op | busy (min..max) | taskclk CPUs | cs/op (min..max) | run ms |
|---|---|---|---|---|---|---|---|
| mutex | 127,683,584 | 25.47 (25.37..25.48) | 968 | 0.98 | 7.85 | 2.0e-4 | 5013–5016 |
| Park | 148,683,776 | 29.71 (29.70..29.75) | 826 | 0.98 | 7.81 | 5.3e-4 | 5004–5014 |
| Ticket | 53,708,800 | 10.54 (10.20..10.65) | 2375 | 1.00 | 7.96 | **0.677** (0.677..0.718) | 5056–5095 |
| TAS | 14,948,352 | 2.43 (2.28..2.45) | 9625 | 0.92 (0.92..0.94) | 7.37 | 3.7e-4 | **5749–6278** |
| TTAS | 13,869,056 | 2.20 (2.04..2.49) | 10,600 | 0.92 (0.92..0.93) | 7.35 | 4.1e-4 | **6082–6303** |

Without f, busy is 0.93 / 0.93 / 0.95 / 0.88 / 0.88 (table order).

Reference point: 8 TAS threads on the same 8 cores at N = 4096 run 31.7 (31.69..31.78) Mops at 792 (790..794) cyc/op (P5 `clock/`), at an effective clock of 3.300 GHz.

- **Busy fraction does not separate the locks; cycles per op do.** All five are at 0.92–1.0 busy.
  - TAS and TTAS spend 11.7× and 12.8× Park's cycles per op. About 91–92% of their cycles are spin (estimate: (cyc/op − 826)/cyc/op).
  - Ticket wastes about 65% (≈1,550 cycles/op over Park).
  - Park runs at 1.04× the reference cost per op (94% of its throughput).
  - mutex runs at 968 cyc/op (80% of the reference throughput), which is about its own non-oversubscribed overhead: it is 22–27% slower in the sweep at T ≤ 56. Oversubscription costs mutex almost nothing.
- **TAS and TTAS burn the cores, because of lock-holder preemption:**
  - A thread preempted inside a critical section freezes its shard. Any running thread that hashes there spins without yielding until the holder runs again, which can take up to the rest of a timeslice.
  - Estimate: 24 descheduled threads × f ≈ 0.9 freeze ≈ 22 of 4096 shards. A running thread hits one every ≈190 ops (~50 µs) and then spins for up to ~ms, so its time is mostly spinning. This matches the 91–92% spin cycles in order of magnitude.
  - Their only switches are timeslice expiry: ≈118 per core per second, one every ≈8.5 ms.
  - Evidence: the runs overran the 5 s timer by 0.75–1.3 s, because threads cannot see the stop flag while waiting on a descheduled holder.
  - Hypothesis: the 0.92 busy is the end-of-run drain, when fewer than 8 threads remain.
- **Ticket (10.5 Mops, 4.3× TAS and 4.8× TTAS):** waiters yield after 128 spins.
  - With 4 runnable threads per core, every yield is a real switch: ≈960k per core per second, one every ≈1 µs.
  - This rotates the threads on each core within µs, so a preempted holder, or the next ticket's owner, gets a CPU within µs instead of ms (inference).
  - Its waste is bounded but large.
  - **The prediction was wrong (Ticket worst):** it weighted Ticket's waiter-preemption problem but overlooked that TAS and TTAS never yield. Their holder preemption costs whole timeslices, while Ticket's yield bounds every wait.
- **mutex and Park give the cores up:** waiters sleep in the futex, so a frozen shard costs only the colliding thread. The core keeps running other runnable threads that do useful work (busy 0.98).
- **Prediction scorecard:**

  | prediction | measured |
  |---|---|
  | Throughput: mutex ≈ Park > TTAS ≥ TAS > Ticket | Wrong order: Park > mutex (+17%, non-overlapping) > Ticket > TAS ≈ TTAS (within spread). |
  | Spinner busy 0.95–1.0 | Partly wrong: TAS and TTAS 0.92 (0.88 by the README formula); Ticket 1.00 held. |
  | Sleeper busy 0.8–1.0 | Held: 0.98. |
  | Ticket has the most cs/op | Held: 0.68 vs ≤ 5.3e-4. |
  | Order of the rest: mutex/Park, then TAS/TTAS | Wrong: Park > TTAS ≈ TAS > mutex (5.3, 4.1, 3.7, 2.0 × 1e-4). The magnitude (~1e-4/op) held. |

### (6) Park vs std::mutex (P5 sweep; 1-shard and 32-on-8 tables)
- **Park/mutex throughput ratio** (medians; spreads do not overlap at any of these T):

  | T | 1 | 8 | 28 | 56 | 84 | 112 |
  |---|---|---|---|---|---|---|
  | Park/mutex | 1.14 | 1.29 | 1.34 | **1.32** | 1.20 | 1.19 |

  - T = 56: Park 152.5 (151.3..153.1) vs mutex 115.6 (110.3..115.6).
  - T = 84: 141.4 vs 118.2.
  - T = 112: 138.7 vs 116.9.
- **Mechanism, cleanest at one shard with 8 on 8:**
  - glibc's default mutex makes one CAS. On failure it swaps in 2 and calls `futex_wait`, so every contended acquire costs a sleep/wake round trip (cs/op 0.585). With no other runnable thread, about half the cores sit idle (all-modes busy 0.49, 4.52 CPUs).
  - Park spins first for up to 100 pauses (≈4.2 µs, estimate), which covers most waits. It switches 25× less often (cs/op 0.023), keeps the cores busy (0.97), and runs 35% faster (1.41 vs 1.04 Mops).
- **At one thread per core with N = 4096, collisions explain little of the gap:**
  - The gap is 29–37% from T = 8 to 56 and does not grow with T, although the model collision rate rises from 0.15% to 1.2%.
  - With k ≈ 5 ops (mutex) vs ≈ 2 (Park) (item 8), collisions account for at most about 4 points of the gap at T = 56 and under 1 point at T = 8 (estimate).
  - Part of the gap is the uncontended path: mutex is 12% slower at T = 1 (3.6 vs 4.1). The cause, plausibly the call into libc plus the `__kind`/`__owner`/`__nusers` bookkeeping, was not measured.
  - Hypothesis for the rest (T ≥ 2, where lock lines were last written by another core): glibc reads `__kind` before its CAS, so taking such a line costs a read miss plus an upgrade instead of one RFO.
- **Beyond the core count:** the gap shrinks from about 32% to 19–20%, toward the single-thread gap of 14%.
  - Park's spin is now partly wasted: a waiter whose holder is preempted spins its whole budget and then sleeps anyway.
  - mutex wastes nothing and gains 1–2%.
  - The prediction, "≥ at one thread per core", held (1.29–1.37×).
  - The prediction, "≈ equal past the core count", was **wrong**: Park stays 19–20% ahead with non-overlapping spreads.
  - At 32-on-8: Park leads by 17% (29.71 vs 25.47) at the same 0.98 busy.

### (7) Spin hint
- **What PAUSE does on CLX:** it takes about 140 cycles (published figure, not measured here) and tells the core it is in a spin-wait.
  - The core stops issuing a stream of speculative loads of the watched flag. When the line is invalidated, there is then no memory-order machine clear (pipeline flush) at the moment the core must react.
  - It saves power.
  - It gives an SMT sibling the pipeline. SMT is off on Frontera, so this part does not apply here.
  - It throttles how often the line is polled.
- **Budgets at 3.30 GHz (estimate):**
  - TTAS backoff of 4..128 pauses ≈ 0.17–5.4 µs.
  - Ticket's 128 spins ≈ 5.4 µs.
  - Park's 100 spins ≈ 4.2 µs.
  - The code comments' ~6 µs and ~5 µs come from the same cycle counts at a lower clock.
- **Why Ticket needs yield and TTAS does not:**
  - TTAS lets whichever waiter is running take the lock, so a descheduled *waiter* costs nothing.
  - Ticket hands the lock to one specific ticket. If that thread is off-CPU, the lock is free but nobody may take it, and everyone queued behind it spins. Yielding is how the spinners give that thread a CPU.
- **Measured nuance (32-on-8):** TTAS also suffers *holder* preemption, at 2.2 Mops. Ticket's yield helps there too, which is why Ticket (10.5) beats TTAS.

### (8) Shard count redone (P5 `shardcount_sharded_{ttas,park}.csv`; mutex from `part4_*/shardcount_sharded_mutex.csv`)
The T = 32 runs use CPUs 0–31 (both sockets) for all three locks.

The mutex data come from a different node (c207-021) than TTAS and Park (c201-033). mutex at T = 1, N = 4096 is 3.6 on both nodes (3.61 in the Part 4 raw data), so the comparison is fair.

T32/T1 ratio from the CSVs:

| N | 64 | 256 | 1024 | 4096 | 16384 |
|---|---|---|---|---|---|
| mutex | 7.54 | 13.14 | **17.45** (17.4..17.7) | 20.28 (20.1..20.4) | 20.24 |
| TTAS | 12.14 | 17.52 | **20.56** (20.34..21.09) | 21.37 (20.6..21.7) | 21.48 |
| Park | 12.07 | 18.48 | **21.43** (20.8..21.5) | 21.93 (21.7..21.9) | 21.04 |

- **Where each plateaus:**
  - TTAS at N = 1024 is 96% of its plateau, and its range overlaps N = 4096's.
  - Park is at its plateau by N = 1024. Its ratio is non-monotonic (21.4 → 21.9 → 21.0), so the plateau is ~21–22 with about 2% noise.
  - mutex at N = 1024 is 86% of its plateau, clearly below N = 4096.
- **Full contention (N = 1):** TTAS 0.65 and Park 0.60, vs mutex 0.35.
- **Collision model** (Part 4's, estimate): p = 1 − (1 − 0.9/N)^31, and k from R∞/R − 1 = k·p.
  - R∞ is the mean of the N = 4096 and N = 16384 ratios.
  - Fit points are N = 64, 256, 1024, with t₀ = 1/T1(N).

  | lock | k (ops) | cost per collision | model overhead N=1024 | model overhead N=4096 | measured overhead N=1024 |
  |---|---|---|---|---|---|
  | mutex | 4.8–6.0 | 1.7–1.9 µs | 13–16% | 3.2–4.1% | 16% |
  | TTAS | 1.6–2.2 | 0.46–0.77 µs | 4–6% | 1.1–1.5% | 4.2% |
  | Park | 0.1–2.2 (poorly determined) | ≤ 0.8 µs | 0.3–6% | ≤ 1.5% | 0.3% |

  - Summary: a collision costs about 2 ops with a spinning lock vs about 5 with mutex. A spinning waiter pays the holder's residual time plus a line handoff; a mutex waiter pays a futex sleep and wake.
  - N = 1024 is one of the fit points, so the agreement between model and measured overhead there is a consistency check, not an independent confirmation.
- **Recommendation: ship N = 4096 (unchanged).**
  - By Part 4's rule (the smallest N on the T32/T1 plateau), N = 1024 would now do for TTAS and Park. Their N = 1024 ratios are within spread of 4096, with a model overhead of ≤ 6%.
  - mutex still needs 4096 (86% of plateau at 1024).
  - For TTAS and Park, N = 4096 is also on the plateau (model collision overhead ≤ 1.5%), so it costs no scalability, and no `size()` is in the workload.
  - One N for all locks keeps the Part 5 and Part 6 comparisons on the same footing.
  - Absolute throughput does keep rising with N: T = 32 TTAS goes 69.9 → 87.6 → 107.4 at N = 1024, 4096, 16384, and Park 75.0 → 92.1 → 107.3. This is a tree-depth effect of the fixed total key count (the T = 1 rate rises the same way), not a collision effect, so it does not decide N.


---

## Part 6 notes: readers and writers

**Setup (state once).**
- Run: Frontera CLX node c201-033, job 7972388 (`results/part6_20261004-161721_7972388/`), g++ 13.2.0, CentOS 7, `locks.h` md5 `a68b2df2…`.
- Protocol: each point is the median of 3 two-second runs. Shard counts are N = 4096 (chosen in Part 4) and N = 1.
- Pinning: `sweep.sh` pins in CPU-number order, and this node numbers its CPUs alternately by socket (node0 = even CPUs). From T=2 the threads therefore sit on both sockets, 14 per socket at T=28. The WRITERS runs use `cpus=0-7/0-27/0-55`, so the same applies.
  - The log tag "<- first socket full" at T=28 is wrong for this pin order.
  - So is the "socket boundary (28)" line in `figs/part6_mix_grid.png`. Relabel it "28 = cores per socket".
- Resolution: the `.log` medians print to 0.1 Mops/s, but every `.raw` line carries the exact op count and ms. Ratios below therefore resolve to ~0.1 %, and the limit is the run-to-run spread.
  - Exception: the WRITERS rd/wr split is printed only at 0.1, so wr = 0.0 means < 0.05 Mops/s.

### (1) RWLock / RWLockWP pass tests and TSan
- Both jobs ran on Lonestar6 (g++ 15.2.0, `HAVE_RW 1`, same `locks.h` md5 as the Frontera runs): `tsan_ls6_20261004-161507_3488118/` and `tsan_ls6_20261004-165301_3488178/`.
  - `tsan_summary.txt`, both jobs: `test_map_tsan: exit=0 … all checks passed` and `test_locks_tsan: exit=0 … all checks passed`. Both show `ThreadSanitizer WARNING/SUMMARY lines: 0`.
  - Plain builds: `test_map` and `test_locks` exit=0 in both jobs (`exit_codes.txt`).
  - Positive control: `race_control` exits 66 and prints a data-race SUMMARY.
- RW test lines (from `test_locks_tsan.stdout` and `test_map_tsan.stdout`):
  - `RWLock (exclusive)` and `RWLockWP (exclusive): 8 threads x 5000, mutual exclusion`.
  - `RWLock` and `RWLockWP: 6 readers + 2 writers, exclusion and sharing`.
  - `ShardedMap<RW>` and `ShardedMap<RWWP>`: sequential, disjoint keys, contended keys, concurrent size() exact.
- **Caveat:** both TSan jobs (and the Frontera run) had `HAVE_HASHED 0`. The final submission needs every switch at 1, and tests and TSan must be re-run with Part 7 enabled.

### (2) Measurements present
- **Mix sweeps:** 4 locks (ttas, rw, rwp, shared_mutex) × MIX 100/0/0, 80/10/10, 50/25/25 × N = 4096 and 1, giving 24 sweeps. Each covers T = 1,2,4,8,16,28,40,56,84,112 with 3 runs per point.
  - Files: `mix{100-0-0,80-10-10,50-25-25}_shards{4096,1}/sharded_{ttas,rw,rwp,shared_mutex}.{csv,log,raw}`.
  - Plot: `figs/part6_mix_grid.png` (fix the T=28 label).
- **WRITERS=n:** rw and rwp × W = 1 and 4 × N = 1 and 4096 × T = 8, 28, 56, with 3 runs each.
  - Files: `writers{1,4}_shards{1,4096}/sharded_{rw,rwp}.raw`. The reader/writer split for each point comes from the run with the median total, in `writers_table.tsv`.
  - Plot: `figs/part6_writers.png`. **Redo it:** on one linear axis every N=1 bar (≤ 9 Mops/s) is invisible next to the 235 Mops/s bars. Use separate N=1 and N=4096 panels or a log axis.
  - The WRITERS `.log` headers print `mix=80/10/10`. This is a sweep.sh artifact: the bench lines say `mix=roles`.
- **shared_mutex was not run with WRITERS.** `jobs/part6.slurm` loops over `rw rwp` only.

### (3) When the RW lock beats TTAS (Mops/s, median [min..max] of 3)
| N, MIX | T | ttas | rw | rwp | shared_mutex |
|---|---|---|---|---|---|
| 1, 100/0/0 | 1 | 2.1 | 2.0 | 2.0 | 2.0 |
| | 8 | 1.9 [1.9..1.9] | 8.4 [8.0..8.5] | 6.8 [6.6..6.9] | 1.9 [1.8..2.6] |
| | 28 | 1.5 [1.4..1.5] | **9.5 [9.2..9.6]** | 5.8 [5.7..5.8] | 2.0 |
| | 112 | 0.4 [0.4..0.5] | 8.5 [8.2..8.7] | 5.0 | 1.9 |
| 1, 80/10/10 | 4 | 1.7 [1.7..1.7] | 2.0 [1.9..2.0] | **2.4 [2.4..2.4]** | 1.0 |
| | 28 | 1.3 [1.3..1.3] | 1.2 [1.2..1.2] | 1.4 [1.3..1.4] | 1.1 |
| | 112 | 0.6 | 0.5 | 0.1 | 1.1 |
| 1, 50/25/25 | 28 | 1.2 [1.2..1.2] | 1.0 [1.0..1.0] | 0.9 | 0.8 |
| 4096, 100/0/0 | 56 | 303.0 [253.8..317.8] | 311.8 [310.6..313.5] | 313.9 | 236.2 [234.9..243.7] |
| | 84 | 50.1 [50.0..54.3] | 313.4 [309.4..331.0] | 315.6 | 235.3 |
| 4096, 80/10/10 | 56 | 149.8 [147.0..149.9] | 150.2 [137.2..150.2] | 137.5 [133.5..137.8] | 109.5 |
| | 84 | 10.4 [7.9..12.5] | 10.5 [10.4..10.8] | 9.4 | 110.9 [110.7..111.0] |
| 4096, 50/25/25 | 56 | 99.7 [98.8..105.9] | 103.9 [100.7..107.7] | 103.4 | 76.3 |
| | 84 | 5.5 [5.4..5.9] | 5.2 [4.9..6.7] | 5.6 | 79.2 [79.2..79.4] |

Ratios below are from the op counts in the `.raw` files.

**Where an RW lock wins:**
- **1 shard, read-only, every T ≥ 2:** rw/ttas is 2.1× at T=2, 6.5× at T=28 (rw's peak of 9.5), 9.3× at T=56 and 21× at T=112. rwp/ttas is 2.0-12.5×. The spreads never overlap.
- **1 shard, 80/10/10, low T:** rwp is the best lock: +16 %, +45 %, +29 %, +12 % over ttas at T = 2/4/8/16 (separated). rw is ahead only at T=4 (+18 %) and T=8 (+10 %).
- **4096 shards, read-only, past the core count:** rw and rwp hold 312-316, the same as at T=56. TTAS collapses to 50.1 at T=84 and 38.6 at T=112, so rw is 6.3× and 8.1× faster.

**Where it does not:**
- **1 shard, 80/10/10, rw from T=16:**
  - About −3 % at T=16 (effectively a tie).
  - −10 %, −13 %, −16 % at T = 28/40/56 (spreads separated).
  - Within spread at T=84/112.
  - rwp ≈ ttas at T = 28-56, then collapses past the cores (0.22, 0.10 = 0.35×, 0.17× ttas).
- **1 shard, 50/25/25:**
  - rw is +4 % at T=2 and ≈ at T=4, then −7 % at T=8 and −15..−21 % at T = 16-56 (separated).
  - rwp ≤ ttas everywhere, falling to 0.06-0.10 past the cores.
- **4096 shards, T ≤ 56, every mix:** rw/ttas is between 0.96 and 1.09. Spreads separate at 7 of the 24 points, and at each of them rw is ahead by only 1-4 %. Treat this as a tie.
  - rwp/ttas is 0.92-1.06. The one separated low point is 80/10/10 T=56 (−8 %).
- **4096 shards, past the cores, with writes:** rw collapses along with TTAS: 10.5 vs 10.4 (80/10/10) and 5.2 vs 5.5 (50/25/25) at T=84; 33.3 vs 36.6 and 21.0 vs 23.7 at T=112.

**What a reader pays and gains:**
- **Pays:** two locked read-modify-writes on the shard's lock word per find (CAS n→n+1 to enter, `fetch_sub` to leave). TTAS pays one `xchg` and a plain release store.
  - **Uncontended:** the extra RMW is about 20 cycles (~6 ns), ≤ 4 % of a 150-500 ns op. At T=1 rw is 1-2 % slower than ttas at N=1 (2.009 vs 2.055 read-only, ≈ +11 ns) but 1-2 % faster at N=4096. Effects of that size are not attributable.
  - **Contended:** each RMW needs the line in M state, so the reader-count line ping-pongs among readers even when no writer exists.
  - **Plateau estimate:** rw's 1-shard plateau of 9.54 Mops/s is about 105 ns of lock-line time per find, or ~53 ns per RMW. That matches in order of magnitude the published handoff costs (same socket ~40-70 ns, across UPI ~110-150 ns; PREDICTIONS.md table). However, the sweep puts 14 threads on each socket at T=28, so two full transfers per find would predict only ~5-7 Mops/s. The counter-free data cannot say how many transfers a find really causes. *Estimate.*
- **Gains:** lookups overlap.
  - A 1-shard lookup takes ≈ 0.50 µs (rw 2.009 Mops/s at T=1).
  - At T=28 each rw thread finishes a find every 28/9.54 = 2.9 µs. About 9.54 × 0.50 ≈ 4.75 lookups are in progress on average, assuming the T=1 lookup cost; the other ~2.4 µs per find is queueing on the count line. *Estimate.*
  - TTAS at T=28 has 1.47 × 0.49 ≈ 0.7 lookups in progress, so there is no overlap. Its extra ~0.2 µs per op is the handoff.
  - rw scales until the count line, not the lookup, is the bottleneck (T ≈ 16-28). It then stays at 8.3-9.5 out to T=112.
- **At 4096 shards** collisions are rare (Part 4). There is no serialization to remove, and each lock line is touched by one thread at a time. The gain is ~0 and the extra RMW is below the spread, hence the tie.
- **With writes at 1 shard:** a writer needs the count at 0 and then excludes everyone.
  - At 50/25/25 there is on average one find per write to overlap, so the gain is about zero while the extra RMW traffic remains: rw < ttas from T=8.
  - At 80/10/10 there are four finds per write, which gives a small gain at low T only.
  - rwp does better than rw at 80/10/10 for T = 2-56 (+10..+24 %). In MIX mode a thread waiting to write does no reads, and rw makes it wait for a moment when the count is 0 while the other threads keep reading. rwp stops new readers once a writer waits, so the writer waits only for readers already inside. *From the code, no counters.*
- **Past the cores:**
  - In a read-only run `state_` never becomes −1 (and rwp's `waiting_` stays 0), so no reader ever waits for a holder and a preempted reader blocks nobody.
  - TTAS: a preempted holder blocks its shard for a whole timeslice (Part 5).
  - With writes, a writer waits on a preempted reader and readers wait on a preempted writer. Neither RW lock yields, so rw collapses like TTAS.
  - rwp is worse at 1 shard: readers spin on `waiting_ != 0`, so a single preempted writer that has announced itself, or that holds the lock, stops every reader. *From the code.*
- **Side note: rwp is below rw read-only at 1 shard** (0.81× at T=8 and 0.61× at T=28; 5.8 vs 9.5). After a failed CAS, `RWLockWP` pauses (~140 cycles on CLX) and re-reads `waiting_` and `state_` (load, then CAS: an S fetch plus an upgrade). `RWLock` retries straight away with the value the failed CAS returned. *From the code, not checked with counters.*

### (4) Where std::shared_mutex falls
- **4096 shards, T ≤ 56:** lowest of the four at every T in every mix. It runs at 0.70-0.82× TTAS for T = 2..56, and its spreads are separated from TTAS at every point.
  - At T=56: 236.2 vs 303.0 (TTAS) / 311.8 (rw), which is −22 % / −24 % at 100/0/0.
  - 109.5 vs 149.8 at 80/10/10, which is −27 %.
  - 76.3 vs 99.7 / 103.9 at 50/25/25, which is −23 % / −27 %.
  - Uncontended extra cost at T=1, from 1/x − 1/y with op-count rates: +20 ns/op (5.84 vs 6.61), +40 ns (3.53 vs 4.10), +36 ns (3.15 vs 3.55). It takes the heavier `pthread_rwlock` path instead of one inline RMW.
- **Past the cores** it stays at its T=56 level: 235 / 110.9 / 79.2 at T=84.
  - Read-only, rw and rwp also hold (312-316), and shared_mutex stays 25 % below them.
  - With writes it is the best of the four: 10.6× TTAS at 80/10/10 and 14.3× at 50/25/25 at T=84, and 3.0× / 3.3× at T=112. Its waiters sleep instead of spinning, so preemption costs it nothing extra.
- **1 shard: it does not scale at all.**
  - **Read-only:** 2.0 at T=1, 2.6 [2.6..2.8] at T=2, then 1.8-2.0 from T=8 to T=112. That is ≥ TTAS at every T ≥ 2 (1.4-4.8× at T ≥ 28) but 4.5× below rw (9.5) at T=28.
  - **With writes,** a second thread halves the throughput: 2.0 → 1.0 [1.0..1.0] at 80/10/10, and 2.0 → 0.7 [0.7..0.9] at 50/25/25. It then stays flat (0.97-1.10 and 0.69-0.77) all the way to T=112, about 1.0 µs and 1.3 µs per op.
  - **Against TTAS, with writes only:**
    - 80/10/10: below TTAS through T=28 (0.82×), tied at T=40, above from T=56.
    - 50/25/25: below through T=40, tied at T=56, above from T=84.
    - Above every spinlock past the cores: T=112 at 80/10/10 gives 1.1 vs 0.6 TTAS, 0.5 rw, 0.1 rwp.
- **Reading of the 1-shard behavior** (inference only: there is no shared_mutex WRITERS split and no context-switch counts in Part 6):
  - The total does not change from T=2 to T=112 and does not fall past the cores. Waiters are therefore parked in the kernel (futex), not spinning, and contended handoffs pay a wake-up on the order of a µs.
  - A thread that draws a write and finds readers inside sleeps until the reader count drains. glibc's default rwlock kind prefers readers, so a waiting writer does not stop new readers.
  - In MIX mode, though, a thread waiting to write issues no reads, so the reader stream dries up within a few ops. The mix runs show the cost of a sleeping writer (throughput halves as soon as T=2 brings read/write conflicts), not indefinite starvation.
  - The read-only flat line (~1.9) means the reader path itself is serialized. provenance.txt records CentOS 7, whose system glibc is 2.17. Its pre-2.25 `pthread_rwlock` takes an internal futex-based lock in every rdlock and unlock. *Hypothesis: the version is inferred from the OS; confirm with `ldd --version`.*
  - The only direct evidence of writer starvation is the local pre-run quoted in PREDICTIONS.md (wr 0.0, rd 12-13 Mops/s). That was a different machine and a WRITERS workload, with shared_mutex reads about 6-7× faster than Frontera's read-only 1.9, so it cannot stand in for Frontera.
  - A ~1-minute Frontera run (WRITERS=1 and 4, `sharded:shared_mutex`, N=1, T=8/28/56) would answer this directly.

### (5) Writer-preferring (rwp) vs reader-preferring (rw), WRITERS=n (`writers_table.tsv`)
Columns are readers / writers / total, in Mops/s. Spreads are from the `.raw` files.

| N | W | T | rw | rwp |
|---|---|---|---|---|
| 1 | 1 | 8 | 6.9 [6.7..6.9] / 0.0 / 6.9 | 0.2 / 0.9 / 1.1 |
| 1 | 1 | 28 | 9.1 [8.9..9.4] / 0.0 / 9.1 | 0.4 / 0.4 / 0.8 |
| 1 | 1 | 56 | 8.2 [7.8..8.3] / 0.0 / 8.2 | 0.3 / 0.2 / 0.5 |
| 1 | 4 | 8 | 1.0 / 1.0 / 2.0 [1.9..2.1] | 0.0 / 1.0 / 1.0 |
| 1 | 4 | 28 | 8.0 [7.8..8.1] / 0.0 / 8.0 | 0.0 / 0.6 / 0.7 |
| 1 | 4 | 56 | 7.8 / 0.0 / 7.8 | 0.0 / 0.4 / 0.4 |
| 4096 | 1 | 8 | 28.3 / 2.1 / 30.4 [30.1..30.5] | 28.2 / 2.1 / 30.2 [30.1..30.3] |
| 4096 | 1 | 28 | 115.5 / 2.2 / 117.7 [116.9..118.4] | 114.0 / 2.1 / 116.1 [114.5..116.8] |
| 4096 | 1 | 56 | 233.8 / 2.1 [1.3..2.1] / 235.9 [234.8..236.9] | 209.1 / 1.8 [1.8..1.9] / 210.9 [207.8..217.1] |
| 4096 | 4 | 8 | 13.3 / 7.4 / 20.6 [20.6..20.8] | 13.3 / 7.1 / 20.4 [18.5..20.6] |
| 4096 | 4 | 28 | 94.1 / 8.0 / 102.0 | 93.6 / 7.5 / 101.1 |
| 4096 | 4 | 56 | 210.1 / 7.9 / 218.0 [196.8..219.4] | 203.7 / 7.4 / 211.1 [176.4..217.5] |

At 1 shard every rwp cell and every writer column agree within 0.1 across the 3 runs. rw's reader column varies by up to 0.5. rw shows wr = 0.0 in every run except at W=4 T=8.

**1 shard:**
- **Writers:**
  - W=1: 0.0 → 0.9 / 0.4 / 0.2 (T = 8/28/56).
  - W=4: 1.0 → 1.0 at T=8 (rw already lets the writers in there), then 0.0 → 0.6 / 0.4 at T=28/56.
- **Readers:**
  - W=1: 6.9 / 9.1 / 8.2 → 0.2 / 0.4 / 0.3.
  - W=4: 1.0 / 8.0 / 7.8 → 0.0.
- **Total:**
  - Down 84 / 91 / 94 % at W=1.
  - Down 50 % at W=4 T=8 (2.0 → 1.0), and 91 / 95 % at W=4 T=28/56.
- **Why rw starves the writer** (*estimate*):
  - At T=8, 7 readers each finish a find every ~1.0 µs, about half of it inside the lock (0.5 µs lookup) and most of the rest queued on the count line.
  - The count reaches 0 only when all readers are outside at once. Even then the writer's load-then-CAS(0→−1) must beat the readers' CAS(0→1) on the same line.
  - With ≥ 7 readers the writer essentially never wins (wr < 0.05). With 4 readers (W=4, T=8) writers do get in (1.0).
- **Why rwp still lets some readers in at W=1** (from the code): `waiting_` drops to 0 once the writer holds the lock and stays 0 until the writer's next `lock()` (its `fetch_add`). After `unlock()`, readers slip in through that gap. With W=4 some writer is almost always waiting, so readers get 0.0.
- **Why rwp's total drops:** the work becomes one stream of serialized writes (about 1.1 µs each at W=1 T=8, ~2× the uncontended op) instead of overlapped finds.
- **Why rwp's writers slow down as T grows** (0.9 → 0.4 → 0.2 at W=1): every writer step (`fetch_add`, CAS, store, `fetch_sub`) must invalidate a line that the T−1 spinning readers keep pulling back into S state, and half of those readers are on the other socket. *Estimate, no counters.*

**4096 shards: preference makes no difference.**
- A writer waits on only one shard in 4096, so even rw never starves it. It gets 1.8-2.2 Mops/s at W=1 and 7.1-8.0 at W=4 (≈ 1.8-2.0 per writer, its uncontended rate) with either lock.
- Readers and totals agree within spread at T=8 (both W), W=4 T=28 and W=4 T=56. At W=1 T=28 the total spreads only just separate (rw +1.4 %), which is practically equal.
- One exception: at W=1 T=56, rwp's total is 10.6 % lower (210.9 vs 235.9) and the spreads separate.
  - Writer preference cannot cause this, because it can only block finds on 1 of 4096 shards.
  - The 80/10/10 mix shows the same direction at T=56 (rwp 137.5 vs rw 150.2 and ttas 149.8). 100/0/0 and 50/25/25 do not.
  - Report it as unexplained.

### Prediction vs measurement (PREDICTIONS.md Part 6, committed 15:07; runs started 16:17)
- **N=4096, every mix: rw ≈ ttas ≈ rwp, shared_mutex lowest.** Held for T ≤ 56: rw within −4..+9 %, rwp within −8..+6 %, shared_mutex at 0.70-0.82×.
  - Not foreseen: past the cores, rw/rwp are far ahead read-only (313 vs 50), and shared_mutex is the *highest* with writes.
- **1 shard, 100/0/0: rw ≫ ttas, gap grows with T, saturation on the count line.** Held: 2.1× → 6.5× → 21×, with a plateau of 9.1-9.5 at T = 16-40.
  - The predicted lookup time was ~0.3 µs; the measured value is 0.50 µs.
  - "~2 line transfers per op" matches only in order of magnitude (see the plateau estimate above).
- **"shared_mutex scales similarly."** **Failed:** it stays flat at about 1.9.
- **1 shard, 80/10/10: rw > ttas at moderate T, gap narrowing.** Partly held.
  - rw: +18 % / +10 % at T = 4/8 only. The gap then reverses rather than narrowing (−10..−16 % at T = 28-56).
  - rwp held better: +12..+45 % at T = 2-16.
- **1 shard, 50/25/25: rw ≈ or < ttas.** Held: ≈ up to T=4, −7 % at T=8, and −15..−21 % at T = 16-56.
- **RWLock starves writers; rwp moves writers from ~0 to substantial, collapses readers, lowers the total.** Held at N=1, except at W=4 T=8, where rw already gives writers 1.0 and rwp leaves them unchanged.
  - There is no effect at N=4096, which the prediction did not address.
- **shared_mutex writer starvation.** Not tested on Frontera. The MIX runs cannot show it (see (4)).
- **Disclose:** the shared_mutex and rwp predictions cite "*measured locally*" numbers, so they are not blind predictions.


---

## Appendix and report-quality notes (machine, protocol, TSan, who did what, page budget, deliverables)

Paths are relative to `lab1/results/`. Every number below was re-derived from the file named next to it.

### A1. Machine
Rubric: Report quality, 2 pts. This row covers the TSan lines, `lscpu`, pin order with socket boundary, and who-did-what. If `lscpu` or the pin order is missing, every sweep is graded as unpinned.

Quote these lines verbatim from `part2_20261004-152041_7972219/lscpu.txt`, and paste the full NUMA lists.
```
CPU(s):                56
On-line CPU(s) list:   0-55
Thread(s) per core:    1
Core(s) per socket:    28
Socket(s):             2
NUMA node(s):          2
Model name:            Intel(R) Xeon(R) Platinum 8280 CPU @ 2.70GHz
CPU MHz:               3300.183
CPU max MHz:           4000.0000
CPU min MHz:           1000.0000
L1d cache:             32K
L2 cache:              1024K
L3 cache:              39424K
NUMA node0 CPU(s):     0,2,4,6,8,10,12,14,16,18,20,22,24,26,28,30,32,34,36,38,40,42,44,46,48,50,52,54
NUMA node1 CPU(s):     1,3,5,7,9,11,13,15,17,19,21,23,25,27,29,31,33,35,37,39,41,43,45,47,49,51,53,55
```
The other **six** Frontera `lscpu.txt` files (part3, part3u, part4, part5, part6, socketfirst) differ from this one only in `CPU MHz` (3299.523 to 3300.512).

**Environment, for one sentence in the report.** Source: `provenance.txt`, which is identical in all 7 Frontera dirs apart from the date, host and job lines.
- CentOS 7, kernel 3.10.0-1160.90.1.el7, g++ 13.2.0.
- Flags `-std=c++20 -O2 -Wall -Wextra -pthread` (the Makefile CXXFLAGS; see `build.txt`).
- Governor `performance`, `no_turbo: 0` (turbo on).
- `Cpus_allowed_list 0-55`: the whole node, development partition.
- `perf_event_paranoid=0`.
- Every perf event set passed a separate "counted 100% of the time" check, so there was no multiplexing (job.log `mux check` lines in part3, part3u and part5 ×3).

**Effective clock: 3.300 GHz with 8 busy cores** (nominal 2.7 GHz).
- Source: `part5_*/job.log` line 58.
- Re-derived from `clock/sharded_tas_8on8.r1.txt`: 125,773,088,638 cycles / 102,902,719,680 ref-cycles × 2.7 GHz = 3.3001 GHz. r2 and r3 also give 3.3001.
- It was measured only for sharded:tas T=8 N=4096 on CPUs 0,2,…,14. Applying 3.30 GHz at 28 or 56 busy cores is an **estimate**: the published all-core turbo is 3.3 GHz, and 32-on-8 busy_ref agrees with busy to within 0.01.

**Three nodes, all the same type. Disclose this.**
- c207-021 (job 7972219): Parts 2, 3 and 4.
- c208-017 (job 7972291): the socket-first sweep.
- c201-033 (job 7972388): Part 3u, Part 5 and Part 6.

Four comparisons cross nodes, and their captions or text must say so:
- `part2_coarse.png` and `part4_coarse_vs_sharded.png`: c207-021 against the socket-first curves from c208-017.
- `part5_shardcount.png`: mutex from c207-021, ttas and park from c201-033.
- Part 3 all-mode table (c207-021) against the Part 3u `:u` table (c201-033).

Part 5's all-mode and `:u` tables are on the same node.

### A2. Pin order and socket boundary (quote exactly)
`part2_*/sweep/coarse.log` gives the line below. It is identical in 88 of the 90 sweep `.log` files; the other 2 are the socket-first copy. Paste all 56 numbers.

`# cores=56 hwthreads=56 sockets=2 cores/socket=28 pin order: 0 1 2 3 … 55`

Then the two tag lines, copy-pasted (8 spaces after `T=28`/`T=56`):
```
T=28        0.7 Mops/s  (0.7 0.7 0.7)  <- first socket full
T=56        0.7 Mops/s  (0.7 0.7 0.7)  <- every core busy
```
The log's first line, `# …/bin/benchlog coarse shards=1 mix=80/10/10 writers=0`, shows the logging wrapper (see deviation 7).

**Interleaving statement.**
- Frontera numbers CPUs alternately by socket: node0 = even CPUs. Sources: `cpu_socket_map.txt`; `topology.txt` says `layout: interleaved`.
- sweep.sh runs `taskset -c <first T CPUs in CPU-number order>` on the whole process. Every even T is therefore split evenly across the sockets: T=2 → 1+1, 8 → 4+4, 28 → 14+14, 32 → 16+16, 40 → 20+20, 56 → 28+28.
- Threads span both sockets from T=2, and socket 0 is not full before T=55 (sweep point T=56).
- The T=28 tag is computed as `t == cores/socket`, so on this numbering it is wrong.

Effect, cross-node (c207-021 vs c208-017), median (min..max):
- Coarse T=28: 0.7 (0.7..0.7) in CPU order vs 1.0 (1.0..1.1) socket-first.
- sharded:mutex N=256 T=28: 34.7 (34.5..34.7) vs 44.9 (44.8..44.9).

**Socket-first supplement.** `jobs/sweep_socketfirst.sh` is the provided sweep.sh with two changes: one `sort`, which now orders by package id and then CPU number, and an overridable `SWEEP_SYSFS` path. The diff shows nothing else. Its log line reads `pin order: 0 2 4 … 54 1 3 … 55` (`socketfirst_*/sweep_socketfirst/coarse.log`), and its T=28 tag is correct. The coarse curve then steps down at the real boundary: T=28 1.0 (1.0..1.1) → T=40 0.7 (0.7..0.7) Mops/s. The graded curves use the unmodified sweep.sh; this sweep is supplementary.

### A3. TSan evidence
Excerpt of `tsan_ls6_20261004-165301_3488178/tsan_summary.txt`:
```
== TSan evidence for the report (LS6 c309-005.ls6.tacc.utexas.edu, g++ (GCC) 15.2.0) ==
test_map_tsan: exit=0  wall=1 s
last line: all checks passed
TSan banner: ***** Running under ThreadSanitizer v3 (pid 1243113) *****
ThreadSanitizer WARNING/SUMMARY lines: 0
test_locks_tsan: exit=0  wall=2 s
last line: all checks passed
TSan banner: ***** Running under ThreadSanitizer v3 (pid 1243360) *****
ThreadSanitizer WARNING/SUMMARY lines: 0
race_control: exit=66  wall=0 s
SUMMARY: ThreadSanitizer: data race …/race.cpp:3 in operator()
```
- Runtime: `libtsan.so.2 => /opt/apps/gcc/15.2.0/lib64/libtsan.so.2`.
- Built with the Makefile TSAN flags (`-std=c++20 -O1 -g -fsanitize=thread -pthread`).
- The two test programs ran separately, each with `TSAN_OPTIONS="halt_on_error=1 verbosity=1"` under `setarch -R`. The positive control ran with `halt_on_error=1`.
- `tests/*.cpp` md5s match the starter commit febc203.
- The 8×5000 and 64×250 counts come from the tests' own `SCALE=4` under TSan (20000/4 and 20000/4/20).
- TSan cannot run on Frontera (staff answer in `edposts.txt`), so it ran on Lonestar6.
- The earlier run (161507, c302-005) gave the same exit codes with identical source md5s.

**Not final.**
- This run built `HAVE_HASHED 0` with the stub `hash_map.h` (md5 44e0d205…), and `job.log` warns "not every parts.h switch is 1".
- Since then (17:02, uncommitted) the working tree has `parts.h` with all four switches at 1 (md5 2e7c9dd6…) and an implemented `hash_map.h` (557a05b7…). No TSan run has used them.
- Re-run `jobs/ls6_tsan.slurm` on the final tree and quote that run. Check four things:
  - its `provenance.txt` shows four `1`s and the final md5s;
  - there is no WARNING line in `job.log`;
  - `test_map_tsan.stdout` contains the `StripedHashMap<mutex>(tiny)` block (7 buckets / 3 stripes);
  - both programs still end with "all checks passed" and 0 WARNING/SUMMARY lines.
- Risk to watch: `PART7_NOTES.md` item 7, where TSan's deadlock detector fails when one thread holds more than 64 mutexes. The tests use 64 stripes.

### A4. Who did what (TEMPLATE: edit before submitting)
> [Student name] ([EID]) wrote `CoarseMap` (Part 1, with Jonathan Bennikutty), `ShardedMap` (Part 4), the four Part 5 locks, and `RWLock`/`RWLockWP` (Part 6). [Student] also designed and ran the measurement campaign: the Frontera sweeps and perf runs for Parts 2–6 (jobs 7972219, 7972291, 7972388) and the Lonestar6 TSan and relaxed-ordering runs. [Student] wrote report sections 4–6 and the appendix. Jonathan Bennikutty (jb83976) worked with [Student] on the Part 1 code [and the Part 2–3 analysis] and wrote report sections 1–3. He helped with Part 5 [specify: e.g. lock review / relaxed experiment / TSan debugging] and wrote the Part 7 striped hash table, its measurements and its report section. Each of us reviewed the other's sections, and both of us can explain every part. [If course policy requires it: the job scripts, plot script, socket-first sweep copy and the drafting of PREDICTIONS.md and PART7_NOTES.md were done with AI assistance (Claude Code; these files carry that header). We ran and checked every measurement ourselves.]

### A5. 8-page budget (estimate; assumes letter paper with a 6.5-in text column)
At native size the sweep and count figures are 7×4.2 in, which is 3.9 in tall at full width. Two-up at 3.2 in their text shrinks to about 4–5 pt. **Re-render them at about 3.2×2.1 in with 7–8 pt fonts.** The mix grid is 12.6×6.8 in natively: at full width it is 3.5 in tall, but its text is 3.6–5.2 pt, so **re-render it at about 6.5×3.6 in** too.

| § | Content | Figure / table | Pages |
|---|---|---|---|
| 0 | Machine and protocol (A1, A2, deviation list) | lscpu excerpt | 0.45 |
| 1 | size() lock, copies | — | 0.2 |
| 2 | Prediction vs measured | **Fig 1 `part2_coarse`** (essential; add prediction band) | 0.5 |
| 3 | MESI and handoff prose | **Table 1** T=1/8/28 (ops + Mops min..max columns) | 1.0 |
| 4 | Lock order, collision argument | **Fig 2 `part4_coarse_vs_sharded`** (essential; two-up with Fig 1) | 0.9 |
| 5 | Locks | **Fig 3 `part5_five_locks`**, **Fig 4 `part5_shardcount`** (covers Part 4 and Part 5 shard counts), **Table 2** 1-shard and **Table 3** 32-on-8 (each with ops and min..max), relaxed experiment in 4 lines | 1.8 |
| 6 | RW | **Fig 5 `part6_mix_grid`** (full width, about 3.5 in), **Table 4** from `writers_table.tsv` | 1.1 |
| 7 | Hash table (pending) | misses/op vs chain length, stripe sweep, padding/HITM table (with ops) | 1.6 |
| A | TSan lines, who did what | — | 0.25 |
| | **Total** | | **7.8** |

Going over 8 pages costs 5 points, and this budget leaves 0.2 page of margin.

- **Drop `part4_shardcount.png`.** `part5_shardcount.png` plots the same mutex T=1/T=32 data alongside ttas and park.
- **Drop `part6_writers.png` and use Table 4 instead.** On a linear axis the N=1 bars (≤ 9.1 Mops/s) are invisible next to the N=4096 bars, which reach 235.9 Mops/s.

Figure fixes needed for the "plots labeled, shared axes, spread stated" row:
- **Fig 1 prediction overlay.** Fig 1 has none. Draw the PREDICTIONS.md bands: T=1 2–3.5; T=2–4 at 40–60% of T=1; T=8–28 0.5–1.2; past 28 a 20–40% step down; flat past 56.
- **x-label.** Figs 1, 2, 3 and 5 say "threads (pinned, one per core)". Change it to "threads (process pinned to first T CPUs; > 56 oversubscribed)". taskset pins a CPU set, not one thread per core.
- **Dashed "socket boundary (28)" line.** It is the real boundary only for the socket-first curves. In Fig 3, Fig 5 and the CPU-order curves of Figs 1–2, relabel it (e.g. "sweep.sh tag; real boundary under interleaving: none before 55") or remove it.
- **Spread.** Every caption should state "bars = min..max of 3 runs". The shard-count plots have no bars; the min..max values are in each `shardcount*/T*/N*/*.log`.
- **Fig 4 T=1 curves.** They are flattened on the linear y axis. Use a log y axis or a second panel, because Part 4 grades the T=1 sweep too.

### A6. Deliverables checklist
- **Code:**
  - Unchanged since the runs: `concurrent_map.h` (efbf5aae…) and `locks.h` (a68b2df2…), identical to every Frontera and LS6 TSan build. The relaxed run used `locks_relaxed.diff` on purpose.
  - Changed since the runs: `parts.h` is now all four switches = 1 (2e7c9dd6…), and `hash_map.h` is now implemented (557a05b7…). Both are uncommitted, and neither has been through TSan yet.
  - bench and the tests include `hash_map.h` only under `HAVE_HASHED`, so the Parts 2–6 data still describes the submitted Parts 1–6 code as long as `concurrent_map.h` and `locks.h` stay unchanged. If either changes, re-measure.
- **Sweep CSVs, named as `make sweep` names them:**
  - `part2_*/sweep/coarse.csv` (graded Part 2)
  - `part4_*/sweep_shards256/sharded_mutex.csv`, plus `part4_*/sweep_coarse_ref/coarse.csv` (same node)
  - `part5_*/sweep_shards4096/sharded_{mutex,tas,ttas,ticket,park}.csv`
  - `part6_*/mix{100-0-0,80-10-10,50-25-25}_shards{4096,1}/sharded_{ttas,rw,rwp,shared_mutex}.csv` (24 files, 10 points each)
  - `part6_*/writers{1,4}_shards{1,4096}/sharded_{rw,rwp}.csv` (8 files, T = 8/28/56)
  - Supplementary: `socketfirst_*/sweep_socketfirst/{coarse,sharded_mutex}.csv`
  - Each CSV comes with a `.log` (pin order, tags, the 3 runs), a `.raw` (bench's own lines) and a `.raw.meta` (rc, affinity, env, warm-up). All 90 `.raw.meta` files have rc=0.
- **Shard-count data as produced by bench (48 `.raw` files):**
  - `part4_*/shardcount/T{1,32}/N{1,4,16,64,256,1024,4096,16384}/sharded_mutex.raw` and `shardcount_sharded_mutex.csv`
  - `part5_*/shardcount_{ttas,park}/T*/N*/…raw` and `shardcount_sharded_{ttas,park}.csv`
  - Mix data: the `.raw` files in the mix and writers directories, plus `writers_table.tsv` (rd/wr split).
  - Part 7 bucket-count and stripe-count data: pending.
- **perfstat output for every counter table.** There are 66 files: 63 table runs plus 3 clock runs. Each contains bench's line with the op count. The *report table itself* must also show ops.
  - Table 1: `part3_*/perf/coarse_T{1,8,28}_S1.r{1,2,3}.txt`
  - Table 2: `part5_*/perf_1shard_8on8/sharded_*.r{1,2,3}.txt`
  - Table 3: `part5_*/perf_32on8/sharded_*.r{1,2,3}.txt`
  - Clock: `part5_*/clock/*.r{1,2,3}.txt`
  - Supplementary `:u` runs: `part3u_*/perf/*`, `part5_*/perf_1shard_8on8_user/*`
  - Part 7 HITM table: pending.
- **Predictions:** `PREDICTIONS.md`.
  - Committed in 33f916a at 15:07:52.
  - The Part 5 section was amended in 76656b7 at 15:51:29: the note that paranoid=0 counts kernel work, and N changed from 256 to 4096. The amendment came after the Parts 2–4 results and before the Part 5 run; say so plainly.
  - Run starts: part2 15:20:50, part5 16:01:57, part6 16:17:29.
- **Machine:** lscpu.txt, topology.txt, cpu_socket_map.txt, numactl_H.txt and provenance.txt are in all 7 Frontera result dirs. The LS6 dirs have only provenance (TSan) or `report_lines.txt` (relaxed).

**Deviations to disclose (one compact list in §0):**
1. **Interleaved CPU numbering.** sweep.sh's T=28 tag is wrong (A2).
2. **perf CPU lists.** perf runs used socket-0 lists (`S0_1=0`, `S0_8=0,2,…,14`, `S0_28` = all even CPUs). The README's `CPUS=0-7` and perfstat's default first-T CPUs would each split 4+4 or 14+14 across the sockets.
3. **DELAY tuned to the warm-up.**
   - DELAY = 1.5 × (warm-up of a single-thread probe run) + 200 ms, which gave 320–390 ms against measured warm-ups of 80–128 ms, instead of the default 1500 ms. No run needed the warm-up-overlap rerun.
   - Per-op values are reported as perfstat prints them, divided by *all* ops of the run. Footnote once: f = 0.947–0.962, so the true per-op value ≈ printed value / f.
   - The `busy`/`busy_ref` columns of `perf_32on8_table.tsv` ARE f-corrected. On the printed cyc/op the README formula gives mutex 0.934, park 0.929, tas 0.885, ticket 0.948, ttas 0.883, against the table's 0.98/0.98/0.92/1.00/0.92. Report one set and label it.
4. **Extra events.** Added to the README lists: remote_hitm (Part 3, 1-shard), task-clock (all) and ref-cycles (32-on-8, clock). cpu-migrations is part of perfstat's default list. The `:u` tables are supplementary, because with paranoid=0 the all-mode counts include kernel work.
5. **Socket-first sweep.** It used a modified copy of sweep.sh, on a different node (c208-017).
6. **Shard-count data.**
   - Collected with single-point sweep.sh runs, pinned and median of 3, instead of the README's unpinned `./bench` loop.
   - N was widened to 1–16384, against the README's 16–4096.
   - T=32 ran on CPUs 0–31, i.e. 16+16 across both sockets. That is not comparable with the socket-0-only 32-on-8 perf runs.
7. **Logging wrapper and perfstat invocation.**
   - sweep.sh ran bench through the transparent wrapper `bin/benchlog`, which adds a timeout and logging only.
   - perfstat.sh was called directly with explicit CPUS, DELAY and EVENTS. This is the same as `make perf`, which passes these through. It ran `./bench` without the wrapper.
   - bench.cpp, sweep.sh, perfstat.sh and the Makefile are md5-identical to starter commit febc203.
8. **Shard count in the Part 5 sweep.** The five-lock sweep used the chosen N=4096 instead of the literal `SHARDS=256` in the README command. For 32-on-8 the README text says "at your chosen shard count", so 4096 there follows the text.
9. **Compilers differ by job.** Frontera g++ 13.2, LS6 TSan g++ 15.2, relaxed experiment g++ 11.2 (LS6 c309-005).
10. **Nonzero cpu-migrations.** taskset pins the *process* to a CPU set, not each thread to a core. Counts per run:
    - coarse T=1: 0–1
    - coarse T=8: 95–110
    - coarse T=28: 677–952 (≈ 2×10⁻⁴/op)
    - 32-on-8 mutex: 7679–8490 (≈ 7×10⁻⁵/op)
    - 32-on-8 park: 8971–9248
11. **Part 7 code.** Every measured binary and both TSan runs had HAVE_HASHED=0. The final TSan run is pending (A3).

### A7. Prose that does work (Report quality, 3 pts; not covered elsewhere)
- Every answer to a README question carries a number and the file it came from.
- Use median (min..max) wherever two values are compared.
- Mark estimates as estimates.
- Do not restate the assignment or the code comments.
- State the prediction, then the measured value, then held/failed in one line.
- Cut any sentence that has no number or mechanism (cache line, MESI state, scheduler action) in it.


---
