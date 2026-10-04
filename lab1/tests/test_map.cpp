// test_map.cpp -- correctness checks for every map class in the lab.
//
//   make test        plain build, runs single- and multi-threaded checks
//   make tsan        the same under ThreadSanitizer
//
// A green TSan run is a requirement, not a bonus: it is the only tool
// here that can prove the absence of a data race.  Passing this test
// without TSan proves almost nothing -- races are silent.
//
// Which classes are tested is controlled by parts.h.

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <shared_mutex>
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

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { ++failures; \
    std::printf("  FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
    } while (0)

#ifdef __SANITIZE_THREAD__
static constexpr int SCALE = 4;       /* TSan is ~10x slower */
#else
static constexpr int SCALE = 1;
#endif

/* Single-threaded semantics: the four operations behave like std::map. */
template <typename Map>
static void test_sequential(Map& m, const char* name)
{
    std::printf("%s: sequential\n", name);
    long v = -1;
    CHECK(m.size() == 0);
    CHECK(m.find(1, v) == false);
    CHECK(m.insert(1, 10) == true);           // new key
    CHECK(m.insert(1, 11) == false);          // overwrite, not new
    CHECK(m.find(1, v) == true && v == 11);
    CHECK(m.insert(2, 20) == true);
    CHECK(m.size() == 2);
    CHECK(m.erase(1) == true);
    CHECK(m.erase(1) == false);
    CHECK(m.find(1, v) == false);
    CHECK(m.size() == 1);
}

/* Disjoint keys per thread: every thread inserts, checks, and erases
   its own range.  Any interference between threads is a bug in the
   locking, and TSan will name the line. */
template <typename Map>
static void test_disjoint(Map& m, const char* name)
{
    std::printf("%s: disjoint keys, 8 threads\n", name);
    const int T = 8, PER = 4000 / SCALE;
    std::vector<int> bad(T, 0);
    {
        std::vector<std::jthread> workers;
        for (int t = 0; t < T; ++t)
            workers.emplace_back([&m, &bad, t] {
                long lo = (long)t * PER, hi = lo + PER, v;
                for (long k = lo; k < hi; ++k)
                    if (!m.insert(k, k + 1)) ++bad[t];
                for (long k = lo; k < hi; ++k)
                    if (!m.find(k, v) || v != k + 1) ++bad[t];
                for (long k = lo; k < hi; k += 2)
                    if (!m.erase(k)) ++bad[t];
            });
    }
    for (int t = 0; t < T; ++t) CHECK(bad[t] == 0);
    CHECK(m.size() == (std::size_t)T * PER / 2);
}

/* Contended keys: every thread hammers the SAME small key set.  The
   only invariant we can check is that nothing crashes and the final
   state is self-consistent; TSan does the real work here. */
template <typename Map>
static void test_contended(Map& m, const char* name)
{
    std::printf("%s: contended keys, 8 threads\n", name);
    const int T = 8;
    {
        std::vector<std::jthread> workers;
        for (int t = 0; t < T; ++t)
            workers.emplace_back([&m, t] {
                long v;
                for (int i = 0; i < 8000 / SCALE; ++i) {
                    long k = (i * 7 + t) % 64;
                    m.insert(k, i);
                    m.find(k, v);
                    if (i % 3 == 0) m.erase(k);
                }
            });
    }
    CHECK(m.size() <= 64);
}

/* size() from several threads at once while others insert and erase.
   An exact size() that takes its N locks in anything but one fixed
   global order deadlocks here -- the test hangs rather than fails.
   Each writer keeps a window of PAIRS keys present and slides it one
   key at a time, so an exact size() sees W*PAIRS plus at most one
   in-flight key per writer.  (An approximate size() can return
   anything; that is the point of the report question.) */
template <typename Map>
static void test_size_exact(Map& m, const char* name, bool exact)
{
    std::printf("%s: concurrent size(), %s\n", name,
                exact ? "exact" : "approximate");
    const int W = 4, S = 2, PAIRS = 64, ROUNDS = 500 / SCALE;
    std::vector<int> bad(S, 0);
    std::atomic<int>  ready{0};
    std::atomic<bool> stop{false};
    {
        std::vector<std::jthread> workers;
        for (int w = 0; w < W; ++w)
            workers.emplace_back([&m, &ready, w] {
                long base = (long)w * 1000000;
                for (long k = 0; k < PAIRS; ++k) m.insert(base + k, k);
                ready.fetch_add(1);
                for (int r = 0; r < ROUNDS; ++r) {
                    /* slide the window: insert one key past the
                       window, erase the oldest.  The count goes
                       PAIRS -> PAIRS+1 -> PAIRS, so an exact size()
                       is never off by more than W (one per writer). */
                    m.insert(base + PAIRS + r, r);
                    m.erase(base + r);
                }
            });
        for (int s = 0; s < S; ++s)
            workers.emplace_back([&m, &bad, &ready, &stop, s, exact] {
                while (ready.load() < W) { }
                while (!stop.load()) {
                    std::this_thread::yield();
                    std::size_t n = m.size();
                    if (exact && (n < (std::size_t)W * PAIRS ||
                                  n > (std::size_t)W * PAIRS + W))
                        ++bad[s];
                }
            });
        /* let the writers finish, then release the size() callers */
        for (int w = 0; w < W; ++w) workers[w].join();
        stop.store(true);
    }
    for (int s = 0; s < S; ++s) CHECK(bad[s] == 0);
}

template <typename Map, typename... Ctor>
static void test_all(const char* name, bool exact_size, Ctor... ctor)
{
    auto t0 = std::chrono::steady_clock::now();
    { Map m(ctor...); test_sequential(m, name); }
    { Map m(ctor...); test_disjoint(m, name); }
    { Map m(ctor...); test_contended(m, name); }
    { Map m(ctor...); test_size_exact(m, name, exact_size); }
    std::printf("%s: %.1f s\n", name,
                std::chrono::duration<double>(
                    std::chrono::steady_clock::now() - t0).count());
}

int main(void)
{
    static_assert(ConcurrentMap<CoarseMap<long, long>, long, long>);
    test_all<CoarseMap<long, long>>("CoarseMap", true);

#if HAVE_SHARDED
    static_assert(ConcurrentMap<ShardedMap<long, long>, long, long>);
    test_all<ShardedMap<long, long>>("ShardedMap<mutex>", true, 16);
    test_all<ShardedMap<long, long>>("ShardedMap<mutex>(1)", true, 1);
    test_all<ShardedMap<long, long, std::shared_mutex>>(
        "ShardedMap<shared_mutex>", true, 16);
    test_all<ShardedMap<long, long, std::mutex, false>>(
        "ShardedMap<mutex,nopad>", true, 16);
#endif
#if HAVE_LOCKS
    test_all<ShardedMap<long, long, TASLock>>(
        "ShardedMap<TAS>", true, 16);
    test_all<ShardedMap<long, long, TTASLock>>(
        "ShardedMap<TTAS>", true, 16);
    test_all<ShardedMap<long, long, TicketLock>>(
        "ShardedMap<Ticket>", true, 16);
    test_all<ShardedMap<long, long, ParkingLock>>(
        "ShardedMap<Parking>", true, 16);
#endif
#if HAVE_RW
    test_all<ShardedMap<long, long, RWLock>>("ShardedMap<RW>", true, 16);
    test_all<ShardedMap<long, long, RWLockWP>>(
        "ShardedMap<RWWP>", true, 16);
#endif
#if HAVE_HASHED
    static_assert(ConcurrentMap<StripedHashMap<long, long>, long, long>);
    test_all<StripedHashMap<long, long>>(
        "StripedHashMap<mutex>", true, 1 << 16, 64);
    test_all<StripedHashMap<long, long>>(
        "StripedHashMap<mutex>(1 stripe)", true, 1 << 16, 1);
    test_all<StripedHashMap<long, long>>(
        "StripedHashMap<mutex>(tiny)", true, 7, 3);   /* long chains */
    test_all<StripedHashMap<long, long, std::shared_mutex>>(
        "StripedHashMap<shared_mutex>", true, 1 << 16, 64);
#if HAVE_LOCKS
    test_all<StripedHashMap<long, long, TTASLock>>(
        "StripedHashMap<TTAS>", true, 1 << 16, 64);
    test_all<StripedHashMap<long, long, ParkingLock>>(
        "StripedHashMap<Parking>", true, 1 << 16, 64);
#endif
#if HAVE_RW
    test_all<StripedHashMap<long, long, RWLock>>(
        "StripedHashMap<RW>", true, 1 << 16, 64);
    test_all<StripedHashMap<long, long, RWLockWP, false>>(
        "StripedHashMap<RWWP,nopad>", true, 1 << 16, 64);
#endif
#endif

    if (failures) { std::printf("%d FAILURES\n", failures); return 1; }
    std::printf("all checks passed\n");
    return 0;
}
