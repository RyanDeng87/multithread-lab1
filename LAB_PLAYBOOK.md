# ECE 379K Labs — Playbook

How to approach every lab in this course, learned from Lab 0 (95/100), with a Lab 1
section built from the actual Lab 1 starter files and tests.

**Read this before starting any lab.** Section 1 says why; section 2 is the standing rules;
section 3 is Lab 1.

---

## 1. What Lab 0 actually graded

Lab 0 scored **95**. A classmate's submission scored **100**. Diffing the two graded stdout
blocks line by line, **exactly one line differs**:

```
handout: [D1] store=10 load=10 fetch_add_returned=10 after=15 exchange_returned=15 after=99
100:     [D1] store=10 load=10 fetch_add_returned=10 after=15 exchange_returned=15 after=99
95:      [D1] store=10 load=10 fetch_add_returned=10 after=15 exchange_returned=18 after=99
```

The handout listed five atomic operations, and its sample line was only reachable if `a += 3`
did not run. We ran all five in order and documented the mismatch; the 100 skipped `+=`. Part
D1/D2 is worth 10%, so losing D1 accounts for exactly 5 points. (To confirm, open the per-test
breakdown on Gradescope.)

Everything else we did beyond the 100 earned nothing extra:

| | ours (95) | theirs (100) |
|---|---|---|
| Writeup | 34 KB, 3 machines, disassembly, every claim verified | ~5 KB; malformed D3 table, no ratios, several wrong answers |
| Makefile | portable `libatomic` probe, `dangling` target | starter, unchanged |
| `job.slurm` | rewritten, documented | starter TODO comments left in, `-e` still splitting streams |
| `tacc_output.txt` | clean batch output | pasted with shell prompts |
| `AI_LOG.md` | 12 KB | one paragraph |

**The lesson is about where points live, not about effort being worthless:**

1. **Exact-match surfaces are binary and unforgiving.** Autograded output lines, test
   assertions, class/method names, file names. One wrong value is a lost item, regardless of
   how well the deviation is explained.
2. **When the prose spec and the expected output disagree, the expected output wins.** It *is*
   the grader. Implement to it, and put the disagreement in the report or ask staff — never the
   other way around.
3. **Hand-graded prose in Lab 0 was graded on coverage, not depth.** Lab 1 is different (section
   3): 78 of its 100 points are measurement and report, against a specific numeric rubric with an
   8-page cap. Depth now pays — but only where a rubric row asks for it.

---

## 2. Standing rules for every lab

### Grading

- **Build a rubric map before writing code.** One row per rubric item: the artifact that earns
  it, and where that artifact will live. Anything not on the map is optional.
- **Treat provided tests and sample output as the specification.** Read the tests line by line
  before implementing. Where they are stricter than the prose, they win.
- **Find every hard gate** ("earns zero", "loses N points", "graded as unpinned") and put each on
  the pre-submission checklist. Gates outweigh any single rubric row.
- **Ask staff about genuine contradictions on day one,** not the night it is due. A forum answer
  turns a judgement call into a non-issue.
- **When a decision trades points for principle, say the point cost out loud,** then decide.
  "This will very likely cost ~5 points" is the sentence that was missing in Lab 0.

### Verification

- **Run every technical claim before writing it down.** In Lab 0 the assistant was confidently
  wrong five times, and every one was caught only by compiling or running:
  - asserted `c += 1` on a `volatile int` warns in C++20 — it does not; `++c` does
  - quoted a GCC `note:` about `mutable` that does not exist
  - put a Clang-only flag (`-fsanitize-address-use-after-return=always`) in a GCC Makefile
  - predicted relaxed vs. seq_cst would diverge on ARM — measured 0.1% apart
  - blamed ASan failures on the 64K-page kernel — the error message named `xalt` outright
- **Read the error message before theorising.** The plausible architectural explanation is the
  one to distrust when a precise message is already on screen.
- **Disassemble to settle "what did the compiler do" questions.** `objdump -d` turned Lab 0's D3
  hypotheses into facts. Lab 1's memory-ordering questions benefit the same way.
- **Regenerate quoted tool output last.** Any edit shifts line numbers; every `file.cpp:NNN` in
  the report must come from a final run.

### Environment (lessons from mario, Vista, LS6)

| machine | trap | fix |
|---|---|---|
| mario | default `g++` is **8.5**; `-std=c++20` rejected | `source /opt/rh/gcc-toolset-14/enable` |
| any TACC | default toolchain is not GCC | `module load gcc`, then check `g++ --version` |
| any TACC | `xalt` `LD_PRELOAD`s ahead of sanitizer runtimes; ASan refuses to start | `module unload xalt` before sanitizer runs |
| TACC compute | LeakSanitizer needs `ptrace`; "fatal error", not a leak | `ASAN_OPTIONS=detect_leaks=0` |
| TACC login | never build or run there | `idev`, or `sbatch` from login (the job runs on a compute node) |
| Windows | `python` is the Microsoft Store stub | use WSL's `python3` |
| Windows→WSL | nested heredocs mangle backticks | write scripts to a file, then run the file |

**Do a full environment smoke test on the graded machine in the first session**, before writing
any lab code: log in, load modules, build the starter, run the starter tests.

### Submission hygiene

- Submitted files contain only what a grader needs. **No mentions of the forum, other students,
  or reasoning narrative** in code comments; code comments explain the code.
- The syllabus AI citation comment is required in source. Add it **last** — every edit above it
  shifts the line ranges, which broke three times in Lab 0.
- Keep verification tooling in a separate `tests/`-style directory that nothing submitted
  references. Zip the deliverables flat, with no wrapper folder.
- Before submitting, diff your graded output against every expected line in the handout.

### Process (for the assistant)

- Recommend, don't present neutral menus, when one option is clearly better for the grade.
- Mark confidence. "Verified by running" and "from memory, unverified" are different claims.
- Keep lists and summaries concise; the user asks for numbered steps and short answers.
- Separate "what to submit" from "what I generated for myself" in every file listing.

---

## 3. Lab 1 — concurrent map, locks, hash table

Pairs, three weeks. **The README has no due date — confirm it first.** Graded code is run by the
staff's tests with every `parts.h` switch at 1; the report is graded against each part's
questions.

### 3.1 Where the 100 points are

| part | code (tests + TSan) | measurement + report |
|---|---|---|
| 1 — Coarse lock | 4 | 4 |
| 2 — Measure | — | 8 |
| 3 — Explain | — | 12 |
| 4 — Shard | 4 | 10 |
| 5 — Locks | 6 | 14 |
| 6 — Reader/writer | 4 | 10 |
| 7 — Hash table | 4 | 12 |
| Report quality | — | 8 |
| **total** | **22** | **78** |

**78% of the grade is measurement and report.** Code is the entry ticket; budget node time and
writing time accordingly.

### 3.2 Hard gates

| gate | consequence |
|---|---|
| Part not TSan-clean under **staff** tests | **zero code points** for that part |
| `parts.h` switches not all 1 at submission | listed deliverable; any part left at 0 is compiled out of the tests |
| Report over 8 pages | −5 |
| Missing `lscpu` output or pin order / socket boundary | −2, **and every sweep graded as unpinned** |
| Counter table without op count, or raw counts instead of per-op | **zero for that table** |
| Measurement without protocol (pinned, median of 3, machine recorded) | protocol points only |
| Partner cannot explain a part at checkoff | pair loses that part's code points |
| `bench.cpp` measurement modified | explicitly forbidden ("do not modify the measurement") |
| Relaxed-ordering experiment left in the submitted `locks.h` | TSan fails → zero code points for Part 5 |

### 3.3 Code traps found in the provided tests

These are the Lab 1 equivalent of `[D1]`: places where the README's prose is looser than the
assertion that grades it.

1. **`insert` must overwrite.** The README says "true if key was new". The test also requires:
   ```cpp
   CHECK(m.insert(1, 10) == true);
   CHECK(m.insert(1, 11) == false);          // overwrite, not new
   CHECK(m.find(1, v) == true && v == 11);
   ```
   `std::map::insert` does **not** overwrite and fails this — verified. Use
   `insert_or_assign(k, v).second`, which overwrites and still reports "was new". Apply the same
   semantics to the hand-written hash table in Part 7.
2. **Exact signatures the tests construct:**
   - `CoarseMap<K,V>` — default-constructed, no arguments
   - `ShardedMap<K, V, Lock = std::mutex, bool Padded = true>` — `explicit ShardedMap(std::size_t nshards)`, `shard_count()`; tested with 16 and **1** shard
   - `StripedHashMap<K, V, Lock = std::mutex, bool Padded = true>` — `(nbuckets, nstripes)`, `bucket_count()`, `stripe_count()`; tested with `(1<<16, 64)`, `(1<<16, 1)`, and **`(7, 3)`**
   - Lock class names exactly: `TASLock TTASLock TicketLock ParkingLock RWLock RWLockWP`
3. **`find` and `size` are `const`,** so every lock member must be `mutable`.
4. **`ShardedMap<long,long,std::shared_mutex>` is tested,** so `find` must go through
   `ReadGuard<Lock>` from `interface.h`, not `lock_guard`.
5. **Exact `size()` deadlock test.** Two threads call `size()` while four insert and erase. Lock
   every shard **in index order**, sum, then unlock. Any other order hangs the test rather than
   failing it — a hang is a fail.
6. **64-thread oversubscription test** for every Part 5 lock. `TicketLock` must yield after
   bounded spins or this test crawls; `ParkingLock` must wake sleepers correctly or it hangs.
   For `ParkingLock`, follow the three-state shape from Drepper's *Futexes Are Tricky*; the
   classic lost-wakeup bug is a woken waiter re-acquiring with CAS(0→1) instead of
   `exchange(2)`. *(From memory — confirm with the 64-thread test under TSan.)*
7. **The spin hint must compile on whatever you test on.** `__builtin_ia32_pause()` is x86-only;
   guard it with `#if defined(__x86_64__) || defined(__i386__)` as `test_locks.cpp` does, with an
   AArch64 `yield` branch.
8. **`Padded = true`:** `alignas(CACHE_LINE)` per shard/stripe plus a `static_assert` on
   `sizeof % CACHE_LINE == 0`. Check it under `std::shared_mutex`, whose size differs from
   `std::mutex`.
9. **Toolchain floor:** `std::atomic::wait`/`notify_one` (ParkingLock) needs **libstdc++ ≥ 11**;
   `-std=c++20` and `std::jthread` need **GCC ≥ 10**. Verified on g++ 13.3 locally.

### 3.4 Day-one checks on Frontera

The graded machine is **Frontera** (2× Xeon Platinum 8280, 56 cores, SMT off) — not Vista, where
Lab 0 ran. Vista is ARM and has no `xsnp_hitm` event, so no graded counter data can come from it.

```bash
ssh <user>@frontera.tacc.utexas.edu
/usr/local/etc/taccinfo                  # is TRA25006 valid HERE, with hours left?
sinfo -o "%P %a %F"                      # dev queue name, likely "development"
module spider gcc                        # need >= 11 for atomic::wait
idev -p development -N 1 -t 01:00:00     # never build on the login node
module load gcc/<ver>; g++ --version
perf stat -e cycles true                 # must print a number, not <not supported>
perf list | grep xsnp                    # must list the HITM event
lscpu                                    # save this output: it is a graded artifact
cd starter_files && make test && make tsan
```

If `taccinfo` shows no Frontera allocation, or either `perf` check fails, **tell staff that
day** — the README says so explicitly, and allocation problems take days to resolve. If TSan
fails at startup there, try `module unload xalt` first (it broke ASan in Lab 0; unverified for
TSan).

### 3.5 Measurement protocol and artifacts

- **Write predictions before running, and commit them.** Points ride on "prediction made before
  the run" in Parts 2, 5, and 7. A dated git commit is the evidence.
- **Save every raw artifact as produced:** every `*.csv` under its `make sweep` name, every
  `make perf` output, `lscpu`, and the core count / socket boundary / pin order `sweep.sh`
  prints. Each is a deliverable, not scratch.
- **Every counter table carries the op count and per-op values.** `perfstat.sh` does the
  division — keep its output verbatim.
- **State run-to-run spread wherever a difference is claimed.** Median of 3 gives min/max for
  free; a difference inside the spread is a result if you say so.
- **Batch the node time.** One `sbatch` script per part that runs every sweep and perf run the
  part needs, writing into a dated directory. Re-runs then cost one command.
- **Sanity-check each table against the theory before writing it up** (L1 misses per op at T=1
  vs. tree depth; HITM per op vs. expected handoffs). A number that disagrees with the model is
  either a finding or a measurement bug — find out which before it goes in the report.

### 3.6 Report: eight pages, rubric-driven

- One subsection per rubric row, in rubric order. Each answer leads with the number the row
  asks for, then the sentence of explanation.
- Plots: linear axis, labeled, comparable curves on shared axes, vertical lines at 28 and 56.
- Required appendix, worth 2 points on its own: both TSan summary lines with all parts enabled,
  `lscpu`, pin order + socket boundary, and the who-did-what paragraph. Missing `lscpu` or pin
  order *also* triggers the unpinned gate in 3.2, so this is the cheapest place to lose the most.
- Set up the markdown → PDF pipeline (the `pdf.css` already used for the project proposal)
  **in week one,** and check the page count every time the report grows.
- Lab 0's writeup would have blown this budget several times over. Compress: tables over prose,
  no restating of the question, no section that no rubric row asks for.

### 3.7 Suggested schedule (three weeks)

| when | goal |
|---|---|
| week 1, day 1 | Frontera smoke test (3.4); confirm due date; rubric map; ask staff anything ambiguous |
| week 1 | Parts 1 and 4 TSan-clean; write Part 2 prediction and commit; first coarse + sharded sweeps |
| week 2 | Parts 5 and 6 TSan-clean; relaxed experiment on a **branch**; five-lock sweep, both counter tables, mix × shard runs |
| week 3, start | Part 7 TSan-clean; bucket, stripe, padding runs with HITM |
| week 3, end | report to ≤ 8 pages; final TSan with all `parts.h` = 1; package and verify |

### 3.8 Pre-submission checklist

- [ ] `parts.h`: all four switches = 1
- [ ] `make test` and `make tsan` both clean with every part enabled — on the graded toolchain
- [ ] `locks.h` has acquire/release ordering — the relaxed experiment is **not** in it
- [ ] `bench.cpp`, `sweep.sh`, `perfstat.sh` unmodified
- [ ] Every CSV and `make perf` output the report cites is in the submission, named as produced
- [ ] `lscpu`, pin order, and socket boundary in the report
- [ ] Every counter table shows op count and per-op values
- [ ] Every prediction has a commit dated before its run
- [ ] Spread stated beside every claimed difference
- [ ] Both TSan summary lines and the who-did-what paragraph present
- [ ] Report PDF ≤ 8 pages
- [ ] AI citation comments added last; line ranges verified against the final files
- [ ] Both partners can explain every part
