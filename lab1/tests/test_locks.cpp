// test_locks.cpp -- correctness checks for the locks in locks.h.
//
//   make test        plain build
//   make tsan        under ThreadSanitizer  <-- the one that matters
//
// A lock that passes the plain build and fails under TSan is a lock
// with the wrong memory ordering.  The report asks what that means.
//
// Which locks are tested is controlled by parts.h.

#include <atomic>
#include <chrono>
#include <cstdio>
#include <mutex>
#include <shared_mutex>
#include <thread>
#include <vector>

#include "parts.h"
#include "interface.h"
#if HAVE_LOCKS || HAVE_RW
#include "locks.h"
#endif

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { ++failures; \
    std::printf("  FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } \
    } while (0)

#ifdef __SANITIZE_THREAD__
static constexpr int SCALE = 4;
#else
static constexpr int SCALE = 1;
#endif

/* Local spin hint so this file compiles even before locks.h exists. */
inline void cpu_relax_test() {
#if defined(__x86_64__) || defined(__i386__)
    __builtin_ia32_pause();
#endif
}

/* T threads each add ITERS to a plain long under the lock.  Two
   witnesses: the final count, and an "inside" counter that must
   never exceed 1 while held.  T > core count on purpose: a spinlock
   has to survive its holder being descheduled. */
template <class Lock>
static void test_mutual_exclusion(const char* name, int T, int iters)
{
    static_assert(BasicLock<Lock>);
    auto t0 = std::chrono::steady_clock::now();
    Lock lk;
    long counter = 0;               /* plain: the lock protects it */
    int  inside  = 0;
    std::atomic<int> violations{0};
    {
        std::vector<std::jthread> workers;
        for (int t = 0; t < T; ++t)
            workers.emplace_back([&] {
                for (int i = 0; i < iters; ++i) {
                    std::lock_guard g(lk);
                    if (++inside != 1) violations.fetch_add(1);
                    ++counter;
                    --inside;
                }
            });
    }
    CHECK(counter == (long)T * iters);
    CHECK(violations.load() == 0);
    std::printf("%s: %d threads x %d, mutual exclusion  %.1f s\n", name,
                T, iters, std::chrono::duration<double>(
                    std::chrono::steady_clock::now() - t0).count());
}

/* Readers may overlap; a writer may overlap nothing.  The writer
   keeps two plain ints equal; readers check the invariant under a
   shared lock.  A broken writer path lets a reader see them differ;
   a broken reader path shows up under TSan as a race on a/b. */
template <class Lock>
static void test_rw(const char* name)
{
    static_assert(SharedLock<Lock>);
    std::printf("%s: 6 readers + 2 writers, exclusion and sharing\n",
                name);
    Lock lk;
    long a = 0, b = 0;
    std::atomic<int>  readers_in{0}, peak{0}, torn{0};
    std::atomic<bool> stop{false};
    {
        std::vector<std::jthread> workers;
        for (int w = 0; w < 2; ++w)
            workers.emplace_back([&] {
                for (int i = 0; i < 5000 / SCALE; ++i) {
                    std::lock_guard g(lk);
                    ++a;
                    ++b;
                }
            });
        for (int r = 0; r < 6; ++r)
            workers.emplace_back([&] {
                while (!stop.load()) {
                    std::shared_lock g(lk);
                    int n = readers_in.fetch_add(1) + 1;
                    int p = peak.load();
                    while (n > p && !peak.compare_exchange_weak(p, n)) { }
                    if (a != b) torn.fetch_add(1);
                    for (int i = 0; i < 20; ++i) cpu_relax_test();
                    readers_in.fetch_sub(1);
                    g.unlock();
                    /* Stay OUT of the lock most of the time.  Six
                       readers that re-acquire the instant they release
                       starve the writers on a reader-preferring lock
                       (std::shared_mutex included), and this test
                       never ends.  That starvation is real and is
                       measured in Part 6; it is not what this test
                       is for. */
                    for (int i = 0; i < 2000; ++i) cpu_relax_test();
                }
            });
        workers[0].join();
        workers[1].join();
        stop.store(true);
    }
    CHECK(a == 10000 / SCALE && b == 10000 / SCALE);
    CHECK(torn.load() == 0);
    /* Sharing is a liveness property, so this is advisory: on a
       one-core box readers may never overlap. */
    if (peak.load() < 2)
        std::printf("  note: readers never overlapped (peak=%d); "
                    "expected on a 1-2 core machine only\n", peak.load());
}

int main(void)
{
    const int ITERS = 20000 / SCALE;
    test_mutual_exclusion<std::mutex>("std::mutex", 8, ITERS);
    test_rw<std::shared_mutex>("std::shared_mutex");
#if HAVE_LOCKS
    test_mutual_exclusion<TASLock>("TASLock", 8, ITERS);
    test_mutual_exclusion<TTASLock>("TTASLock", 8, ITERS);
    test_mutual_exclusion<TicketLock>("TicketLock", 8, ITERS);
    test_mutual_exclusion<ParkingLock>("ParkingLock", 8, ITERS);
    /* oversubscribed: more threads than any machine has cores */
    test_mutual_exclusion<TASLock>("TASLock", 64, ITERS / 20);
    test_mutual_exclusion<TTASLock>("TTASLock", 64, ITERS / 20);
    test_mutual_exclusion<TicketLock>("TicketLock", 64, ITERS / 20);
    test_mutual_exclusion<ParkingLock>("ParkingLock", 64, ITERS / 20);
#else
    std::printf("(Part 5 locks not enabled in parts.h)\n");
#endif
#if HAVE_RW
    test_mutual_exclusion<RWLock>("RWLock (exclusive)", 8, ITERS);
    test_mutual_exclusion<RWLockWP>("RWLockWP (exclusive)", 8, ITERS);
    test_rw<RWLock>("RWLock");
    test_rw<RWLockWP>("RWLockWP");
#else
    std::printf("(Part 6 locks not enabled in parts.h)\n");
#endif

    if (failures) { std::printf("%d FAILURES\n", failures); return 1; }
    std::printf("all checks passed\n");
    return 0;
}
