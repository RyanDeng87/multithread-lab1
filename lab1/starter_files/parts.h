// parts.h -- which parts of the lab are implemented.
//
// The harness and the tests compile only the parts switched on here,
// so you can build and measure Part 1 before Part 7 exists.  Flip a
// switch to 1 when the corresponding header compiles; the tests for
// that part start running on the next `make test`.
//
// The graded submission has every switch at 1.

#ifndef LAB1_PARTS_H
#define LAB1_PARTS_H

#define HAVE_SHARDED 0      // Part 4: ShardedMap   (concurrent_map.h)
#define HAVE_LOCKS   0      // Part 5: TAS/TTAS/Ticket/Park (locks.h)
#define HAVE_RW      0      // Part 6: RWLock, RWLockWP         (locks.h)
#define HAVE_HASHED  0      // Part 7: StripedHashMap        (hash_map.h)

#endif /* LAB1_PARTS_H */
