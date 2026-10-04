// hash_map.h -- Lab 1: Part 7.  YOU WRITE THIS FILE.
//
// What the harness and tests expect from this header:
//
//   template <typename K, typename V,
//             class Lock = std::mutex, bool Padded = true>
//       requires BasicLock<Lock>
//   class StripedHashMap;
//       explicit StripedHashMap(std::size_t nbuckets,
//                               std::size_t nstripes);
//       std::size_t bucket_count() const;
//       std::size_t stripe_count() const;
//
// satisfying ConcurrentMap<M, K, V> from interface.h.  The bucket
// count is fixed at construction: there is no resizing.  The tests
// construct one with 7 buckets and 3 stripes and fill it with
// thousands of keys, so long chains must work, just slowly.
//
// Flip HAVE_HASHED in parts.h when it compiles.

#ifndef HASH_MAP_H
#define HASH_MAP_H

#include <cstddef>
#include <functional>
#include <mutex>
#include <vector>

#include "interface.h"

#endif /* HASH_MAP_H */
