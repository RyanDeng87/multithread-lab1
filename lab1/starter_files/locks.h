// locks.h -- Lab 1: Part 5 and Part 6.
// Generated with assistance of claude code.
//
//   Part 5 (BasicLock):     TASLock  TTASLock  TicketLock  ParkingLock
//   Part 6 (SharedLock):    RWLock   RWLockWP
//
// Every lock is built from std::atomic (ParkingLock also sleeps through
// std::atomic::wait / notify_one, and TicketLock yields its timeslice
// with std::this_thread::yield).  None is copyable or movable; the
// std::atomic members see to that.
//
// Ordering: every unlock() is a release, and every lock() ends in an
// acquire that reads the value that release wrote (directly, or through
// the read-modify-writes that follow it in the release sequence), so
// everything one holder did in its critical section happens-before
// everything the next holder does in its own.  Waiting is done with
// relaxed operations, which only decide WHEN to try; the acquire is paid
// once per lock().  In TTAS, Parking and the two RW locks the winning
// RMW is itself the acquire; TAS and Ticket win with a relaxed operation
// and follow it with one acquire load (see their comments).

#ifndef LOCKS_H
#define LOCKS_H

#include <atomic>
#include <cstdint>
#include <thread>

#include "interface.h"

/* The processor's spin-wait hint.  On x86 PAUSE stalls the spinning
   core (about 140 cycles on Skylake-SP / Cascade Lake, about 10 on
   older cores), so a spin loop issues far fewer loads, frees pipeline
   resources for an SMT sibling, and avoids the memory-order
   mis-speculation flush when the watched line finally changes. */
inline void cpu_relax() noexcept
{
#if defined(__x86_64__) || defined(__i386__)
    __builtin_ia32_pause();
#elif defined(__aarch64__)
    __asm__ __volatile__("yield" ::: "memory");
#endif
}

/* ---- Part 5 ------------------------------------------------------------ */

/* Test-and-set: every attempt is an exchange, a write, so every waiter
   pulls the lock's line into its own cache in M state on every spin.

   The exchange in the loop is relaxed; the acquire is the load after
   it.  That load reads the value written by our winning exchange or by
   a later waiter's failed exchange.  No plain store can come between,
   because only the holder (us) unlocks, so every one of those writes is
   a read-modify-write in the release sequence headed by the previous
   holder's release store, and that store synchronizes with our acquire
   load just as it would with an acquire exchange.  On x86 the code is
   the same XCHG either way.  Spinning with relaxed operations keeps the
   waiters out of ThreadSanitizer's per-address lock, which the
   releasing thread needs: spinning with acquire exchanges starves the
   unlock under TSan, and the 64-thread test never finishes. */
class TASLock {
public:
    void lock() noexcept
    {
        while (held_.exchange(true, std::memory_order_relaxed)) { }
        (void)held_.load(std::memory_order_acquire);
    }
    void unlock() noexcept { held_.store(false, std::memory_order_release); }

private:
    std::atomic<bool> held_{false};
};

/* Test-and-test-and-set with exponential backoff: waiters read the
   line (S state, shared, no traffic while it stays unchanged) and only
   write it with an exchange when it looks free.  After a lost race a
   waiter backs off for a doubling number of pauses, up to a cap, so
   the waiters that saw the same release do not all retry at once.
   4..128 pauses is about 560 cycles to 18k cycles (~6 us) on CLX: the
   cap is a few critical sections long, not hundreds. */
class TTASLock {
public:
    void lock() noexcept
    {
        unsigned backoff = kMinBackoff;
        for (;;) {
            while (held_.load(std::memory_order_relaxed)) cpu_relax();
            if (!held_.exchange(true, std::memory_order_acquire)) return;
            for (unsigned i = 0; i < backoff; ++i) cpu_relax();
            if (backoff < kMaxBackoff) backoff *= 2;
        }
    }
    void unlock() noexcept { held_.store(false, std::memory_order_release); }

private:
    static constexpr unsigned kMinBackoff = 4;
    static constexpr unsigned kMaxBackoff = 128;
    std::atomic<bool> held_{false};
};

/* FIFO: take a ticket, wait for it to be served.  Only the holder
   writes serving_, so unlock() is a plain load and a release store.
   Because the lock is handed to one specific waiter, a waiter that has
   been descheduled stalls everyone queued behind it; after a bounded
   number of spins a waiter yields so the waiter whose turn it is can
   get a CPU.  128 spins is about 18k cycles (~6 us) on CLX.  The spin
   loads are relaxed, for the same TSan reason as TASLock; once the
   ticket comes up, one acquire load reads the previous holder's
   release store (nothing else writes serving_ until we unlock). */
class TicketLock {
public:
    void lock() noexcept
    {
        const std::uint32_t me =
            next_.fetch_add(1, std::memory_order_relaxed);
        unsigned spins = 0;
        while (serving_.load(std::memory_order_relaxed) != me) {
            if (spins < kSpinsBeforeYield) { ++spins; cpu_relax(); }
            else                           std::this_thread::yield();
        }
        (void)serving_.load(std::memory_order_acquire);
    }
    void unlock() noexcept
    {
        serving_.store(serving_.load(std::memory_order_relaxed) + 1,
                       std::memory_order_release);
    }

private:
    static constexpr unsigned kSpinsBeforeYield = 128;
    std::atomic<std::uint32_t> next_{0};     // next ticket to hand out
    std::atomic<std::uint32_t> serving_{0};  // ticket that holds the lock
};

/* Spin briefly, then sleep: the three-state lock word of Drepper's
   "Futexes Are Tricky" (mutex 3), with the README's exchange-based
   unlock.  100 spins is about 14k cycles (~5 us) on CLX.
   state_: 0 free, 1 held with no waiters, 2 held and maybe sleepers.
   A waiter that gives up spinning swaps in 2 before it sleeps, and a
   woken waiter re-acquires with exchange(2), never with CAS(0 -> 1):
   it cannot know it was the only sleeper, so the lock must stay marked
   2 and the next unlock must notify. */
class ParkingLock {
public:
    void lock() noexcept
    {
        int c = 0;
        if (state_.compare_exchange_strong(c, 1, std::memory_order_acquire,
                                           std::memory_order_relaxed))
            return;                                   // fast path: 0 -> 1
        for (unsigned i = 0; i < kSpins; ++i) {       // bounded spin
            cpu_relax();
            c = 0;
            if (state_.load(std::memory_order_relaxed) == 0 &&
                state_.compare_exchange_strong(c, 1,
                                               std::memory_order_acquire,
                                               std::memory_order_relaxed))
                return;
        }
        c = state_.exchange(2, std::memory_order_acquire);
        while (c != 0) {                              // sleep while held
            state_.wait(2, std::memory_order_relaxed);
            c = state_.exchange(2, std::memory_order_acquire);
        }
    }
    void unlock() noexcept
    {
        if (state_.exchange(0, std::memory_order_release) == 2)
            state_.notify_one();
    }

private:
    static constexpr unsigned kSpins = 100;
    std::atomic<int> state_{0};
};

/* ---- Part 6 ------------------------------------------------------------ */

/* Reader-preferring reader-writer spinlock.  state_: -1 a writer holds
   it; n >= 0, n readers hold it.  A reader enters with CAS n -> n+1
   (n >= 0) and leaves with fetch_sub; a writer enters with CAS 0 -> -1
   and leaves with a store of 0.  Readers' fetch_subs are release RMWs,
   so the writer's acquire CAS, reading the 0 the last reader left,
   synchronizes with every reader that was inside. */
class RWLock {
public:
    void lock_shared() noexcept
    {
        int n = state_.load(std::memory_order_relaxed);
        for (;;) {
            if (n >= 0) {
                if (state_.compare_exchange_weak(n, n + 1,
                                                 std::memory_order_acquire,
                                                 std::memory_order_relaxed))
                    return;                 // a failed CAS reloads n
            } else {
                cpu_relax();
                n = state_.load(std::memory_order_relaxed);
            }
        }
    }
    void unlock_shared() noexcept
    {
        state_.fetch_sub(1, std::memory_order_release);
    }
    void lock() noexcept
    {
        for (;;) {
            int expected = 0;
            if (state_.load(std::memory_order_relaxed) == 0 &&
                state_.compare_exchange_weak(expected, -1,
                                             std::memory_order_acquire,
                                             std::memory_order_relaxed))
                return;
            cpu_relax();
        }
    }
    void unlock() noexcept { state_.store(0, std::memory_order_release); }

private:
    std::atomic<int> state_{0};
};

/* Writer-preferring: the same word, plus a count of writers waiting.
   Readers check the count before they try to enter, so once a writer is
   waiting no new reader attempt starts; a reader already past the check
   can still get in once (the check and the CAS are separate steps).  A
   writer therefore waits only for the readers already in flight, not
   for an unbounded stream; the price is that a stream of writers can
   keep the readers out instead.  waiting_ is only a hint (relaxed):
   who gets in is decided by state_ alone. */
class RWLockWP {
public:
    void lock_shared() noexcept
    {
        for (;;) {
            while (waiting_.load(std::memory_order_relaxed) != 0) cpu_relax();
            int n = state_.load(std::memory_order_relaxed);
            if (n >= 0 &&
                state_.compare_exchange_weak(n, n + 1,
                                             std::memory_order_acquire,
                                             std::memory_order_relaxed))
                return;
            cpu_relax();
        }
    }
    void unlock_shared() noexcept
    {
        state_.fetch_sub(1, std::memory_order_release);
    }
    void lock() noexcept
    {
        waiting_.fetch_add(1, std::memory_order_relaxed);
        for (;;) {
            int expected = 0;
            if (state_.load(std::memory_order_relaxed) == 0 &&
                state_.compare_exchange_weak(expected, -1,
                                             std::memory_order_acquire,
                                             std::memory_order_relaxed))
                break;
            cpu_relax();
        }
        waiting_.fetch_sub(1, std::memory_order_relaxed);
    }
    void unlock() noexcept { state_.store(0, std::memory_order_release); }

private:
    std::atomic<int> state_{0};     // -1 writer, n >= 0 readers
    std::atomic<int> waiting_{0};   // writers in lock(), not yet returned
};

#endif /* LOCKS_H */
