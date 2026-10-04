// bench.cpp -- Lab 1 throughput harness.  PROVIDED; do not modify the
// measurement.  The knobs you need are all on the command line or in
// the environment.
//
//   ./bench IMPL THREADS [SHARDS] [SECONDS]
//
//   IMPL     coarse
//            sharded[:LOCK][:nopad]    N std::maps, N locks
//            hashed[:LOCK][:nopad]     B buckets, N stripe locks
//   LOCK     mutex (default) | shared_mutex
//            tas | ttas | ticket | park          (Part 5)
//            rw | rwp                            (Part 6)
//   THREADS  worker threads
//   SHARDS   shard count (sharded) or stripe count (hashed); default 16
//   SECONDS  how long each thread runs (default 2)
//
// Environment:
//   MIX=80/10/10   percent find/insert/erase per thread (default)
//   WRITERS=n      make n of the THREADS pure writers (50% insert,
//                  50% erase) and the rest pure readers, ignoring MIX;
//                  throughput is then reported per class as well
//   BUCKETS=b      bucket count for hashed (default 2*KEYS)
//
// Each thread runs its OWN random-number generator and performs the
// mix on keys in [0, KEYS).  Throughput is total
// operations / wall time, printed as one line ending in Mops/s:
//
//   sharded:ttas T=8   shards=256  mix=80/10/10  123456789 ops
//                                             2001 ms   61.7 Mops/s
//
// The thread count is the only thing you vary in a sweep; sweep.sh
// pins the threads and does that for you.  perfstat.sh wraps one
// pinned run in perf stat and reports the counters per operation.
// The single-threaded warm-up time is printed on stderr ("warm-up
// NNN ms") so that a perf stat --delay can be chosen to skip it.

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <random>
#include <shared_mutex>
#include <string>
#include <thread>
#include <vector>

#include "parts.h"
#include "interface.h"
#include "concurrent_map.h"
#if HAVE_LOCKS || HAVE_RW
#include "locks.h"
#endif
#if HAVE_HASHED
#include "hash_map.h"
#endif

static constexpr long KEYS = 1 << 20;     // key space: 1M keys
static std::atomic<long> g_sink{0};       // keeps find() results live

struct Args {
    std::string impl;
    int         threads  = 1;
    std::size_t shards   = 16;
    double      seconds  = 2.0;
    int         pf = 80, pi = 10;         // find %, insert %; rest erase
    int         writers  = 0;
    std::size_t buckets  = 2 * KEYS;
    std::string mix_text = "80/10/10";
};

/* One thread's loop against any map with the lab interface.
   Reader-only and writer-only roles are used when WRITERS is set. */
template <typename Map>
static void worker(Map& m, int id, const Args& a, bool writer_role,
                   bool role_mode, long* ops_out)
{
    std::mt19937_64 rng(0xC0FFEE + id);          // per-thread state
    std::uniform_int_distribution<long> key(0, KEYS - 1);
    std::uniform_int_distribution<int>  op(0, 99);

    int pf = a.pf, pi = a.pf + a.pi;
    if (role_mode) {                 /* pure reader or pure writer */
        pf = writer_role ? 0  : 100;
        pi = writer_role ? 50 : 100;
    }

    auto deadline = std::chrono::steady_clock::now()
                  + std::chrono::duration<double>(a.seconds);
    long ops = 0;
    long v = 0, sink = 0;
    while (true) {
        /* check the clock every 1024 ops, not every op */
        for (int i = 0; i < 1024; ++i, ++ops) {
            long k = key(rng);
            int  o = op(rng);
            if      (o < pf) { if (m.find(k, v)) sink += v; }
            else if (o < pi) m.insert(k, k * 2);
            else             m.erase(k);
        }
        if (std::chrono::steady_clock::now() >= deadline) break;
    }
    /* The found values must be consumed.  A find whose result is
       never read is a side-effect-free loop, and the compiler is
       allowed to delete it -- leaving lock/unlock around nothing,
       which measures the lock and not the map. */
    g_sink.fetch_add(sink, std::memory_order_relaxed);
    *ops_out = ops;
}

template <typename Map>
static void run(Map& m, const Args& a)
{
    static_assert(ConcurrentMap<Map, long, long>);

    /* warm the map so finds mostly hit: half the key space present.
       The warm-up is single-threaded and is NOT part of the
       measurement; its duration is printed so that a perf stat run
       can skip it with --delay (see perfstat.sh). */
    auto w0 = std::chrono::steady_clock::now();
    for (long k = 0; k < KEYS; k += 2) m.insert(k, k * 2);
    std::fprintf(stderr, "warm-up %.0f ms\n",
                 std::chrono::duration<double, std::milli>(
                     std::chrono::steady_clock::now() - w0).count());

    const int  T = a.threads;
    const bool role_mode = a.writers > 0;
    std::vector<long> ops(T, 0);
    auto t0 = std::chrono::steady_clock::now();
    {
        std::vector<std::jthread> workers;
        for (int t = 0; t < T; ++t)
            workers.emplace_back(worker<Map>, std::ref(m), t,
                                 std::cref(a), t < a.writers, role_mode,
                                 &ops[t]);
        /* emplace_back(fn, args...): the thread is constructed in
           place inside the vector.  A std::jthread cannot be copied,
           so push_back(t) would not compile. */
    }                                            // join
    double ms = std::chrono::duration<double, std::milli>(
                    std::chrono::steady_clock::now() - t0).count();

    long total = 0, wr = 0;
    for (int t = 0; t < T; ++t) {
        total += ops[t];
        if (t < a.writers) wr += ops[t];
    }

    std::printf("%-14s T=%-3d shards=%-4zu mix=%-8s", a.impl.c_str(), T,
                a.shards, role_mode ? "roles" : a.mix_text.c_str());
    if (role_mode)
        std::printf(" rd=%.1f wr=%.1f Mops/s ",
                    (total - wr) / ms / 1000.0, wr / ms / 1000.0);
    std::printf(" %12ld ops %7.0f ms %8.1f Mops/s\n",
                total, ms, total / ms / 1000.0);
}

/* ---- dispatch: IMPL string -> template instantiation --------------- */

[[noreturn]] static void die(const std::string& why)
{
    std::fprintf(stderr, "bench: %s\n", why.c_str());
    std::exit(2);
}

template <class Lock, bool Padded>
static void run_family(const std::string& fam, const Args& a)
{
    (void)a;                    /* unused until Part 4 is switched on */
    if (fam == "sharded") {
#if HAVE_SHARDED
        ShardedMap<long, long, Lock, Padded> m(a.shards);
        run(m, a);
        return;
#else
        die("sharded: set HAVE_SHARDED to 1 in parts.h");
#endif
    }
    if (fam == "hashed") {
#if HAVE_HASHED
        StripedHashMap<long, long, Lock, Padded> m(a.buckets, a.shards);
        run(m, a);
        return;
#else
        die("hashed: set HAVE_HASHED to 1 in parts.h");
#endif
    }
    die("unknown implementation family " + fam);
}

template <bool Padded>
static void run_lock(const std::string& fam, const std::string& lk,
                     const Args& a)
{
    if (lk == "mutex")
        return run_family<std::mutex, Padded>(fam, a);
    if (lk == "shared_mutex")
        return run_family<std::shared_mutex, Padded>(fam, a);
#if HAVE_LOCKS
    if (lk == "tas")    return run_family<TASLock, Padded>(fam, a);
    if (lk == "ttas")   return run_family<TTASLock, Padded>(fam, a);
    if (lk == "ticket") return run_family<TicketLock, Padded>(fam, a);
    if (lk == "park")   return run_family<ParkingLock, Padded>(fam, a);
#else
    if (lk == "tas" || lk == "ttas" || lk == "ticket" || lk == "park")
        die(lk + ": set HAVE_LOCKS to 1 in parts.h");
#endif
#if HAVE_RW
    if (lk == "rw")  return run_family<RWLock, Padded>(fam, a);
    if (lk == "rwp") return run_family<RWLockWP, Padded>(fam, a);
#else
    if (lk == "rw" || lk == "rwp")
        die(lk + ": set HAVE_RW to 1 in parts.h");
#endif
    die("unknown lock " + lk);
}

static void parse_mix(const char* s, Args& a)
{
    int f, i, e;
    if (std::sscanf(s, "%d/%d/%d", &f, &i, &e) != 3 || f < 0 || i < 0 ||
        e < 0 || f + i + e != 100)
        die(std::string("MIX must be F/I/E summing to 100, got ") + s);
    a.pf = f; a.pi = i; a.mix_text = s;
}

int main(int argc, char** argv)
{
    if (argc < 3) {
        std::fprintf(stderr,
            "usage: %s IMPL THREADS [SHARDS] [SECONDS]\n"
            "  IMPL = coarse | sharded[:LOCK][:nopad] | "
            "hashed[:LOCK][:nopad]\n"
            "  env: MIX=F/I/E  WRITERS=n  BUCKETS=b\n", argv[0]);
        return 2;
    }
    Args a;
    a.impl    = argv[1];
    a.threads = std::atoi(argv[2]);
    if (argc > 3) a.shards  = std::strtoul(argv[3], nullptr, 10);
    if (argc > 4) a.seconds = std::atof(argv[4]);
    if (a.threads < 1) a.threads = 1;
    if (a.seconds < 1.0) a.seconds = 1.0;     /* see the lab notes */

    if (const char* s = std::getenv("MIX"))     parse_mix(s, a);
    if (const char* s = std::getenv("WRITERS")) a.writers = std::atoi(s);
    if (const char* s = std::getenv("BUCKETS"))
        a.buckets = std::strtoul(s, nullptr, 10);
    if (a.writers > a.threads) a.writers = a.threads;

    /* IMPL grammar: family[:lock][:nopad] */
    std::vector<std::string> f;
    for (std::size_t p = 0, q; p <= a.impl.size(); p = q + 1) {
        q = a.impl.find(':', p);
        if (q == std::string::npos) q = a.impl.size();
        f.push_back(a.impl.substr(p, q - p));
    }
    std::string fam = f[0], lk = "mutex";
    bool padded = true;
    for (std::size_t i = 1; i < f.size(); ++i) {
        if (f[i] == "nopad")    padded = false;
        else if (f[i] == "pad") padded = true;
        else                    lk = f[i];
    }

    if (fam == "coarse") {
        a.shards = 1;
        CoarseMap<long, long> m;
        run(m, a);
        return 0;
    }
    if (padded) run_lock<true>(fam, lk, a);
    else        run_lock<false>(fam, lk, a);
    return 0;
}
