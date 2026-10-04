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
#include <type_traits>

#include "interface.h"

template<typename K, typename V, class Lock = std::mutex, bool Padded = true> requires BasicLock<Lock>
class StripedHashMap {
private:
    struct Node
    {
        K key;
        V value;
        Node* next;

        Node(const K& k, const V&v, Node* n = nullptr) : key(k), value(v), next(n) {}
    };

    // if padded is true, each stripe lock is aligned to a cache line
    // When false the locks are stored normally and may share lines
    struct Stripe {
        Lock lock;
    };

    struct alignas(64) PaddedStripe {
        Lock lock;
    };

    using StripeStorage = std::conditional_t<Padded, PaddedStripe, Stripe>;

public:
    explicit StripedHashMap(std::size_t nbuckets, std::size_t nstripes) : buckets_(nbuckets, nullptr), stripes_(nstripes) {}

    ~StripedHashMap()
    {
        for(Node* head : buckets_)
        {
            while(head != nullptr)
            {
                Node* next = head->next;
                delete head;
                head = next;
            }
        }
    }

    StripedHashMap(const StripedHashMap&) = delete;
    StripedHashMap& operator=(const StripedHashMap&) = delete;

    bool insert(const K& key, const V& value)
    {
        const std::size_t bucket = bucket_index(key);
        const std::size_t stripe = stripe_index(bucket);

        std::lock_guard<Lock> lock(stripes_[stripe].lock);

        Node* current = buckets_[bucket];

        while(current != nullptr)
        {
            if(current->key == key) {
                current->value = value;
                return false;
            }
            current = current->next;
        }

        buckets_[bucket] = new Node(key, value, buckets_[bucket]);
        return true;
    }

    bool find(const K& key, V& out) const
    {
        const std::size_t bucket = bucket_index(key);
        const std::size_t stripe = stripe_index(bucket);

        std::lock_guard<Lock> lock(stripes_[stripe].lock);

        Node* current = buckets_[bucket];

        while(current != nullptr)
        {
            if(current->key == key)
            {
                out = current->value;
                return true;
            }
            current = current->next;
        }
        return false;
    }

    bool erase(const K& key)
    {
        const std::size_t bucket = bucket_index(key);
        const std::size_t stripe = stripe_index(bucket);

        std::lock_guard<Lock> lock(stripes_[stripe].lock);

        Node* current = buckets_[bucket];
        Node* previous = nullptr;

        while(current != nullptr)
        {
            if(current->key == key)
            {
                if(previous == nullptr)
                {
                    buckets_[bucket] = current->next;
                } else{
                    previous->next = current->next;
                }

                delete current;
                return true;
            }
            previous = current;
            current = current->next;
        }
        return false;
    }

    std::size_t size() const
    {
        std::vector<std::unique_lock<Lock>> locks;
        locks.reserve(stripes_.size());

        for(auto& stripe : stripes_) {
            locks.emplace_back(stripe.lock);
        }

        std::size_t count = 0;

        for(Node* head : buckets_)
        {
            for(Node* current = head; current!=nullptr; current = current->next)
            {
                ++count;
            }

        }
        return count;
    }

    std::size_t bucket_count() const
    {
        return buckets_.size();
    }

    std::size_t stripe_count() const
    {
        return stripes_.size();
    }

private:
    std::size_t bucket_index(const K& key) const
    {
        return std::hash<K>{}(key) % buckets_.size();
    }

    std::size_t stripe_index(std::size_t bucket) const
    {
        // Maps contigous ranges of buckets to each stripe
        return (bucket * stripes_.size()) / buckets_.size();
    }

    std::vector<Node*> buckets_;
    mutable std::vector<StripeStorage> stripes_;


};


#endif /* HASH_MAP_H */
