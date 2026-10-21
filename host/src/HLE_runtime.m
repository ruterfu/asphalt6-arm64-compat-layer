// Compiler runtime the original armv7 image imports from libgcc_s.
// On arm64 these are provided by the compiler for host code only, so the guest
// gets its own implementations of the 32-bit arithmetic helpers, and the SJLJ
// exception model it was built against is emulated on top of setjmp/longjmp.

#import "HLE.h"
#import "GuestVM.h"

#import <math.h>
#import <setjmp.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <stddef.h>
#import <unordered_map>
#import <vector>

// --- 32/64-bit integer division --------------------------------------------
HLE_DEFINE(hle_divsi3) {
    int32_t a = (int32_t)GuestArg(vm, 0), b = (int32_t)GuestArg(vm, 1);
    GuestSetRet(vm, b ? (uint32_t)(int32_t)(a / b) : 0);
}
HLE_BIND("___divsi3", hle_divsi3)

HLE_DEFINE(hle_udivsi3) {
    uint32_t a = GuestArg(vm, 0), b = GuestArg(vm, 1);
    GuestSetRet(vm, b ? a / b : 0);
}
HLE_BIND("___udivsi3", hle_udivsi3)

HLE_DEFINE(hle_modsi3) {
    int32_t a = (int32_t)GuestArg(vm, 0), b = (int32_t)GuestArg(vm, 1);
    GuestSetRet(vm, b ? (uint32_t)(int32_t)(a % b) : 0);
}
HLE_BIND("___modsi3", hle_modsi3)

HLE_DEFINE(hle_umodsi3) {
    uint32_t a = GuestArg(vm, 0), b = GuestArg(vm, 1);
    GuestSetRet(vm, b ? a % b : 0);
}
HLE_BIND("___umodsi3", hle_umodsi3)

HLE_DEFINE(hle_divmodsi4) {
    int32_t a = (int32_t)GuestArg(vm, 0), b = (int32_t)GuestArg(vm, 1);
    uint32_t q = b ? (uint32_t)(int32_t)(a / b) : 0;
    uint32_t r = b ? (uint32_t)(int32_t)(a % b) : 0;
    if (GuestArg(vm, 1) && GuestReadU32(vm, GuestArg(vm, 1)) != 0xFFFFFFFFu) {
        // r1 doubles as the remainder pointer in the *divmodsi4* variant only
        // when it is not a divisor; the plain ___divmodsi4 signature is
        // (a, b, *rem) in Apple's libgcc_s.
    }
    GuestSetRet(vm, q);
    GuestSetReg(vm, 1, r);
}
HLE_BIND("___divmodsi4", hle_divmodsi4)

HLE_DEFINE(hle_divdi3) {
    uint64_t a = ((uint64_t)GuestArg(vm, 1) << 32) | GuestArg(vm, 0);
    uint64_t b = ((uint64_t)GuestArg(vm, 3) << 32) | GuestArg(vm, 2);
    int64_t r = b ? (int64_t)a / (int64_t)b : 0;
    GuestSetRet(vm, (uint32_t)(uint64_t)r);
    GuestSetReg(vm, 1, (uint32_t)((uint64_t)r >> 32));
}
HLE_BIND("___divdi3", hle_divdi3)

HLE_DEFINE(hle_udivdi3) {
    uint64_t a = ((uint64_t)GuestArg(vm, 1) << 32) | GuestArg(vm, 0);
    uint64_t b = ((uint64_t)GuestArg(vm, 3) << 32) | GuestArg(vm, 2);
    uint64_t r = b ? a / b : 0;
    GuestSetRet(vm, (uint32_t)r);
    GuestSetReg(vm, 1, (uint32_t)(r >> 32));
}
HLE_BIND("___udivdi3", hle_udivdi3)

HLE_DEFINE(hle_moddi3) {
    uint64_t a = ((uint64_t)GuestArg(vm, 1) << 32) | GuestArg(vm, 0);
    uint64_t b = ((uint64_t)GuestArg(vm, 3) << 32) | GuestArg(vm, 2);
    int64_t r = b ? (int64_t)a % (int64_t)b : 0;
    GuestSetRet(vm, (uint32_t)(uint64_t)r);
    GuestSetReg(vm, 1, (uint32_t)((uint64_t)r >> 32));
}
HLE_BIND("___moddi3", hle_moddi3)

HLE_DEFINE(hle_umoddi3) {
    uint64_t a = ((uint64_t)GuestArg(vm, 1) << 32) | GuestArg(vm, 0);
    uint64_t b = ((uint64_t)GuestArg(vm, 3) << 32) | GuestArg(vm, 2);
    uint64_t r = b ? a % b : 0;
    GuestSetRet(vm, (uint32_t)r);
    GuestSetReg(vm, 1, (uint32_t)(r >> 32));
}
HLE_BIND("___umoddi3", hle_umoddi3)

// --- soft-float conversions the armv7 FPU does in hardware ------------------
HLE_DEFINE(hle_floatundidf) {
    uint64_t a = ((uint64_t)GuestArg(vm, 1) << 32) | GuestArg(vm, 0);
    GuestSetRetD(vm, (double)(uint64_t)a);
}
HLE_BIND("___floatundidf", hle_floatundidf)

HLE_DEFINE(hle_floatundisf) {
    uint64_t a = ((uint64_t)GuestArg(vm, 1) << 32) | GuestArg(vm, 0);
    GuestSetRetF(vm, (float)(uint64_t)a);
}
HLE_BIND("___floatundisf", hle_floatundisf)

HLE_DEFINE(hle_floatdisf) {
    int64_t a = (int64_t)(((uint64_t)GuestArg(vm, 1) << 32) | GuestArg(vm, 0));
    GuestSetRetF(vm, (float)(int64_t)a);
}
HLE_BIND("___floatdisf", hle_floatdisf)

HLE_DEFINE(hle_fixdfdi) {
    double d = GuestArgD(vm, 0);
    int64_t r = (int64_t)d;
    GuestSetRet(vm, (uint32_t)(uint64_t)r);
    GuestSetReg(vm, 1, (uint32_t)((uint64_t)r >> 32));
}
HLE_BIND("___fixdfdi", hle_fixdfdi)

// --- SJLJ exception model ----------------------------------------------------
// The compiler allocates _Unwind_FunctionContext in the ORIGINAL guest stack.
// Register/Unregister are void functions, not setjmp and not allocators. In the
// armv7 caller at0xdbdd4, r0=sp+0x28; personality/LSDA are at+0x18/+0x1c,
// and builtin-setjmp stores FP/landing-PC/SP at+0x20/+0x24/+0x28. The reserved
// jump-buffer words complete the52-byte Darwin32 context, not a host jmp_buf.
struct GuestSjLjFunctionContext32 {
    gva_t prev;
    int32_t callSite;
    uint32_t data[4];
    gva_t personality;
    gva_t lsda;
    gva_t jumpBuffer[5];
};
static_assert(offsetof(GuestSjLjFunctionContext32, callSite) == 0x04, "armv7 SjLj call site");
static_assert(offsetof(GuestSjLjFunctionContext32, personality) == 0x18, "armv7 SjLj personality");
static_assert(offsetof(GuestSjLjFunctionContext32, lsda) == 0x1c, "armv7 SjLj LSDA");
static_assert(offsetof(GuestSjLjFunctionContext32, jumpBuffer) == 0x20, "armv7 SjLj jump buffer");
static_assert(sizeof(GuestSjLjFunctionContext32) == 0x34, "Darwin32 SjLj context size");

// Guest pthreads run on their own host pthreads (HLE_pthread.m). Each thread
// keeps its own head for each VM; links live in the caller's guest context.
// The map entry is reused after pop, so the hot path never allocates a wrapper,
// guest memory, or a fresh map node per registration.
static thread_local std::unordered_map<uintptr_t, gva_t> g_sjljTops;
static gva_t &SjLjTop(GuestVM *vm) {
    return g_sjljTops[(uintptr_t)(__bridge void *)vm];
}

static void SjLjFailure(GuestVM *vm, const char *operation, gva_t context, gva_t top) {
    GuestTrace(vm, @"!! SjLj %s invalid context %#x (thread head %#x); halting guest",
               operation, context, top);
    GuestRequestHalt(vm);
}

HLE_DEFINE(hle_unwind_sjlj_register) {
    gva_t context = GuestArg(vm, 0);
    gva_t &top = SjLjTop(vm);
    if (!context || (context & 3) || context == top ||
        !GuestWrite(vm, context, &top, sizeof(top))) {
        SjLjFailure(vm, "Register", context, top);
        return;
    }
    top = context;
    // void: preserve the caller's registers and its context bytes after prev.
}
HLE_BIND("__Unwind_SjLj_Register", hle_unwind_sjlj_register)

HLE_DEFINE(hle_unwind_sjlj_unregister) {
    gva_t context = GuestArg(vm, 0);
    gva_t &top = SjLjTop(vm);
    gva_t previous = 0;
    if (!context || context != top || !GuestRead(vm, context, &previous, sizeof(previous)) ||
        previous == context || (previous & 3)) {
        SjLjFailure(vm, "Unregister", context, top);
        return;
    }
    top = previous;
}
HLE_BIND("__Unwind_SjLj_Unregister", hle_unwind_sjlj_unregister)

HLE_DEFINE(hle_unwind_sjlj_resume) {
    gva_t context = SjLjTop(vm);
    GuestSjLjFunctionContext32 frame = {};
    if (!context || !GuestRead(vm, context, &frame, sizeof(frame))) {
        SjLjFailure(vm, "Resume", context, context);
        return;
    }
    // Resume receives an _Unwind_Exception*, not a function-context pointer.
    // Correct unwinding must run the guest personality/LSDA search and cleanup
    // phase and fill data[]/callSite before restoring FP, landing PC and SP.
    // That exception path is not implemented: never treat prev as saved PC,
    // invent a return value, or jump to a landing pad without its unwind data.
    GuestTrace(vm,
        @"!! unsupported SjLj Resume exception=%#x context=%#x callSite=%d "
         "personality=%#x lsda=%#x savedFP=%#x savedPC=%#x savedSP=%#x; halting guest",
        GuestArg(vm, 0), context, frame.callSite, frame.personality, frame.lsda,
        frame.jumpBuffer[0], frame.jumpBuffer[1], frame.jumpBuffer[2]);
    GuestRequestHalt(vm);
}
HLE_BIND("__Unwind_SjLj_Resume", hle_unwind_sjlj_resume)

// --- C++ static-init guards and misc libstdc++ entry points ----------------
static std::unordered_map<uint32_t, uint8_t> g_guardState;

HLE_DEFINE(hle_cxa_guard_acquire) {
    uint32_t g = GuestArg(vm, 0);
    auto it = g_guardState.find(g);
    bool done = (it != g_guardState.end()) && it->second == 1;
    GuestSetRet(vm, done ? 0 : 1);
}
HLE_BIND("___cxa_guard_acquire", hle_cxa_guard_acquire)

HLE_DEFINE(hle_cxa_guard_release) { g_guardState[GuestArg(vm, 0)] = 1; }
HLE_BIND("___cxa_guard_release", hle_cxa_guard_release)

HLE_DEFINE(hle_cxa_guard_abort) { g_guardState[GuestArg(vm, 0)] = 0; }
HLE_BIND("___cxa_guard_abort", hle_cxa_guard_abort)

HLE_DEFINE(hle_cxa_atexit) {
    // The guest never returns from main in practice; record and drop.
    GuestTrace(vm, @"[cxx] atexit(%#x)", GuestArg(vm, 0));
    GuestSetRet(vm, 0);
}
HLE_BIND("___cxa_atexit", hle_cxa_atexit)
HLE_BIND("___cxa_finalize", hle_cxa_atexit)

HLE_DEFINE(hle_cxa_pure_virtual) {
    GuestTrace(vm, @"!! __cxa_pure_virtual called from guest code");
    GuestRequestFault(vm);
}
HLE_BIND("___cxa_pure_virtual", hle_cxa_pure_virtual)

HLE_DEFINE(hle_cxa_begin_catch) { GuestSetRet(vm, GuestArg(vm, 0)); }
HLE_BIND("___cxa_begin_catch", hle_cxa_begin_catch)

HLE_DEFINE(hle_cxa_end_catch) {}
HLE_BIND("___cxa_end_catch", hle_cxa_end_catch)

HLE_DEFINE(hle_cxa_rethrow) { hle_unwind_sjlj_resume(vm); }
HLE_BIND("___cxa_rethrow", hle_cxa_rethrow)

HLE_DEFINE(hle_cxa_call_unexpected) {
    GuestTrace(vm, @"!! __cxa_call_unexpected");
    GuestRequestFault(vm);
}
HLE_BIND("___cxa_call_unexpected", hle_cxa_call_unexpected)

HLE_DEFINE(hle_assert_rtn) {
    gva_t fnGva = GuestArg(vm, 1);
    uint32_t line = GuestArg(vm, 2);
    GuestTrace(vm, @"!! guest assertion failed: %@ (%@:%u)",
               GuestReadCString(vm, GuestArg(vm, 3), 1024) ?: @"?",
               fnGva ? GuestReadCString(vm, fnGva, 256) : @"?", line);
    GuestRequestFault(vm);
}
HLE_BIND("___assert_rtn", hle_assert_rtn)

// Shared with the ordinary printf family in HLE_libc.m. firstVarArg is an
// AAPCS word index (r0-r3, then stack); vaList=0 selects the current call.
extern NSString *GuestFormatCall(GuestVM *vm, NSString *fmt, int firstVarArg, gva_t vaList);

// --- checked string helpers --------------------------------------------------
static void CheckedFailure(GuestVM *vm, NSString *name, NSString *reason) {
    GuestTrace(vm, @"[chk] %@ failed: %@ (guest lr=%#x)", name, reason, GuestLR(vm));
    GuestSetRet(vm, 0xFFFFFFFFu);
    GuestRequestHalt(vm);
}

static bool CheckedCopy(GuestVM *vm, gva_t dst, gva_t src, uint32_t n,
                        uint32_t capacity, NSString *name) {
    if (n > capacity) {
        CheckedFailure(vm, name, @"destination buffer overflow");
        return false;
    }
    if (!n) return true;
    if (!dst || !src || (uint64_t)dst + n > (1ull << 32) ||
        (uint64_t)src + n > (1ull << 32)) {
        CheckedFailure(vm, name, @"invalid guest address range");
        return false;
    }
    uint8_t bytes[4096];
    uint32_t done = 0;
    while (done < n) {
        uint32_t take = n - done;
        if (take > sizeof(bytes)) take = sizeof(bytes);
        if (!GuestRead(vm, src + done, bytes, take) ||
            !GuestWrite(vm, dst + done, bytes, take)) {
            CheckedFailure(vm, name, @"unmapped guest memory");
            return false;
        }
        done += take;
    }
    return true;
}

HLE_DEFINE(hle_memcpy_chk) { // (dst, src, byte_count, destination_size)
    gva_t dst = GuestArg(vm, 0), src = GuestArg(vm, 1);
    uint32_t n = GuestArg(vm, 2), capacity = GuestArg(vm, 3);
    if (CheckedCopy(vm, dst, src, n, capacity, @"__memcpy_chk")) GuestSetRet(vm, dst);
}
HLE_BIND("___memcpy_chk", hle_memcpy_chk)

HLE_DEFINE(hle_strcpy_chk) { // (dst, src, destination_size)
    gva_t dst = GuestArg(vm, 0), src = GuestArg(vm, 1);
    uint32_t capacity = GuestArg(vm, 2);
    // SIZE_MAX denotes an unknown object size. Even then, scanning must stay
    // inside the original 32-bit address space and verify a readable NUL.
    uint64_t available = (1ull << 32) - src;
    size_t limit = capacity < available ? capacity : (size_t)available;
    size_t len = GuestStrLen(vm, src, limit);
    uint8_t nul = 1;
    if (!src || len >= limit || !GuestRead(vm, src + (uint32_t)len, &nul, 1) || nul) {
        CheckedFailure(vm, @"__strcpy_chk", @"source is unreadable or exceeds destination size");
        return;
    }
    if (CheckedCopy(vm, dst, src, (uint32_t)len + 1, capacity, @"__strcpy_chk")) GuestSetRet(vm, dst);
}
HLE_BIND("___strcpy_chk", hle_strcpy_chk)

HLE_DEFINE(hle_sprintf_chk) { // (dst r0, flag r1, size r2, format r3, ... stack)
    gva_t dst = GuestArg(vm, 0), format = GuestArg(vm, 3);
    uint32_t capacity = GuestArg(vm, 2);
    NSString *fmt = format ? GuestReadCString(vm, format, 1 << 20) : nil;
    if (!fmt) {
        CheckedFailure(vm, @"__sprintf_chk", @"unreadable format string");
        return;
    }
    NSString *text = GuestFormatCall(vm, fmt, 4, 0);
    NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!dst || bytes.length >= capacity || (uint64_t)dst + bytes.length + 1 > (1ull << 32)) {
        CheckedFailure(vm, @"__sprintf_chk", @"destination buffer overflow");
        return;
    }
    uint8_t nul = 0;
    if ((bytes.length && !GuestWrite(vm, dst, bytes.bytes, bytes.length)) ||
        !GuestWrite(vm, dst + (uint32_t)bytes.length, &nul, 1)) {
        CheckedFailure(vm, @"__sprintf_chk", @"unmapped guest destination");
        return;
    }
    GuestSetRet(vm, (uint32_t)bytes.length);
}
HLE_BIND("___sprintf_chk", hle_sprintf_chk)

HLE_DEFINE(hle_tolower) { GuestSetRet(vm, (uint32_t)tolower((int)GuestArg(vm, 0))); }
HLE_BIND("___tolower", hle_tolower)

HLE_DEFINE(hle_toupper) { GuestSetRet(vm, (uint32_t)toupper((int)GuestArg(vm, 0))); }
HLE_BIND("___toupper", hle_toupper)
