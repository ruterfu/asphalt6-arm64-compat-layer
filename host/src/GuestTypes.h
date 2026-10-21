#ifndef PORT_GUEST_TYPES_H
#define PORT_GUEST_TYPES_H

#include <stdint.h>
#include <stddef.h>

// Original 32-bit data layouts and code identities survive offline translation.
// Execution uses linked ARM64 functions; no original code image is loaded.
typedef uint32_t gva_t;

#define GUEST_PAGEZERO_ADDR   0x00000000u
#define GUEST_PAGEZERO_SIZE   0x00001000u
#define GUEST_HLE_BASE        0x10000000u   // reserved original bridge identities
#define GUEST_HLE_SIZE        0x00100000u
#define GUEST_HEAP_BASE       0x20000000u
#define GUEST_HEAP_SIZE       0x04000000u
#define GUEST_MMAP_BASE       0x28000000u
#define GUEST_MMAP_SIZE       0x08000000u
#define GUEST_STACK_TOP       0x3FFF0000u
#define GUEST_STACK_SIZE      0x00800000u
#define GUEST_TLS_BASE        0x40000000u

#endif  // PORT_GUEST_TYPES_H
