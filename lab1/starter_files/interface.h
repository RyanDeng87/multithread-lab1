// interface.h -- Lab 1: the contracts your types must satisfy.
// PROVIDED.  Do not modify.
//
// The harness and the tests are written against these concepts, not
// against your class definitions, so anything that satisfies them
// plugs in.  If your type does not satisfy one, the static_assert
// in the tests names the concept; the compiler's note under it names
// the missing member.

#ifndef LAB1_INTERFACE_H
#define LAB1_INTERFACE_H

#include <concepts>
#include <cstddef>

/* A lock usable with std::lock_guard / std::unique_lock. */
template <class L>
concept BasicLock = requires(L l) {
    l.lock();
    l.unlock();
};

/* A lock that also admits concurrent readers, usable with
   std::shared_lock.  std::shared_mutex is the standard example. */
template <class L>
concept SharedLock = BasicLock<L> && requires(L l) {
    l.lock_shared();
    l.unlock_shared();
};

/* The four operations every map in this lab exposes.  Values come out
   as copies, never as references or iterators into the container. */
template <class M, class K, class V>
concept ConcurrentMap = requires(M m, const M cm, const K& k,
                                 const V& v, V& out) {
    { m.insert(k, v) } -> std::same_as<bool>;   // true if key was new
    { cm.find(k, out) } -> std::same_as<bool>;  // copy; false if absent
    { m.erase(k) }     -> std::same_as<bool>;   // true if it was present
    { cm.size() }      -> std::same_as<std::size_t>;
};

/* ReadGuard<L>: an RAII guard that takes L in SHARED mode when L
   offers one and in exclusive mode otherwise.  Use it in find() so
   the same map code works with std::mutex, your spinlocks, and your
   reader-writer lock.  This is the one piece of template machinery
   the lab hands you; everything else you write. */
template <class L>
class ReadGuard {
public:
    explicit ReadGuard(L& l) : l_(l) {
        if constexpr (SharedLock<L>) l_.lock_shared();
        else                         l_.lock();
    }
    ~ReadGuard() {
        if constexpr (SharedLock<L>) l_.unlock_shared();
        else                         l_.unlock();
    }
    ReadGuard(const ReadGuard&)            = delete;
    ReadGuard& operator=(const ReadGuard&) = delete;

private:
    L& l_;
};

/* Cache line size.  std::hardware_destructive_interference_size is
   the portable spelling, but GCC warns that its value is not
   ABI-stable.  128 on Apple silicon; 64 on every x86 you will use. */
inline constexpr std::size_t CACHE_LINE = 64;

#endif /* LAB1_INTERFACE_H */
