/* Independent integer support for the isolated ARM floating-point candidate.
 * This file is original candidate code; retained SoftFloat files keep their
 * own notices and licenses. No CPU, decoder, GLib, or QEMU runtime dependency.
 */
#ifndef AS6_MATH_SUPPORT_H
#define AS6_MATH_SUPPORT_H
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <float.h>
#include <limits.h>
#if !defined(TARGET_ARM) || TARGET_ARM != 1
#error ARM source floating-point semantics must be selected explicitly
#endif
#if !defined(__aarch64__) || !defined(__clang__)
#error This candidate is validated only with Clang targeting AArch64
#endif
#define QEMU_FLATTEN
#define likely(value) __builtin_expect(!!(value), 1)
#define unlikely(value) __builtin_expect(!!(value), 0)
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))
_Noreturn void as6_math_fatal(const char *source, unsigned line);
#define g_assert_not_reached() as6_math_fatal(__FILE__, __LINE__)
static inline int clz32(uint32_t value) { return value ? __builtin_clz(value) : 32; }
static inline int clz64(uint64_t value) { return value ? __builtin_clzll(value) : 64; }
static inline uint64_t extract64(uint64_t value, unsigned start, unsigned length) {
    assert(length && length <= 64 && start <= 64 - length);
    return length == 64 ? value : (value >> start) & ((UINT64_C(1) << length) - 1);
}
static inline uint64_t deposit64(uint64_t value, unsigned start, unsigned length, uint64_t field) {
    assert(length && length <= 64 && start <= 64 - length);
    if (length == 64) return field;
    uint64_t mask = ((UINT64_C(1) << length) - 1) << start;
    return (value & ~mask) | ((field << start) & mask);
}
#endif
