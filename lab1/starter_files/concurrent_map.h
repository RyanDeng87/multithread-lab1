// concurrent_map.h -- Lab 1: Part 1 and Part 4.
// Generated with assistance of claude code.
//
//   template <typename K, typename V>
//   class CoarseMap;                               // Part 1
//
//   template <typename K, typename V,
//             class Lock = std::mutex, bool Padded = true>
//       requires BasicLock<Lock>
//   class ShardedMap;                              // Part 4
//
// Both satisfy ConcurrentMap<M, K, V> from interface.h.  Values come
// out as copies, never references or iterators into the container: a
// reference would outlive the guard that made reading it safe.

#ifndef CONCURRENT_MAP_H
#define CONCURRENT_MAP_H

#include <algorithm>
#include <cstddef>
#include <functional>
#include <map>
#include <mutex>
#include <vector>

#include "interface.h"

/* ---- Part 1: one std::map behind one std::mutex ------------------------

   mu_ protects every byte of map_: the tree nodes, the header that
   holds the root and leftmost pointers, and the element count that
   size() reads.  Every member function takes mu_ before touching map_;
   nothing else does. */
template <typename K, typename V>
class CoarseMap {
public:
    /* true if key was new; an existing key's value is overwritten */
    bool insert(const K& key, const V& value)
    {
        std::lock_guard<std::mutex> g(mu_);
        return map_.insert_or_assign(key, value).second;
    }

    /* copies the value out while the lock is still held */
    bool find(const K& key, V& out) const
    {
        std::lock_guard<std::mutex> g(mu_);
        auto it = map_.find(key);
        if (it == map_.end()) return false;
        out = it->second;
        return true;
    }

    bool erase(const K& key)
    {
        std::lock_guard<std::mutex> g(mu_);
        return map_.erase(key) != 0;
    }

    /* map_.size() reads a count that insert and erase write: without
       the lock that read is a data race. */
    std::size_t size() const
    {
        std::lock_guard<std::mutex> g(mu_);
        return map_.size();
    }

private:
    /* alignas: bench builds the map on the stack, which would put the
       mutex at a different offset in its cache line on every run.  With
       it (libstdc++, x86-64) the layout is fixed: line 0 holds the mutex
       (bytes 0-39) and the map's root pointer (56); line 1 holds the
       leftmost/rightmost pointers and the node count (64-87).  Every op
       moves line 0; an insert of a new key or an erase also reads and
       writes line 1. */
    alignas(CACHE_LINE) mutable std::mutex mu_;  // mutable: find, size const
    std::map<K, V> map_;
};

/* ---- Part 4: N std::maps, each behind its own lock --------------------

   A key lives in shard std::hash<K>{}(key) % N, and shard i's lock
   protects shard i's map and nothing else.  insert, erase and find
   each lock exactly one shard; size() locks all of them. */
template <typename K, typename V, class Lock = std::mutex,
          bool Padded = true>
    requires BasicLock<Lock>
class ShardedMap {
public:
    explicit ShardedMap(std::size_t nshards)
        : shards_(nshards ? nshards : 1) {}

    std::size_t shard_count() const { return shards_.size(); }

    bool insert(const K& key, const V& value)
    {
        Shard& s = shard_for(key);
        std::lock_guard<Lock> g(s.lock);
        return s.map.insert_or_assign(key, value).second;
    }

    /* shared mode when Lock has one (Part 6), exclusive otherwise */
    bool find(const K& key, V& out) const
    {
        const Shard& s = shard_for(key);
        ReadGuard<Lock> g(s.lock);
        auto it = s.map.find(key);
        if (it == s.map.end()) return false;
        out = it->second;
        return true;
    }

    bool erase(const K& key)
    {
        Shard& s = shard_for(key);
        std::lock_guard<Lock> g(s.lock);
        return s.map.erase(key) != 0;
    }

    /* Exact: every shard's lock is held at once, so the sum is the
       size at one instant.  Locks are taken in index order, the one
       global order every multi-lock holder follows, so two size()
       callers cannot each hold a lock the other is waiting for; insert,
       erase and find hold only one lock and never wait while holding. */
    std::size_t size() const
    {
        const std::size_t n = shards_.size();
        for (std::size_t i = 0; i < n; ++i) shards_[i].lock.lock();
        std::size_t total = 0;
        for (std::size_t i = 0; i < n; ++i) total += shards_[i].map.size();
        for (std::size_t i = n; i-- > 0; ) shards_[i].lock.unlock();
        return total;
    }

private:
    /* Padded: the lock and the map header each start their own cache
       line, so a shard fills whole lines, no two shards share a line, and
       threads waiting on a shard's lock do not fight its holder for the
       map's root pointer and node count.  Packed: natural alignment,
       shards back to back, so one shard's lock can share a line with its
       neighbour's map header. */
    static constexpr std::size_t kAlign =
        Padded ? CACHE_LINE
               : std::max(alignof(Lock), alignof(std::map<K, V>));

    struct alignas(kAlign) Shard {
        mutable Lock lock;                            // find, size are const
        alignas(kAlign) std::map<K, V> map;
    };
    static_assert(!Padded || sizeof(Shard) % CACHE_LINE == 0,
                  "a padded shard must occupy whole cache lines");

    Shard& shard_for(const K& key)
    {
        return shards_[std::hash<K>{}(key) % shards_.size()];
    }
    const Shard& shard_for(const K& key) const
    {
        return shards_[std::hash<K>{}(key) % shards_.size()];
    }

    std::vector<Shard> shards_;  // never resized: Shard is not movable
};

#endif /* CONCURRENT_MAP_H */
