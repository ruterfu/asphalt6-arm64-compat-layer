// The 2011 build links against Apple's armv7 libstdc++, which still used the
// copy-on-write std::string (_Rep) ABI. That library does not exist on arm64,
// so the guest gets a faithful re-implementation of the 92 symbols it imports.
// All string objects live in *guest* memory, so the game's own C++ code keeps
// manipulating them exactly as before.

#import "HLE.h"
#import "GuestVM.h"

#import <stdlib.h>
#import <string.h>
#import <vector>
#import <string>
#import <unordered_map>
#include <algorithm>
#include <cstdio>
#include <utility>
#import <objc/runtime.h>

// --- COW _Rep layout (32-bit GCC) -------------------------------------------
//   +0  size_type _M_length
//   +4  size_type _M_capacity
//   +8  _Atomic_word _M_refcount
//   +12 char data[]
#define REP_HDR 12u
#define NPOS 0xFFFFFFFFu

// A std::string stores the address of data[], not the address of _Rep.
// The game's inlined methods load length/capacity/refcount at data -12/-8/-4.
static gva_t EmptyRep(GuestVM *vm);

static void AllocationFailure(GuestVM *vm, const char *operation, uint32_t size,
                              bool lengthError=false) {
    GuestTrace(vm, @"[cxx] %s(%u): %s cannot unwind through the compatibility bridge; halting guest",
               operation, size, lengthError ? "std::length_error" : "std::bad_alloc");
    GuestRequestFault(vm);
}
static void StringMemoryFailure(GuestVM *vm, const char *operation, gva_t address) {
    GuestTrace(vm, @"[cxx] %s failed at guest string address %#x; halting guest", operation, address);
    GuestRequestFault(vm);
}

static gva_t StringRep(GuestVM *vm, gva_t self) {
    gva_t data = GuestReadU32(vm, self);
    return data ? data - REP_HDR : 0;
}

static gva_t RepCreate(GuestVM *vm, uint32_t capacity) {
    if (capacity > 0x3FFFFFFFu - REP_HDR - 1) {
        AllocationFailure(vm, "std::string::_Rep::_S_create", capacity, true);
        return 0;
    }
    gva_t rep = GuestHeapAlloc(vm, REP_HDR + capacity + 1);
    if (!rep) { AllocationFailure(vm, "std::string::_Rep::_S_create", capacity); return 0; }
    uint32_t header[3] = {0, capacity, 0};
    uint8_t nul = 0;
    if (!GuestWrite(vm, rep, header, sizeof(header)) ||
        !GuestWrite(vm, rep + REP_HDR, &nul, 1)) {
        GuestHeapFree(vm, rep);
        StringMemoryFailure(vm, "string rep initialization", rep);
        return 0;
    }
    return rep;
}

static gva_t RepClone(GuestVM *vm, gva_t old, uint32_t capacity) {
    uint32_t len = 0;
    if (old && !GuestRead(vm, old, &len, sizeof(len))) {
        StringMemoryFailure(vm, "string clone length", old);
        return 0;
    }
    if (capacity < len) capacity = len;
    gva_t rep = RepCreate(vm, capacity);
    if (!rep) return 0;
    if (len) {
        std::vector<uint8_t> buf(len);
        if (!GuestRead(vm, old + REP_HDR, buf.data(), len) ||
            !GuestWrite(vm, rep + REP_HDR, buf.data(), len)) {
            GuestHeapFree(vm, rep);
            StringMemoryFailure(vm, "string clone copy", old);
            return 0;
        }
    }
    uint8_t nul = 0;
    if (!GuestWrite(vm, rep, &len, sizeof(len)) ||
        !GuestWrite(vm, rep + REP_HDR + len, &nul, 1)) {
        GuestHeapFree(vm, rep);
        StringMemoryFailure(vm, "string clone metadata", rep);
        return 0;
    }
    return rep;
}

static void RepDestroy(GuestVM *vm, gva_t rep) {
    if (!rep || rep == EmptyRep(vm)) return;
    if (GuestHeapOwns(vm, rep)) GuestHeapFree(vm, rep);
    else GuestTrace(vm, @"[cxx] preserving non-heap string rep %#x", rep);
}

static void RepRelease(GuestVM *vm, gva_t rep) {
    if (!rep || rep == EmptyRep(vm)) return;
    uint32_t old = GuestReadU32(vm, rep + 8);
    GuestWriteU32(vm, rep + 8, old - 1u);
    // Darwin GCC COW counts other references: old0 is the last owner; old-1
    // denotes the unique unshareable representation. Use unsigned arithmetic
    // for the decrement so every original 32-bit bit pattern is preserved.
    if ((int32_t)old <= 0) RepDestroy(vm, rep);
}

static void StringAssignBytes(GuestVM *vm, gva_t self, const uint8_t *bytes, uint32_t len) {
    gva_t rep = StringRep(vm, self);
    uint32_t cap = rep ? GuestReadU32(vm, rep + 4) : 0;
    int32_t rc = rep ? (int32_t)GuestReadU32(vm, rep + 8) : 0;
    if (!rep || rep == EmptyRep(vm) || rc > 0 || cap < len) {
        gva_t fresh = RepCreate(vm, len);
        if (!fresh) return;
        uint8_t nul = 0;
        gva_t freshData = fresh + REP_HDR;
        if ((len && !GuestWrite(vm, freshData, bytes, len)) ||
            !GuestWrite(vm, fresh, &len, sizeof(len)) ||
            !GuestWrite(vm, freshData + len, &nul, 1) ||
            !GuestWrite(vm, self, &freshData, sizeof(freshData))) {
            GuestHeapFree(vm, fresh);
            StringMemoryFailure(vm, "string assignment copy/commit", self);
            return;
        }
        // Publish the fully initialized new representation before releasing the
        // old owner. A failed copy or destination write keeps the old string.
        RepRelease(vm, rep);
        return;
    }
    uint32_t unique = 0;
    uint8_t nul = 0;
    if ((len && !GuestWrite(vm, rep + REP_HDR, bytes, len)) ||
        !GuestWrite(vm, rep, &len, sizeof(len)) ||
        !GuestWrite(vm, rep + 8, &unique, sizeof(unique)) ||
        !GuestWrite(vm, rep + REP_HDR + len, &nul, 1))
        StringMemoryFailure(vm, "in-place string assignment", self);
}

static void StringConstructBytes(GuestVM *vm, gva_t self, const uint8_t *bytes, uint32_t len) {
    // Constructor destinations can contain stale stack values.
    GuestWriteU32(vm, self, 0);
    StringAssignBytes(vm, self, bytes, len);
}

static void StringConstructCopy(GuestVM *vm, gva_t self, gva_t other) {
    gva_t rep = StringRep(vm, other);
    if (!rep) {
        StringConstructBytes(vm, self, nullptr, 0);
        return;
    }
    if (rep != EmptyRep(vm)) {
        int32_t rc = (int32_t)GuestReadU32(vm, rep + 8);
        if (rc < 0) {
            rep = RepClone(vm, rep, GuestReadU32(vm, rep));
            if (!rep) return;
        } else {
            GuestWriteU32(vm, rep + 8, (uint32_t)rc + 1);
        }
    }
    GuestWriteU32(vm, self, rep ? rep + REP_HDR : 0);
}

static void ReadString(GuestVM *vm, gva_t self, std::vector<uint8_t> &out) {
    gva_t rep = StringRep(vm, self);
    uint32_t len = rep ? GuestReadU32(vm, rep) : 0;
    out.assign(len, 0);
    if (len) GuestRead(vm, rep + REP_HDR, out.data(), len);
}

static void ReadCStringBytes(GuestVM *vm, gva_t data, std::vector<uint8_t> &out) {
    uint32_t len = (uint32_t)GuestStrLen(vm, data, 1 << 20);
    out.assign(len, 0);
    if (len) GuestRead(vm, data, out.data(), len);
}

static void StringLeak(GuestVM *vm, gva_t self) {
    gva_t rep = StringRep(vm, self);
    if (!rep || rep == EmptyRep(vm)) return;
    if ((int32_t)GuestReadU32(vm, rep + 8) > 0) {
        gva_t fresh = RepClone(vm, rep, GuestReadU32(vm, rep));
        if (!fresh) return;
        RepRelease(vm, rep);
        rep = fresh;
        GuestWriteU32(vm, self, rep + REP_HDR);
    }
    GuestWriteU32(vm, rep + 8, NPOS); // leaked / unshareable
}

// --- operator new / delete --------------------------------------------------
HLE_DEFINE(hle_op_new) {
    uint32_t n = GuestArg(vm, 0);
    gva_t at = GuestHeapAlloc(vm, n ? n : 1);
    if (!at) AllocationFailure(vm, "operator new", n);
    GuestSetRet(vm, at);
}
HLE_BIND("__Znwm", hle_op_new)
HLE_BIND("__Znam", hle_op_new)

HLE_DEFINE(hle_op_new_nothrow) {
    uint32_t n = GuestArg(vm, 0);
    GuestSetRet(vm, GuestHeapAlloc(vm, n ? n : 1));
}
HLE_BIND("__ZnwmRKSt9nothrow_t", hle_op_new_nothrow)
HLE_BIND("__ZnamRKSt9nothrow_t", hle_op_new_nothrow)

HLE_DEFINE(hle_op_delete) {
    gva_t pointer = GuestArg(vm, 0);
    if (!pointer) return;
    if (GuestHeapOwns(vm, pointer)) GuestHeapFree(vm, pointer);
    else GuestTrace(vm, @"[cxx] preserving delete of non-heap pointer %#x", pointer);
}
HLE_BIND("__ZdlPv", hle_op_delete)
HLE_BIND("__ZdaPv", hle_op_delete)

// --- throw helpers ----------------------------------------------------------
static void ReportThrow(GuestVM *vm, const char *what) {
    gva_t arg = GuestArg(vm, 0);
    NSString *msg = arg ? GuestReadCString(vm, arg, 256) : nil;
    GuestTrace(vm, @"[cxx] %@%@ -- SJLJ throw cannot cross into the host",
               [NSString stringWithUTF8String:what],
               msg.length ? [NSString stringWithFormat:@": %@", msg] : @"");
    GuestRequestFault(vm);
}
HLE_DEFINE(hle_throw_bad_alloc) {
    // This helper has no message argument. In particular r0 is not a C string.
    AllocationFailure(vm, "__throw_bad_alloc", 0);
    GuestSetRet(vm, 0);
}
HLE_BIND("__ZSt17__throw_bad_allocv", hle_throw_bad_alloc)
HLE_DEFINE(hle_throw_logic) { ReportThrow(vm, "__throw_logic_error"); }
HLE_BIND("__ZSt19__throw_logic_errorPKc", hle_throw_logic)
HLE_DEFINE(hle_throw_length) { ReportThrow(vm, "__throw_length_error"); }
HLE_BIND("__ZSt20__throw_length_errorPKc", hle_throw_length)
HLE_DEFINE(hle_throw_out_of_range) { ReportThrow(vm, "__throw_out_of_range"); }
HLE_BIND("__ZSt20__throw_out_of_rangePKc", hle_throw_out_of_range)

// --- std::string ------------------------------------------------------------
HLE_DEFINE(hle_rep_create) {   // _S_create(capacity, old_capacity, allocator)
    GuestSetRet(vm, RepCreate(vm, GuestArg(vm, 0)));
}
HLE_BIND("__ZNSs4_Rep9_S_createEmmRKSaIcE", hle_rep_create)

HLE_DEFINE(hle_rep_destroy) { RepDestroy(vm, GuestArg(vm, 0)); GuestSetRet(vm, 0); }
HLE_BIND("__ZNSs4_Rep10_M_destroyERKSaIcE", hle_rep_destroy)

HLE_DEFINE(hle_ctor_cstr) {   // (this, const char*, const allocator&)
    gva_t self = GuestArg(vm, 0), cstr = GuestArg(vm, 1);
    std::vector<uint8_t> b;
    ReadCStringBytes(vm, cstr, b);
    StringConstructBytes(vm, self, b.data(), (uint32_t)b.size());
    GuestSetRet(vm, self);
}
HLE_BIND("__ZNSsC1EPKcRKSaIcE", hle_ctor_cstr)

HLE_DEFINE(hle_ctor_cstr_n) {  // (this, const char*, size_type, const allocator&)
    gva_t self = GuestArg(vm, 0), cstr = GuestArg(vm, 1);
    uint32_t n = GuestArg(vm, 2);
    std::vector<uint8_t> b(n);
    if (n) GuestRead(vm, cstr, b.data(), n);
    StringConstructBytes(vm, self, b.data(), n);
    GuestSetRet(vm, self);
}
HLE_BIND("__ZNSsC1EPKcmRKSaIcE", hle_ctor_cstr_n)

HLE_DEFINE(hle_ctor_copy) {   // (this, const string&)
    gva_t self = GuestArg(vm, 0), other = GuestArg(vm, 1);
    StringConstructCopy(vm, self, other);
    GuestSetRet(vm, self);
}
HLE_BIND("__ZNSsC1ERKSs", hle_ctor_copy)

HLE_DEFINE(hle_ctor_substr) {  // (this, const string&, pos, len)
    gva_t self = GuestArg(vm, 0), other = GuestArg(vm, 1);
    uint32_t pos = GuestArg(vm, 2), len = GuestArg(vm, 3);
    std::vector<uint8_t> src;
    ReadString(vm, other, src);
    if (pos > src.size()) pos = (uint32_t)src.size();
    uint32_t n = (len == NPOS || pos + len > src.size()) ? (uint32_t)(src.size() - pos) : len;
    StringConstructBytes(vm, self, n ? src.data() + pos : nullptr, n);
    GuestSetRet(vm, self);
}
HLE_BIND("__ZNSsC1ERKSsmm", hle_ctor_substr)

HLE_DEFINE(hle_dtor) {
    RepRelease(vm, StringRep(vm, GuestArg(vm, 0)));
}
HLE_BIND("__ZNSsD1Ev", hle_dtor)
HLE_BIND("__ZNSsD2Ev", hle_dtor)

HLE_DEFINE(hle_assign_cstr) {
    gva_t self = GuestArg(vm, 0);
    std::vector<uint8_t> b;
    ReadCStringBytes(vm, GuestArg(vm, 1), b);
    StringAssignBytes(vm, self, b.data(), (uint32_t)b.size());
    GuestSetRet(vm, self);
}
HLE_BIND("__ZNSs6assignEPKc", hle_assign_cstr)

HLE_DEFINE(hle_assign_cstr_n) {
    gva_t self = GuestArg(vm, 0), src = GuestArg(vm, 1);
    uint32_t n = GuestArg(vm, 2);
    std::vector<uint8_t> b(n);
    if (n) GuestRead(vm, src, b.data(), n);
    StringAssignBytes(vm, self, b.data(), n);
    GuestSetRet(vm, self);
}
HLE_BIND("__ZNSs6assignEPKcm", hle_assign_cstr_n)

HLE_DEFINE(hle_assign_str) {
    gva_t self = GuestArg(vm, 0), other = GuestArg(vm, 1);
    std::vector<uint8_t> b;
    ReadString(vm, other, b);
    StringAssignBytes(vm, self, b.data(), (uint32_t)b.size());
    GuestSetRet(vm, self);
}
HLE_BIND("__ZNSs6assignERKSs", hle_assign_str)

HLE_DEFINE(hle_append_cstr_n) {
    gva_t self = GuestArg(vm, 0), src = GuestArg(vm, 1);
    uint32_t n = GuestArg(vm, 2);
    std::vector<uint8_t> cur, add(n);
    ReadString(vm, self, cur);
    if (n) GuestRead(vm, src, add.data(), n);
    cur.insert(cur.end(), add.begin(), add.end());
    StringAssignBytes(vm, self, cur.data(), (uint32_t)cur.size());
    GuestSetRet(vm, self);
}
HLE_BIND("__ZNSs6appendEPKcm", hle_append_cstr_n)

HLE_DEFINE(hle_append_str) {
    gva_t self = GuestArg(vm, 0), other = GuestArg(vm, 1);
    std::vector<uint8_t> cur, add;
    ReadString(vm, self, cur);
    ReadString(vm, other, add);
    cur.insert(cur.end(), add.begin(), add.end());
    StringAssignBytes(vm, self, cur.data(), (uint32_t)cur.size());
    GuestSetRet(vm, self);
}
HLE_BIND("__ZNSs6appendERKSs", hle_append_str)

HLE_DEFINE(hle_replace) {  // (this, pos, len, const char*, size_type n)
    gva_t self = GuestArg(vm, 0);
    uint32_t pos = GuestArg(vm, 1), len = GuestArg(vm, 2), cstr = GuestArg(vm, 3);
    uint32_t n = GuestArg(vm, 4);
    std::vector<uint8_t> cur, rep(n);
    ReadString(vm, self, cur);
    if (pos > cur.size()) pos = (uint32_t)cur.size();
    if (len > cur.size() - pos) len = (uint32_t)(cur.size() - pos);
    if (n) GuestRead(vm, cstr, rep.data(), n);
    cur.erase(cur.begin() + pos, cur.begin() + pos + len);
    cur.insert(cur.begin() + pos, rep.begin(), rep.end());
    StringAssignBytes(vm, self, cur.data(), (uint32_t)cur.size());
    GuestSetRet(vm, self);
}
HLE_BIND("__ZNSs7replaceEmmPKcm", hle_replace)

HLE_DEFINE(hle_reserve) {
    gva_t self = GuestArg(vm, 0), want = GuestArg(vm, 1);
    gva_t rep = StringRep(vm, self);
    uint32_t len = rep ? GuestReadU32(vm, rep) : 0;
    uint32_t cap = rep ? GuestReadU32(vm, rep + 4) : 0;
    if (want < len) want = len;
    if (rep && cap == want && (int32_t)GuestReadU32(vm, rep + 8) <= 0) return;
    gva_t fresh = RepClone(vm, rep, want);
    if (!fresh) return;
    RepRelease(vm, rep);
    GuestWriteU32(vm, self, fresh + REP_HDR);
}
HLE_BIND("__ZNSs7reserveEm", hle_reserve)

HLE_DEFINE(hle_leak_hard) { StringLeak(vm, GuestArg(vm, 0)); }
HLE_BIND("__ZNSs12_M_leak_hardEv", hle_leak_hard)

HLE_DEFINE(hle_at) {   // returns char& as a guest data address
    gva_t self = GuestArg(vm, 0);
    StringLeak(vm, self);
    GuestSetRet(vm, GuestReadU32(vm, self) + GuestArg(vm, 1));
}
HLE_BIND("__ZNSs2atEm", hle_at)

HLE_DEFINE(hle_substr) { // AAPCS non-trivial result: (result, this, pos, len)
    gva_t out = GuestArg(vm, 0), self = GuestArg(vm, 1);
    uint32_t pos = GuestArg(vm, 2), len = GuestArg(vm, 3);
    std::vector<uint8_t> src;
    ReadString(vm, self, src);
    if (pos > src.size()) pos = (uint32_t)src.size();
    uint32_t n = len > src.size() - pos ? (uint32_t)(src.size() - pos) : len;
    StringConstructBytes(vm, out, n ? src.data() + pos : nullptr, n);
    GuestSetRet(vm, out);
}
HLE_BIND("__ZNKSs6substrEmm", hle_substr)

static int CompareBytes(const std::vector<uint8_t> &a, const uint8_t *b, uint32_t bn) {
    uint32_t n = (uint32_t)a.size() < bn ? (uint32_t)a.size() : bn;
    int c = n ? memcmp(a.data(), b, n) : 0;
    if (c) return c < 0 ? -1 : 1;
    if (a.size() == bn) return 0;
    return a.size() < bn ? -1 : 1;
}

HLE_DEFINE(hle_compare_cstr) {
    std::vector<uint8_t> a, b;
    ReadString(vm, GuestArg(vm, 0), a);
    ReadCStringBytes(vm, GuestArg(vm, 1), b);
    GuestSetRet(vm, (uint32_t)(int32_t)CompareBytes(a, b.data(), (uint32_t)b.size()));
}
HLE_BIND("__ZNKSs7compareEPKc", hle_compare_cstr)

HLE_DEFINE(hle_compare_str) {
    std::vector<uint8_t> a, b;
    ReadString(vm, GuestArg(vm, 0), a);
    ReadString(vm, GuestArg(vm, 1), b);
    GuestSetRet(vm, (uint32_t)(int32_t)CompareBytes(a, b.data(), (uint32_t)b.size()));
}
HLE_BIND("__ZNKSs7compareERKSs", hle_compare_str)

HLE_DEFINE(hle_compare_pos_str) {
    std::vector<uint8_t> a, b;
    ReadString(vm, GuestArg(vm, 0), a);
    ReadString(vm, GuestArg(vm, 3), b);
    uint32_t pos = GuestArg(vm, 1), len = GuestArg(vm, 2);
    if (pos > a.size()) pos = (uint32_t)a.size();
    uint32_t n = (len == NPOS || pos + len > a.size()) ? (uint32_t)(a.size() - pos) : len;
    std::vector<uint8_t> slice(a.begin() + pos, a.begin() + pos + n);
    GuestSetRet(vm, (uint32_t)(int32_t)CompareBytes(slice, b.data(), (uint32_t)b.size()));
}
HLE_BIND("__ZNKSs7compareEmmRKSs", hle_compare_pos_str)

HLE_DEFINE(hle_find_char) {   // (this, char c, pos)
    std::vector<uint8_t> a;
    ReadString(vm, GuestArg(vm, 0), a);
    uint8_t c = (uint8_t)GuestArg(vm, 1);
    uint32_t pos = GuestArg(vm, 2);
    for (uint32_t i = pos; i < a.size(); i++) if (a[i] == c) { GuestSetRet(vm, i); return; }
    GuestSetRet(vm, NPOS);
}
HLE_BIND("__ZNKSs4findEcm", hle_find_char)

static void StringFindBytes(GuestVM *vm, bool counted) {
    std::vector<uint8_t> a, n;
    ReadString(vm, GuestArg(vm, 0), a);
    uint32_t pos = GuestArg(vm, 2);
    if (counted) {
        n.resize(GuestArg(vm, 3));
        if (!n.empty()) GuestRead(vm, GuestArg(vm, 1), n.data(), n.size());
    } else {
        ReadCStringBytes(vm, GuestArg(vm, 1), n);
    }
    if (n.empty()) { GuestSetRet(vm, pos <= a.size() ? pos : NPOS); return; }
    if (pos <= a.size() && n.size() <= a.size() - pos) {
        for (uint32_t i = pos; i <= a.size() - n.size(); i++) {
            if (memcmp(a.data() + i, n.data(), n.size()) == 0) { GuestSetRet(vm, i); return; }
        }
    }
    GuestSetRet(vm, NPOS);
}
HLE_DEFINE(hle_find_cstr) { StringFindBytes(vm, false); }
HLE_BIND("__ZNKSs4findEPKcm", hle_find_cstr)
HLE_DEFINE(hle_find_cstr_n) { StringFindBytes(vm, true); }
HLE_BIND("__ZNKSs4findEPKcmm", hle_find_cstr_n)

HLE_DEFINE(hle_rfind_char) {
    std::vector<uint8_t> a;
    ReadString(vm, GuestArg(vm, 0), a);
    uint8_t c = (uint8_t)GuestArg(vm, 1);
    if (!a.empty()) {
        uint32_t pos = GuestArg(vm, 2);
        if (pos >= a.size()) pos = (uint32_t)a.size() - 1;
        do { if (a[pos] == c) { GuestSetRet(vm, pos); return; } } while (pos-- != 0);
    }
    GuestSetRet(vm, NPOS);
}
HLE_BIND("__ZNKSs5rfindEcm", hle_rfind_char)

HLE_DEFINE(hle_find_last_of) {
    std::vector<uint8_t> a, set(GuestArg(vm, 3));
    ReadString(vm, GuestArg(vm, 0), a);
    if (!set.empty()) GuestRead(vm, GuestArg(vm, 1), set.data(), set.size());
    if (!a.empty()) {
        uint32_t pos = GuestArg(vm, 2);
        if (pos >= a.size()) pos = (uint32_t)a.size() - 1;
        do {
            for (uint8_t c : set) if (a[pos] == c) { GuestSetRet(vm, pos); return; }
        } while (pos-- != 0);
    }
    GuestSetRet(vm, NPOS);
}
HLE_BIND("__ZNKSs12find_last_ofEPKcmm", hle_find_last_of)

// --- std::_List_node_base ---------------------------------------------------
// Darwin32 libstdc++ list node: next +0, previous +4. hook has only one
// explicit argument; r2 is caller scratch, never a third link parameter.
HLE_DEFINE(hle_list_hook) { // (this, position): insert this before position
    gva_t self = GuestArg(vm, 0), position = GuestArg(vm, 1);
    gva_t previous = GuestReadU32(vm, position + 4);
    GuestWriteU32(vm, self, position);
    GuestWriteU32(vm, self + 4, previous);
    GuestWriteU32(vm, previous, self);
    GuestWriteU32(vm, position + 4, self);
}
HLE_BIND("__ZNSt15_List_node_base4hookEPS_", hle_list_hook)

HLE_DEFINE(hle_list_unhook) {
    gva_t self = GuestArg(vm, 0);
    gva_t next = GuestReadU32(vm, self), previous = GuestReadU32(vm, self + 4);
    GuestWriteU32(vm, previous, next);
    GuestWriteU32(vm, next + 4, previous);
    // GCC unlinks the node but preserves its own links until it is re-hooked.
}
HLE_BIND("__ZNSt15_List_node_base6unhookEv", hle_list_unhook)

HLE_DEFINE(hle_list_swap) {
    gva_t x = GuestArg(vm, 0), y = GuestArg(vm, 1);
    if (x == y) return;
    gva_t xn = GuestReadU32(vm, x), xp = GuestReadU32(vm, x + 4);
    gva_t yn = GuestReadU32(vm, y), yp = GuestReadU32(vm, y + 4);
    bool xEmpty = xn == x, yEmpty = yn == y;
    GuestWriteU32(vm, x, yEmpty ? x : yn);
    GuestWriteU32(vm, x + 4, yEmpty ? x : yp);
    GuestWriteU32(vm, y, xEmpty ? y : xn);
    GuestWriteU32(vm, y + 4, xEmpty ? y : xp);
    if (!yEmpty) {
        GuestWriteU32(vm, yn + 4, x);
        GuestWriteU32(vm, yp, x);
    }
    if (!xEmpty) {
        GuestWriteU32(vm, xn + 4, y);
        GuestWriteU32(vm, xp, y);
    }
}
HLE_BIND("__ZNSt15_List_node_base4swapERS_S0_", hle_list_swap)

HLE_DEFINE(hle_list_transfer) { // splice [first,last) immediately before this
    gva_t self = GuestArg(vm, 0), first = GuestArg(vm, 1), last = GuestArg(vm, 2);
    if (first == last || self == last) return;
    gva_t beforeFirst = GuestReadU32(vm, first + 4);
    gva_t beforeLast = GuestReadU32(vm, last + 4);
    gva_t beforeSelf = GuestReadU32(vm, self + 4);
    GuestWriteU32(vm, beforeLast, self);
    GuestWriteU32(vm, beforeFirst, last);
    GuestWriteU32(vm, beforeSelf, first);
    GuestWriteU32(vm, self + 4, beforeLast);
    GuestWriteU32(vm, last + 4, beforeFirst);
    GuestWriteU32(vm, first + 4, beforeSelf);
}
HLE_BIND("__ZNSt15_List_node_base8transferEPS_S0_", hle_list_transfer)

// --- std::_Rb_tree node helpers --------------------------------------------
// Apple libstdc++ armv7: color +0, parent +4, left +8, right +12.
// The header uses the same layout; its parent is root and its children are
// leftmost/rightmost. The game's inlined tree methods access these fields.
enum { RB_COLOR = 0, RB_PARENT = 4, RB_LEFT = 8, RB_RIGHT = 12 };
enum { RB_RED = 0, RB_BLACK = 1 };
static gva_t RbGet(GuestVM *vm, gva_t x, uint32_t field) {
    return x ? GuestReadU32(vm, x + field) : 0;
}
static void RbSet(GuestVM *vm, gva_t x, uint32_t field, uint32_t value) {
    if (x) GuestWriteU32(vm, x + field, value);
}
static bool RbBlack(GuestVM *vm, gva_t x) {
    return !x || RbGet(vm, x, RB_COLOR) == RB_BLACK;
}
static gva_t RbMin(GuestVM *vm, gva_t x) {
    while (RbGet(vm, x, RB_LEFT)) x = RbGet(vm, x, RB_LEFT);
    return x;
}
static gva_t RbMax(GuestVM *vm, gva_t x) {
    while (RbGet(vm, x, RB_RIGHT)) x = RbGet(vm, x, RB_RIGHT);
    return x;
}
static void RbRotateLeft(GuestVM *vm, gva_t x, gva_t header) {
    gva_t y = RbGet(vm, x, RB_RIGHT), p = RbGet(vm, x, RB_PARENT);
    gva_t child = RbGet(vm, y, RB_LEFT);
    RbSet(vm, x, RB_RIGHT, child);
    RbSet(vm, child, RB_PARENT, x);
    RbSet(vm, y, RB_PARENT, p);
    if (x == RbGet(vm, header, RB_PARENT)) RbSet(vm, header, RB_PARENT, y);
    else RbSet(vm, p, x == RbGet(vm, p, RB_LEFT) ? RB_LEFT : RB_RIGHT, y);
    RbSet(vm, y, RB_LEFT, x);
    RbSet(vm, x, RB_PARENT, y);
}
static void RbRotateRight(GuestVM *vm, gva_t x, gva_t header) {
    gva_t y = RbGet(vm, x, RB_LEFT), p = RbGet(vm, x, RB_PARENT);
    gva_t child = RbGet(vm, y, RB_RIGHT);
    RbSet(vm, x, RB_LEFT, child);
    RbSet(vm, child, RB_PARENT, x);
    RbSet(vm, y, RB_PARENT, p);
    if (x == RbGet(vm, header, RB_PARENT)) RbSet(vm, header, RB_PARENT, y);
    else RbSet(vm, p, x == RbGet(vm, p, RB_RIGHT) ? RB_RIGHT : RB_LEFT, y);
    RbSet(vm, y, RB_RIGHT, x);
    RbSet(vm, x, RB_PARENT, y);
}
HLE_DEFINE(hle_rb_increment) {
    gva_t x = GuestArg(vm, 0);
    if (RbGet(vm, x, RB_RIGHT)) {
        x = RbMin(vm, RbGet(vm, x, RB_RIGHT));
    } else {
        gva_t y = RbGet(vm, x, RB_PARENT);
        while (x == RbGet(vm, y, RB_RIGHT)) { x = y; y = RbGet(vm, y, RB_PARENT); }
        if (RbGet(vm, x, RB_RIGHT) != y) x = y;
    }
    GuestSetRet(vm, x);
}
HLE_BIND("__ZSt18_Rb_tree_incrementPSt18_Rb_tree_node_base", hle_rb_increment)
HLE_BIND("__ZSt18_Rb_tree_incrementPKSt18_Rb_tree_node_base", hle_rb_increment)

HLE_DEFINE(hle_rb_decrement) {
    gva_t x = GuestArg(vm, 0);
    gva_t p = RbGet(vm, x, RB_PARENT);
    if (RbGet(vm, x, RB_COLOR) == RB_RED && RbGet(vm, p, RB_PARENT) == x) {
        x = RbGet(vm, x, RB_RIGHT); // decrement(end())
    } else if (RbGet(vm, x, RB_LEFT)) {
        x = RbMax(vm, RbGet(vm, x, RB_LEFT));
    } else {
        gva_t y = p;
        while (x == RbGet(vm, y, RB_LEFT)) { x = y; y = RbGet(vm, y, RB_PARENT); }
        x = y;
    }
    GuestSetRet(vm, x);
}
HLE_BIND("__ZSt18_Rb_tree_decrementPSt18_Rb_tree_node_base", hle_rb_decrement)

HLE_DEFINE(hle_rb_insert_rebalance) {
    bool insertLeft = GuestArg(vm, 0) != 0;
    gva_t x = GuestArg(vm, 1), p = GuestArg(vm, 2), header = GuestArg(vm, 3);
    RbSet(vm, x, RB_PARENT, p);
    RbSet(vm, x, RB_LEFT, 0);
    RbSet(vm, x, RB_RIGHT, 0);
    RbSet(vm, x, RB_COLOR, RB_RED);
    if (insertLeft) {
        RbSet(vm, p, RB_LEFT, x);
        if (p == header) {
            RbSet(vm, header, RB_PARENT, x);
            RbSet(vm, header, RB_RIGHT, x);
        } else if (p == RbGet(vm, header, RB_LEFT)) {
            RbSet(vm, header, RB_LEFT, x);
        }
    } else {
        RbSet(vm, p, RB_RIGHT, x);
        if (p == RbGet(vm, header, RB_RIGHT)) RbSet(vm, header, RB_RIGHT, x);
    }
    while (x != RbGet(vm, header, RB_PARENT) &&
           RbGet(vm, RbGet(vm, x, RB_PARENT), RB_COLOR) == RB_RED) {
        p = RbGet(vm, x, RB_PARENT);
        gva_t gp = RbGet(vm, p, RB_PARENT);
        if (p == RbGet(vm, gp, RB_LEFT)) {
            gva_t uncle = RbGet(vm, gp, RB_RIGHT);
            if (uncle && !RbBlack(vm, uncle)) {
                RbSet(vm, p, RB_COLOR, RB_BLACK);
                RbSet(vm, uncle, RB_COLOR, RB_BLACK);
                RbSet(vm, gp, RB_COLOR, RB_RED);
                x = gp;
            } else {
                if (x == RbGet(vm, p, RB_RIGHT)) {
                    x = p;
                    RbRotateLeft(vm, x, header);
                    p = RbGet(vm, x, RB_PARENT);
                    gp = RbGet(vm, p, RB_PARENT);
                }
                RbSet(vm, p, RB_COLOR, RB_BLACK);
                RbSet(vm, gp, RB_COLOR, RB_RED);
                RbRotateRight(vm, gp, header);
            }
        } else {
            gva_t uncle = RbGet(vm, gp, RB_LEFT);
            if (uncle && !RbBlack(vm, uncle)) {
                RbSet(vm, p, RB_COLOR, RB_BLACK);
                RbSet(vm, uncle, RB_COLOR, RB_BLACK);
                RbSet(vm, gp, RB_COLOR, RB_RED);
                x = gp;
            } else {
                if (x == RbGet(vm, p, RB_LEFT)) {
                    x = p;
                    RbRotateRight(vm, x, header);
                    p = RbGet(vm, x, RB_PARENT);
                    gp = RbGet(vm, p, RB_PARENT);
                }
                RbSet(vm, p, RB_COLOR, RB_BLACK);
                RbSet(vm, gp, RB_COLOR, RB_RED);
                RbRotateLeft(vm, gp, header);
            }
        }
    }
    RbSet(vm, RbGet(vm, header, RB_PARENT), RB_COLOR, RB_BLACK);
}
HLE_BIND("__ZSt29_Rb_tree_insert_and_rebalancebPSt18_Rb_tree_node_baseS0_RS_",
         hle_rb_insert_rebalance)

HLE_DEFINE(hle_rb_erase_rebalance) {
    gva_t z = GuestArg(vm, 0), header = GuestArg(vm, 1), y = z, x = 0, xp = 0;
    if (!RbGet(vm, y, RB_LEFT)) x = RbGet(vm, y, RB_RIGHT);
    else if (!RbGet(vm, y, RB_RIGHT)) x = RbGet(vm, y, RB_LEFT);
    else { y = RbMin(vm, RbGet(vm, y, RB_RIGHT)); x = RbGet(vm, y, RB_RIGHT); }
    if (y != z) {
        gva_t left = RbGet(vm, z, RB_LEFT), right = RbGet(vm, z, RB_RIGHT);
        RbSet(vm, left, RB_PARENT, y);
        RbSet(vm, y, RB_LEFT, left);
        if (y != right) {
            xp = RbGet(vm, y, RB_PARENT);
            RbSet(vm, x, RB_PARENT, xp);
            RbSet(vm, xp, RB_LEFT, x);
            RbSet(vm, y, RB_RIGHT, right);
            RbSet(vm, right, RB_PARENT, y);
        } else {
            xp = y;
        }
        gva_t zp = RbGet(vm, z, RB_PARENT);
        if (RbGet(vm, header, RB_PARENT) == z) RbSet(vm, header, RB_PARENT, y);
        else RbSet(vm, zp, RbGet(vm, zp, RB_LEFT) == z ? RB_LEFT : RB_RIGHT, y);
        RbSet(vm, y, RB_PARENT, zp);
        uint32_t color = RbGet(vm, y, RB_COLOR);
        RbSet(vm, y, RB_COLOR, RbGet(vm, z, RB_COLOR));
        RbSet(vm, z, RB_COLOR, color);
        y = z;
    } else {
        xp = RbGet(vm, y, RB_PARENT);
        RbSet(vm, x, RB_PARENT, xp);
        if (RbGet(vm, header, RB_PARENT) == z) RbSet(vm, header, RB_PARENT, x);
        else RbSet(vm, xp, RbGet(vm, xp, RB_LEFT) == z ? RB_LEFT : RB_RIGHT, x);
        if (RbGet(vm, header, RB_LEFT) == z) {
            RbSet(vm, header, RB_LEFT, !RbGet(vm, z, RB_RIGHT) ? xp : RbMin(vm, x));
        }
        if (RbGet(vm, header, RB_RIGHT) == z) {
            RbSet(vm, header, RB_RIGHT, !RbGet(vm, z, RB_LEFT) ? xp : RbMax(vm, x));
        }
    }
    if (RbBlack(vm, y)) {
        while (x != RbGet(vm, header, RB_PARENT) && RbBlack(vm, x)) {
            if (x == RbGet(vm, xp, RB_LEFT)) {
                gva_t w = RbGet(vm, xp, RB_RIGHT);
                if (!RbBlack(vm, w)) {
                    RbSet(vm, w, RB_COLOR, RB_BLACK);
                    RbSet(vm, xp, RB_COLOR, RB_RED);
                    RbRotateLeft(vm, xp, header);
                    w = RbGet(vm, xp, RB_RIGHT);
                }
                if (RbBlack(vm, RbGet(vm, w, RB_LEFT)) && RbBlack(vm, RbGet(vm, w, RB_RIGHT))) {
                    RbSet(vm, w, RB_COLOR, RB_RED);
                    x = xp;
                    xp = RbGet(vm, xp, RB_PARENT);
                } else {
                    if (RbBlack(vm, RbGet(vm, w, RB_RIGHT))) {
                        RbSet(vm, RbGet(vm, w, RB_LEFT), RB_COLOR, RB_BLACK);
                        RbSet(vm, w, RB_COLOR, RB_RED);
                        RbRotateRight(vm, w, header);
                        w = RbGet(vm, xp, RB_RIGHT);
                    }
                    RbSet(vm, w, RB_COLOR, RbGet(vm, xp, RB_COLOR));
                    RbSet(vm, xp, RB_COLOR, RB_BLACK);
                    RbSet(vm, RbGet(vm, w, RB_RIGHT), RB_COLOR, RB_BLACK);
                    RbRotateLeft(vm, xp, header);
                    break;
                }
            } else {
                gva_t w = RbGet(vm, xp, RB_LEFT);
                if (!RbBlack(vm, w)) {
                    RbSet(vm, w, RB_COLOR, RB_BLACK);
                    RbSet(vm, xp, RB_COLOR, RB_RED);
                    RbRotateRight(vm, xp, header);
                    w = RbGet(vm, xp, RB_LEFT);
                }
                if (RbBlack(vm, RbGet(vm, w, RB_RIGHT)) && RbBlack(vm, RbGet(vm, w, RB_LEFT))) {
                    RbSet(vm, w, RB_COLOR, RB_RED);
                    x = xp;
                    xp = RbGet(vm, xp, RB_PARENT);
                } else {
                    if (RbBlack(vm, RbGet(vm, w, RB_LEFT))) {
                        RbSet(vm, RbGet(vm, w, RB_RIGHT), RB_COLOR, RB_BLACK);
                        RbSet(vm, w, RB_COLOR, RB_RED);
                        RbRotateLeft(vm, w, header);
                        w = RbGet(vm, xp, RB_LEFT);
                    }
                    RbSet(vm, w, RB_COLOR, RbGet(vm, xp, RB_COLOR));
                    RbSet(vm, xp, RB_COLOR, RB_BLACK);
                    RbSet(vm, RbGet(vm, w, RB_LEFT), RB_COLOR, RB_BLACK);
                    RbRotateRight(vm, xp, header);
                    break;
                }
            }
        }
        RbSet(vm, x, RB_COLOR, RB_BLACK);
    }
    GuestSetRet(vm, y); // erase unlinks z; the caller destroys this node's value
}
HLE_BIND("__ZSt28_Rb_tree_rebalance_for_erasePSt18_Rb_tree_node_baseRS_",
         hle_rb_erase_rebalance)

// --- Darwin32 libstdc++ character streams -----------------------------------
// These are functional string streams: original code uses them to form values
// and to split input with getline, not merely to print diagnostic messages.
// Layout is independently visible in original constructors 0xc42xx/0x326xx.
static constexpr uint32_t SB_GBASE=4, SB_GPTR=8, SB_GEND=12, SB_PBASE=16,
    SB_PPTR=20, SB_PEND=24, SB_LOCALE=28, SB_MODE=32, SB_STRING=36;
static constexpr uint32_t IOS_PRECISION=4, IOS_WIDTH=8, IOS_FLAGS=12,
    IOS_EXCEPT=16, IOS_STATE=20, IOS_LOCALE=108, IOS_TIE=112,
    IOS_FILL=116, IOS_FILL_INIT=117, IOS_BUFFER=120;
static constexpr uint32_t IO_IN=8, IO_OUT=16, IO_EOF=2, IO_FAIL=4, IO_BAD=1;
static constexpr uint32_t VT_D1=0, VT_D0=1, VT_IMBUE=2, VT_SETBUF=3,
    VT_SEEKOFF=4, VT_SEEKPOS=5, VT_SYNC=6, VT_SHOWMANY=7, VT_XSGETN=8,
    VT_UNDERFLOW=9, VT_UFLOW=10, VT_PBACKFAIL=11, VT_XSPUTN=12, VT_OVERFLOW=13;
struct GuestCxxRuntime {
    bool ready=false;
    gva_t locale=0;
    std::unordered_map<std::string,gva_t> data;
};
@interface GuestCxxRuntimeBox : NSObject { @public GuestCxxRuntime state; }
@end
@implementation GuestCxxRuntimeBox
@end
static char g_cxxRuntimeKey;
static void CxxTables(GuestVM *,GuestCxxRuntime &);
static GuestCxxRuntime &CxxRuntime(GuestVM *vm) {
    GuestCxxRuntimeBox *box=objc_getAssociatedObject(vm,&g_cxxRuntimeKey);
    if(!box){
        @synchronized(vm){
            box=objc_getAssociatedObject(vm,&g_cxxRuntimeKey);
            if(!box){box=[GuestCxxRuntimeBox new];objc_setAssociatedObject(vm,&g_cxxRuntimeKey,box,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
        }
    }
    auto &runtime=box->state;
    CxxTables(vm,runtime);
    return runtime;
}
static gva_t CxxData(GuestVM *vm,const char *name) { return CxxRuntime(vm).data[name]; }
static gva_t EmptyRep(GuestVM *vm) {
    return CxxData(vm,"__ZNSs4_Rep20_S_empty_rep_storageE");
}
static void CxxFault(GuestVM *vm,const char *operation) {
    GuestTrace(vm,@"[cxx-stream] unsupported or invalid %s at guest lr=%#x",operation,GuestLR(vm));
    GuestRequestHalt(vm);
}
static bool GuestBytes(GuestVM *vm,gva_t address,const uint8_t *bytes,uint32_t count) {
    return !count || (address && (uint64_t)address+count<=(1ull<<32) && GuestWrite(vm,address,bytes,count));
}
static void LocaleConstruct(GuestVM *vm,gva_t self) {
    gva_t impl=CxxRuntime(vm).locale;
    GuestWriteU32(vm,self,impl);
    GuestWriteU32(vm,impl,GuestReadU32(vm,impl)+1);
}
static void LocaleDestroy(GuestVM *vm,gva_t self) {
    gva_t impl=GuestReadU32(vm,self);
    if (impl==CxxRuntime(vm).locale) {
        uint32_t count=GuestReadU32(vm,impl);
        if (count>1) GuestWriteU32(vm,impl,count-1);
    }
    GuestWriteU32(vm,self,0);
}
static bool IsStringbuf(GuestVM *vm,gva_t self) {
    return self && GuestReadU32(vm,self)==CxxData(vm,"__ZTVSt15basic_stringbufIcSt11char_traitsIcESaIcEE")+8;
}
static uint32_t VirtualCall(GuestVM *vm,gva_t self,uint32_t slot,uint32_t one=0,uint32_t two=0) {
    gva_t vptr=GuestReadU32(vm,self),target=vptr?GuestReadU32(vm,vptr+slot*4):0;
    if (!target) { CxxFault(vm,"null stream virtual function"); return UINT32_MAX; }
    uint32_t args[3]={self,one,two};
    return GuestCall(vm,target,args,3,1000000);
}
static gva_t BasicIos(GuestVM *vm,gva_t stream) {
    gva_t table=stream?GuestReadU32(vm,stream):0;
    if (!table) { CxxFault(vm,"stream vptr"); return 0; }
    int32_t offset=(int32_t)GuestReadU32(vm,table-12);
    return stream+(uint32_t)offset;
}
static void StreamState(GuestVM *vm,gva_t ios,uint32_t bits) {
    if (!ios) return;
    uint32_t state=GuestReadU32(vm,ios+IOS_STATE)|bits;
    GuestWriteU32(vm,ios+IOS_STATE,state);
    if (state&GuestReadU32(vm,ios+IOS_EXCEPT)) CxxFault(vm,"enabled ios_base exception");
}
static gva_t BufferBase(GuestVM *vm,gva_t self) {
    gva_t base=GuestReadU32(vm,self+SB_PBASE);
    if (!base) base=GuestReadU32(vm,self+SB_GBASE);
    if (!base) base=GuestReadU32(vm,self+SB_STRING);
    return base;
}
static uint32_t BufferSize(GuestVM *vm,gva_t self) {
    gva_t base=BufferBase(vm,self),end=base;
    gva_t gend=GuestReadU32(vm,self+SB_GEND),put=GuestReadU32(vm,self+SB_PPTR);
    if (gend>end) end=gend;
    if (put>end) end=put;
    gva_t rep=StringRep(vm,self+SB_STRING);
    if (base==GuestReadU32(vm,self+SB_STRING) && rep) {
        uint32_t length=GuestReadU32(vm,rep);
        if ((uint64_t)base+length>end) end=base+length;
    }
    return base && end>=base ? end-base : 0;
}
static void StringbufSync(GuestVM *vm,gva_t self,gva_t base,uint32_t input,uint32_t output) {
    uint32_t mode=GuestReadU32(vm,self+SB_MODE);
    gva_t rep=StringRep(vm,self+SB_STRING);
    uint32_t length=rep?GuestReadU32(vm,rep):0,capacity=rep?GuestReadU32(vm,rep+4):0;
    gva_t endg=base+length,endp=base+capacity;
    if (base!=GuestReadU32(vm,self+SB_STRING)) { endg=base+input;input=0;endp=endg; }
    if (mode&IO_IN) {
        GuestWriteU32(vm,self+SB_GBASE,base);GuestWriteU32(vm,self+SB_GPTR,base+input);GuestWriteU32(vm,self+SB_GEND,endg);
    }
    if (mode&IO_OUT) {
        GuestWriteU32(vm,self+SB_PBASE,base);GuestWriteU32(vm,self+SB_PPTR,base+output);GuestWriteU32(vm,self+SB_PEND,endp);
        if (!(mode&IO_IN)) {
            GuestWriteU32(vm,self+SB_GBASE,endg);GuestWriteU32(vm,self+SB_GPTR,endg);GuestWriteU32(vm,self+SB_GEND,endg);
        }
    }
}
static bool StringbufReserve(GuestVM *vm,gva_t self,uint32_t needed) {
    gva_t base=BufferBase(vm,self),data=GuestReadU32(vm,self+SB_STRING),rep=StringRep(vm,self+SB_STRING);
    uint32_t capacity=rep?GuestReadU32(vm,rep+4):0,put=GuestReadU32(vm,self+SB_PPTR),get=GuestReadU32(vm,self+SB_GPTR);
    uint32_t mode=GuestReadU32(vm,self+SB_MODE),length=BufferSize(vm,self);
    uint32_t output=base&&put>=base?put-base:0;
    uint32_t input=(mode&IO_IN)&&base&&get>=base?get-base:0;
    if (needed<=capacity && base==data && rep && (int32_t)GuestReadU32(vm,rep+8)<=0 && rep!=EmptyRep(vm)) return true;
    uint64_t grown=capacity?(uint64_t)capacity*2:512;
    if (grown<needed) grown=needed;
    if (grown<length) grown=length;
    if (grown>0x3ffffff0u) return false;
    gva_t fresh=RepCreate(vm,(uint32_t)grown);
    if (!fresh) return false;
    if (length) {
        std::vector<uint8_t> bytes(length);
        if (!GuestRead(vm,base,bytes.data(),length) || !GuestWrite(vm,fresh+REP_HDR,bytes.data(),length)) {
            RepDestroy(vm,fresh);
            return false;
        }
    }
    GuestWriteU32(vm,fresh,length);uint8_t nul=0;GuestWrite(vm,fresh+REP_HDR+length,&nul,1);
    RepRelease(vm,rep);
    GuestWriteU32(vm,self+SB_STRING,fresh+REP_HDR);
    StringbufSync(vm,self,fresh+REP_HDR,input,output);
    return true;
}
static uint32_t StringbufOverflow(GuestVM *vm,gva_t self,uint32_t character) {
    if (!(GuestReadU32(vm,self+SB_MODE)&IO_OUT)) return UINT32_MAX;
    if (character==UINT32_MAX) return 0; // traits::not_eof(eof())
    gva_t base=BufferBase(vm,self),put=GuestReadU32(vm,self+SB_PPTR);
    uint32_t offset=base&&put>=base?put-base:0;
    if (offset==UINT32_MAX || !StringbufReserve(vm,self,offset+1)) return UINT32_MAX;
    put=GuestReadU32(vm,self+SB_PPTR);
    uint8_t byte=(uint8_t)character;
    if (!GuestWrite(vm,put,&byte,1)) return UINT32_MAX;
    GuestWriteU32(vm,self+SB_PPTR,put+1);
    return byte;
}
static uint32_t StringbufUnderflow(GuestVM *vm,gva_t self) {
    if (!(GuestReadU32(vm,self+SB_MODE)&IO_IN)) return UINT32_MAX;
    gva_t base=BufferBase(vm,self),get=GuestReadU32(vm,self+SB_GPTR),end=base+BufferSize(vm,self);
    GuestWriteU32(vm,self+SB_GEND,end);
    uint8_t byte;
    return get<end && GuestRead(vm,get,&byte,1) ? byte : UINT32_MAX;
}
static uint32_t BufferUnderflow(GuestVM *vm,gva_t self) {
    gva_t get=GuestReadU32(vm,self+SB_GPTR),end=GuestReadU32(vm,self+SB_GEND);
    uint8_t byte;
    if (get && get<end && GuestRead(vm,get,&byte,1)) return byte;
    return IsStringbuf(vm,self)?StringbufUnderflow(vm,self):VirtualCall(vm,self,VT_UNDERFLOW);
}
static uint32_t BaseUflow(GuestVM *vm,gva_t self) {
    uint32_t value=BufferUnderflow(vm,self);
    if (value!=UINT32_MAX) GuestWriteU32(vm,self+SB_GPTR,GuestReadU32(vm,self+SB_GPTR)+1);
    return value;
}
static uint32_t BufferGet(GuestVM *vm,gva_t self) {
    gva_t get=GuestReadU32(vm,self+SB_GPTR),end=GuestReadU32(vm,self+SB_GEND);
    uint8_t byte;
    if (get&&get<end&&GuestRead(vm,get,&byte,1)) {GuestWriteU32(vm,self+SB_GPTR,get+1);return byte;}
    return IsStringbuf(vm,self)?BaseUflow(vm,self):VirtualCall(vm,self,VT_UFLOW);
}
static uint32_t BufferWrite(GuestVM *vm,gva_t self,gva_t source,uint32_t count) {
    uint32_t done=0;
    while (done<count) {
        gva_t put=GuestReadU32(vm,self+SB_PPTR),end=GuestReadU32(vm,self+SB_PEND);
        uint32_t available=put&&end>=put?end-put:0;
        if (available) {
            uint32_t take=std::min(available,count-done);
            std::vector<uint8_t> bytes(take);
            if (!GuestRead(vm,source+done,bytes.data(),take) || !GuestWrite(vm,put,bytes.data(),take)) break;
            GuestWriteU32(vm,self+SB_PPTR,put+take);done+=take;
        } else {
            uint8_t byte;
            if (!GuestRead(vm,source+done,&byte,1)) break;
            uint32_t result=IsStringbuf(vm,self)?StringbufOverflow(vm,self,byte):VirtualCall(vm,self,VT_OVERFLOW,byte);
            if (result==UINT32_MAX) break;
            done++;
        }
    }
    return done;
}
static uint32_t BufferRead(GuestVM *vm,gva_t self,gva_t destination,uint32_t count) {
    uint32_t done=0;
    while (done<count) {
        uint32_t character=BufferGet(vm,self);
        if (character==UINT32_MAX) break;
        uint8_t byte=(uint8_t)character;
        if (!GuestWrite(vm,destination+done,&byte,1)) break;
        done++;
    }
    return done;
}
HLE_DEFINE(hle_cxx_virtual_missing) { CxxFault(vm,"RTTI virtual operation outside imported stream ABI");GuestSetRet(vm,UINT32_MAX); }
HLE_DEFINE(hle_cxx_noop) {}
HLE_DEFINE(hle_cxx_self) {GuestSetRet(vm,GuestArg(vm,0));}
HLE_DEFINE(hle_cxx_zero) {GuestSetRet(vm,0);}
HLE_DEFINE(hle_cxx_eof) {GuestSetRet(vm,UINT32_MAX);}
HLE_DEFINE(hle_locale_ctor) {LocaleConstruct(vm,GuestArg(vm,0));}
HLE_DEFINE(hle_locale_dtor) {LocaleDestroy(vm,GuestArg(vm,0));}
HLE_DEFINE(hle_iosbase_ctor) {
    gva_t self=GuestArg(vm,0);
    uint8_t zero[108]={};GuestWrite(vm,self+4,zero,sizeof(zero));
    GuestWriteU32(vm,self+36,8);GuestWriteU32(vm,self+40,self+44);
    LocaleConstruct(vm,self+IOS_LOCALE);
}
HLE_DEFINE(hle_ios_init) {
    gva_t self=GuestArg(vm,0),buffer=GuestArg(vm,1);
    GuestWriteU32(vm,self+IOS_PRECISION,6);GuestWriteU32(vm,self+IOS_WIDTH,0);GuestWriteU32(vm,self+IOS_FLAGS,0x1002);
    GuestWriteU32(vm,self+IOS_EXCEPT,0);GuestWriteU32(vm,self+IOS_STATE,buffer?0:IO_BAD);
    GuestWriteU32(vm,self+IOS_TIE,0);GuestWriteU32(vm,self+IOS_BUFFER,buffer);
    uint8_t fill[2]={' ',1};GuestWrite(vm,self+IOS_FILL,fill,2);
    GuestWriteU32(vm,self+124,0);GuestWriteU32(vm,self+128,0);GuestWriteU32(vm,self+132,0);
}
HLE_DEFINE(hle_iosbase_dtor) {LocaleDestroy(vm,GuestArg(vm,0)+IOS_LOCALE);}
HLE_DEFINE(hle_stringbuf_sync) {StringbufSync(vm,GuestArg(vm,0),GuestArg(vm,1),GuestArg(vm,2),GuestArg(vm,3));}
HLE_DEFINE(hle_stringbuf_str) {
    gva_t result=GuestArg(vm,0),self=GuestArg(vm,1);
    uint32_t length=BufferSize(vm,self);gva_t base=BufferBase(vm,self);
    std::vector<uint8_t> bytes(length);
    if (length&&!GuestRead(vm,base,bytes.data(),length)) {CxxFault(vm,"stringbuf::str data");return;}
    StringConstructBytes(vm,result,bytes.data(),length);GuestSetRet(vm,result);
}
HLE_DEFINE(hle_xsputn) {
    int32_t count=(int32_t)GuestArg(vm,2);
    GuestSetRet(vm,count>0?BufferWrite(vm,GuestArg(vm,0),GuestArg(vm,1),(uint32_t)count):0);
}
HLE_DEFINE(hle_xsgetn) {
    int32_t count=(int32_t)GuestArg(vm,2);
    GuestSetRet(vm,count>0?BufferRead(vm,GuestArg(vm,0),GuestArg(vm,1),(uint32_t)count):0);
}
HLE_DEFINE(hle_uflow) {GuestSetRet(vm,BaseUflow(vm,GuestArg(vm,0)));}
HLE_DEFINE(hle_stringbuf_underflow) {GuestSetRet(vm,StringbufUnderflow(vm,GuestArg(vm,0)));}
HLE_DEFINE(hle_stringbuf_overflow) {GuestSetRet(vm,StringbufOverflow(vm,GuestArg(vm,0),GuestArg(vm,1)));}
HLE_DEFINE(hle_stringbuf_showmany) {
    gva_t self=GuestArg(vm,0);
    if (!(GuestReadU32(vm,self+SB_MODE)&IO_IN)) {GuestSetRet(vm,UINT32_MAX);return;}
    StringbufUnderflow(vm,self);GuestSetRet(vm,GuestReadU32(vm,self+SB_GEND)-GuestReadU32(vm,self+SB_GPTR));
}
HLE_DEFINE(hle_stringbuf_pbackfail) {
    gva_t self=GuestArg(vm,0),get=GuestReadU32(vm,self+SB_GPTR),base=GuestReadU32(vm,self+SB_GBASE);
    uint32_t character=GuestArg(vm,1);uint8_t previous;
    if (get<=base || !GuestRead(vm,get-1,&previous,1)) {GuestSetRet(vm,UINT32_MAX);return;}
    if (character!=UINT32_MAX && previous!=(uint8_t)character && !(GuestReadU32(vm,self+SB_MODE)&IO_OUT)) {GuestSetRet(vm,UINT32_MAX);return;}
    GuestWriteU32(vm,self+SB_GPTR,get-1);
    if (character!=UINT32_MAX) {uint8_t byte=(uint8_t)character;GuestWrite(vm,get-1,&byte,1);}
    GuestSetRet(vm,character==UINT32_MAX?0:(uint8_t)character);
}
HLE_DEFINE(hle_stringbuf_setbuf) {
    gva_t self=GuestArg(vm,0),bytes=GuestArg(vm,1);int32_t count=(int32_t)GuestArg(vm,2);
    if (bytes&&count>=0) {StringAssignBytes(vm,self+SB_STRING,nullptr,0);StringbufSync(vm,self,bytes,(uint32_t)count,0);}
    GuestSetRet(vm,self);
}
static void PositionResult(GuestVM *vm,gva_t destination,int64_t offset,const uint8_t *state=nullptr) {
    uint8_t result[136]={};memcpy(result,&offset,8);if(state)memcpy(result+8,state,128);GuestWrite(vm,destination,result,sizeof(result));
}
static int64_t StringbufSeek(GuestVM *vm,gva_t self,int64_t offset,uint32_t way,uint32_t which) {
    uint32_t mode=GuestReadU32(vm,self+SB_MODE);bool input=(mode&which&IO_IN)!=0,output=(mode&which&IO_OUT)!=0;
    if ((!input&&!output)||(way==1&&input&&output)||way>2) return -1;
    gva_t base=BufferBase(vm,self);uint32_t size=BufferSize(vm,self);
    if (way==1) offset+=(input?GuestReadU32(vm,self+SB_GPTR):GuestReadU32(vm,self+SB_PPTR))-base;
    else if (way==2) offset+=size;
    if (offset<0||(uint64_t)offset>size)return -1;
    GuestWriteU32(vm,self+SB_GEND,base+size);
    if(!(mode&IO_IN)){GuestWriteU32(vm,self+SB_GBASE,base+size);GuestWriteU32(vm,self+SB_GPTR,base+size);}
    if(input){GuestWriteU32(vm,self+SB_GBASE,base);GuestWriteU32(vm,self+SB_GPTR,base+(uint32_t)offset);GuestWriteU32(vm,self+SB_GEND,base+size);}
    if(output)GuestWriteU32(vm,self+SB_PPTR,base+(uint32_t)offset);
    return offset;
}
HLE_DEFINE(hle_streambuf_seekfail) {PositionResult(vm,GuestArg(vm,0),-1);}
HLE_DEFINE(hle_stringbuf_seekoff) {
    uint64_t bits=GuestArg(vm,2)|((uint64_t)GuestArg(vm,3)<<32);
    PositionResult(vm,GuestArg(vm,0),StringbufSeek(vm,GuestArg(vm,1),(int64_t)bits,GuestArg(vm,4),GuestArg(vm,5)));
}
HLE_DEFINE(hle_stringbuf_seekpos) {
    uint32_t position[34];for(int i=0;i<34;i++)position[i]=GuestArg(vm,2+i);
    int64_t offset;memcpy(&offset,position,8);
    int64_t result=StringbufSeek(vm,GuestArg(vm,1),offset,0,GuestArg(vm,36));
    PositionResult(vm,GuestArg(vm,0),result,result>=0?(const uint8_t*)position+8:nullptr);
}
static void StringbufDestroy(GuestVM *vm,gva_t self) {
    RepRelease(vm,StringRep(vm,self+SB_STRING));GuestWriteU32(vm,self+SB_STRING,0);LocaleDestroy(vm,self+SB_LOCALE);
}
HLE_DEFINE(hle_stringbuf_dtor) {StringbufDestroy(vm,GuestArg(vm,0));}
HLE_DEFINE(hle_streambuf_dtor) {LocaleDestroy(vm,GuestArg(vm,0)+SB_LOCALE);}
HLE_DEFINE(hle_stream_dtor) {
    gva_t self=GuestArg(vm,0),table=GuestReadU32(vm,self);if(!table)return;
    gva_t top=self+GuestReadU32(vm,table-8),primary=GuestReadU32(vm,top);
    if(primary==CxxData(vm,"__ZTVSt19basic_ostringstreamIcSt11char_traitsIcESaIcEE")+12){StringbufDestroy(vm,top+4);LocaleDestroy(vm,top+44+IOS_LOCALE);}
    else if(primary==CxxData(vm,"__ZTVSt18basic_stringstreamIcSt11char_traitsIcESaIcEE")+12){StringbufDestroy(vm,top+12);LocaleDestroy(vm,top+52+IOS_LOCALE);}
    else if(table==CxxData(vm,"__ZTVSt9basic_iosIcSt11char_traitsIcEE")+8)LocaleDestroy(vm,self+IOS_LOCALE);
    else {gva_t ios=BasicIos(vm,top);if(ios)LocaleDestroy(vm,ios+IOS_LOCALE);}
}
static uint32_t StreamWriteBytes(GuestVM *vm,gva_t buffer,const uint8_t *bytes,uint32_t count) {
    if (!count) return 0;
    if (IsStringbuf(vm,buffer)) {
        if (!(GuestReadU32(vm,buffer+SB_MODE)&IO_OUT)) return 0;
        gva_t base=BufferBase(vm,buffer),put=GuestReadU32(vm,buffer+SB_PPTR);
        uint32_t offset=base&&put>=base?put-base:0;
        if ((uint64_t)offset+count>UINT32_MAX || !StringbufReserve(vm,buffer,offset+count)) return 0;
        put=GuestReadU32(vm,buffer+SB_PPTR);
        if (!GuestBytes(vm,put,bytes,count)) return 0;
        GuestWriteU32(vm,buffer+SB_PPTR,put+count);
        return count;
    }
    gva_t source=GuestHeapAlloc(vm,count);
    if (!source) { AllocationFailure(vm,"ostream temporary",count); return 0; }
    @try {
        if (!GuestWrite(vm,source,bytes,count)) return 0;
        return VirtualCall(vm,buffer,VT_XSPUTN,source,count);
    } @finally {
        // xsputn consumes the source synchronously; its caller owns these bytes.
        GuestHeapFree(vm,source);
    }
}
static bool StreamSentry(GuestVM *vm,gva_t ios) {
    if (!ios || GuestReadU32(vm,ios+IOS_STATE)) return false;
    gva_t tie=GuestReadU32(vm,ios+IOS_TIE);
    if (tie) {
        gva_t tiedIos=BasicIos(vm,tie),buffer=tiedIos?GuestReadU32(vm,tiedIos+IOS_BUFFER):0;
        if (buffer && (int32_t)VirtualCall(vm,buffer,VT_SYNC)==-1) StreamState(vm,tiedIos,IO_BAD);
    }
    return true;
}
static bool StreamPadding(GuestVM *vm,gva_t buffer,uint8_t fill,uint32_t count) {
    uint8_t bytes[256];memset(bytes,fill,sizeof(bytes));
    while(count){uint32_t take=std::min<uint32_t>(count,sizeof(bytes));if(StreamWriteBytes(vm,buffer,bytes,take)!=take)return false;count-=take;}
    return true;
}
static void OstreamInsert(GuestVM *vm,gva_t self,const std::vector<uint8_t> &text,bool numeric=false) {
    gva_t ios=BasicIos(vm,self);
    if (!StreamSentry(vm,ios)) return;
    gva_t buffer=GuestReadU32(vm,ios+IOS_BUFFER);
    if (!buffer){StreamState(vm,ios,IO_BAD);return;}
    int32_t requested=(int32_t)GuestReadU32(vm,ios+IOS_WIDTH);
    uint32_t padding=requested>0&&(uint32_t)requested>text.size()?(uint32_t)requested-(uint32_t)text.size():0;
    uint32_t flags=GuestReadU32(vm,ios+IOS_FLAGS),adjust=flags&0xb0;
    uint8_t fill=' ';GuestRead(vm,ios+IOS_FILL,&fill,1);
    bool ok=true;size_t prefix=0;
    if(numeric&&adjust==0x10&&!text.empty()) {
        if(text[0]=='+'||text[0]=='-')prefix=1;
        else if(text.size()>1&&text[0]=='0'&&(text[1]=='x'||text[1]=='X'))prefix=2;
    }
    if(prefix)ok=StreamWriteBytes(vm,buffer,text.data(),(uint32_t)prefix)==prefix;
    if(ok&&adjust!=0x20)ok=StreamPadding(vm,buffer,fill,padding);
    if(ok&&text.size()>prefix)ok=StreamWriteBytes(vm,buffer,text.data()+prefix,(uint32_t)(text.size()-prefix))==text.size()-prefix;
    if(ok&&adjust==0x20)ok=StreamPadding(vm,buffer,fill,padding);
    GuestWriteU32(vm,ios+IOS_WIDTH,0);
    if(!ok)StreamState(vm,ios,IO_BAD);
    if(flags&0x2000)if((int32_t)VirtualCall(vm,buffer,VT_SYNC)==-1)StreamState(vm,ios,IO_BAD);
}
HLE_DEFINE(hle_ostream_insert) {
    gva_t self=GuestArg(vm,0);int32_t count=(int32_t)GuestArg(vm,2);
    if(count>=0){std::vector<uint8_t> bytes((size_t)count);if(!count||GuestRead(vm,GuestArg(vm,1),bytes.data(),bytes.size()))OstreamInsert(vm,self,bytes);else StreamState(vm,BasicIos(vm,self),IO_BAD);}
    GuestSetRet(vm,self);
}
HLE_DEFINE(hle_ostream_cstr) {
    gva_t self=GuestArg(vm,0),source=GuestArg(vm,1);
    if(!source){StreamState(vm,BasicIos(vm,self),IO_BAD);GuestSetRet(vm,self);return;}
    std::vector<uint8_t> bytes;ReadCStringBytes(vm,source,bytes);OstreamInsert(vm,self,bytes);GuestSetRet(vm,self);
}
template<typename Value> static void OstreamNumber(GuestVM *vm,gva_t self,const std::string &format,Value value) {
    int count=snprintf(nullptr,0,format.c_str(),value);
    if(count<0){StreamState(vm,BasicIos(vm,self),IO_BAD);return;}
    std::vector<uint8_t> text((size_t)count+1);
    snprintf((char*)text.data(),text.size(),format.c_str(),value);text.resize((size_t)count);OstreamInsert(vm,self,text,true);
}
static std::string IntegerFormat(GuestVM *vm,gva_t self,bool signedValue) {
    uint32_t flags=GuestReadU32(vm,BasicIos(vm,self)+IOS_FLAGS),base=flags&0x4a;
    std::string format="%";
    if(flags&0x200)format+='#';
    if(signedValue&&base!=8&&base!=0x40&&(flags&0x800))format+='+';
    format+=base==8?((flags&0x4000)?'X':'x'):base==0x40?'o':signedValue?'d':'u';
    return format;
}
HLE_DEFINE(hle_ostream_int) {
    gva_t self=GuestArg(vm,0);uint32_t flags=GuestReadU32(vm,BasicIos(vm,self)+IOS_FLAGS);
    if((flags&0x4a)==8||(flags&0x4a)==0x40)OstreamNumber(vm,self,IntegerFormat(vm,self,false),GuestArg(vm,1));
    else OstreamNumber(vm,self,IntegerFormat(vm,self,true),(int32_t)GuestArg(vm,1));GuestSetRet(vm,self);
}
HLE_DEFINE(hle_ostream_ulong) {gva_t self=GuestArg(vm,0);OstreamNumber(vm,self,IntegerFormat(vm,self,false),GuestArg(vm,1));GuestSetRet(vm,self);}
HLE_DEFINE(hle_ostream_double) {
    gva_t self=GuestArg(vm,0),ios=BasicIos(vm,self);uint32_t flags=GuestReadU32(vm,ios+IOS_FLAGS);
    int32_t precision=(int32_t)GuestReadU32(vm,ios+IOS_PRECISION);if(precision<0)precision=6;
    std::string format="%";if(flags&0x800)format+='+';if(flags&0x400)format+='#';format+='.';format+=std::to_string(precision);
    uint32_t floating=flags&0x104;char conversion=floating==4?'f':floating==0x100?'e':floating==0x104?'a':'g';if(flags&0x4000)conversion=(char)(conversion-'a'+'A');format+=conversion;
    uint64_t bits=GuestArg(vm,1)|((uint64_t)GuestArg(vm,2)<<32);double value;memcpy(&value,&bits,8);OstreamNumber(vm,self,format,value);GuestSetRet(vm,self);
}
HLE_DEFINE(hle_widen) {GuestSetRet(vm,(uint32_t)(int32_t)(int8_t)GuestArg(vm,1));}
HLE_DEFINE(hle_getline) {
    gva_t self=GuestArg(vm,0),result=GuestArg(vm,1),ios=BasicIos(vm,self);uint8_t delimiter=(uint8_t)GuestArg(vm,2);
    if(!StreamSentry(vm,ios)){StreamState(vm,ios,IO_FAIL);GuestSetRet(vm,self);return;}
    gva_t buffer=GuestReadU32(vm,ios+IOS_BUFFER);if(!buffer){StreamState(vm,ios,IO_BAD|IO_FAIL);GuestSetRet(vm,self);return;}
    std::vector<uint8_t> bytes;uint32_t extracted=0,state=0;
    for(;;){uint32_t value=BufferGet(vm,buffer);if(value==UINT32_MAX){state|=IO_EOF;break;}extracted++;if((uint8_t)value==delimiter)break;bytes.push_back((uint8_t)value);}
    StringAssignBytes(vm,result,bytes.data(),(uint32_t)bytes.size());if(!extracted)state|=IO_FAIL;if(state)StreamState(vm,ios,state);GuestSetRet(vm,self);
}

HLE_BIND("__ZNSolsEi",hle_ostream_int)
HLE_BIND("__ZNSo9_M_insertIdEERSoT_",hle_ostream_double)
HLE_BIND("__ZNSo9_M_insertImEERSoT_",hle_ostream_ulong)
HLE_BIND("__ZStlsISt11char_traitsIcEERSt13basic_ostreamIcT_ES5_PKc",hle_ostream_cstr)
HLE_BIND("__ZSt16__ostream_insertIcSt11char_traitsIcEERSt13basic_ostreamIT_T0_ES6_PKS3_i",hle_ostream_insert)
HLE_BIND("__ZSt7getlineIcSt11char_traitsIcESaIcEERSt13basic_istreamIT_T0_ES7_RSbIS4_S5_T1_ES4_",hle_getline)
HLE_BIND("__ZNKSt15basic_stringbufIcSt11char_traitsIcESaIcEE3strEv",hle_stringbuf_str)
HLE_BIND("__ZNSt15basic_stringbufIcSt11char_traitsIcESaIcEE7_M_syncEPcmm",hle_stringbuf_sync)
HLE_BIND("__ZNSt15basic_streambufIcSt11char_traitsIcEE6xsputnEPKci",hle_xsputn)
HLE_BIND("__ZNSt15basic_streambufIcSt11char_traitsIcEE6xsgetnEPci",hle_xsgetn)
HLE_BIND("__ZNSt15basic_streambufIcSt11char_traitsIcEE5uflowEv",hle_uflow)
HLE_BIND("__ZNSt15basic_streambufIcSt11char_traitsIcEE4syncEv",hle_cxx_zero)
HLE_BIND("__ZNSt15basic_streambufIcSt11char_traitsIcEE5imbueERKSt6locale",hle_cxx_noop)
HLE_BIND("__ZNKSt9basic_iosIcSt11char_traitsIcEE5widenEc",hle_widen)
HLE_BIND("__ZNSt6localeC1Ev",hle_locale_ctor)
HLE_BIND("__ZNSt6localeD1Ev",hle_locale_dtor)
HLE_BIND("__ZNSt8ios_baseC2Ev",hle_iosbase_ctor)
HLE_BIND("__ZNSt8ios_baseD2Ev",hle_iosbase_dtor)
HLE_BIND("__ZNSt9basic_iosIcSt11char_traitsIcEE4initEPSt15basic_streambufIcS1_E",hle_ios_init)
HLE_BIND("__ZNSt19basic_ostringstreamIcSt11char_traitsIcESaIcEED1Ev",hle_stream_dtor)
HLE_BIND("__ZNSdD0Ev",hle_stream_dtor)
HLE_BIND("__ZNSdD1Ev",hle_stream_dtor)
HLE_BIND("__ZNSdD2Ev",hle_cxx_noop)
HLE_BIND("__ZNSiD0Ev",hle_stream_dtor)
HLE_BIND("__ZNSiD1Ev",hle_stream_dtor)
HLE_BIND("__ZNSoD0Ev",hle_stream_dtor)
HLE_BIND("__ZNSoD1Ev",hle_stream_dtor)
HLE_BIND("__ZTv0_n12_NSdD0Ev",hle_stream_dtor)
HLE_BIND("__ZTv0_n12_NSdD1Ev",hle_stream_dtor)
HLE_BIND("__ZTv0_n12_NSiD0Ev",hle_stream_dtor)
HLE_BIND("__ZTv0_n12_NSiD1Ev",hle_stream_dtor)
HLE_BIND("__ZTv0_n12_NSoD0Ev",hle_stream_dtor)
HLE_BIND("__ZTv0_n12_NSoD1Ev",hle_stream_dtor)
HLE_BIND("__ZThn8_NSdD0Ev",hle_stream_dtor)
HLE_BIND("__ZThn8_NSdD1Ev",hle_stream_dtor)
HLE_BIND("__ZNSt8ios_base4InitC1Ev",hle_cxx_noop)
HLE_BIND("__ZNSt8ios_base4InitD1Ev",hle_cxx_noop)
// Private system-runtime virtual functions. Their identities must be in the
// offline provider's fixed native bridge table before these tables are built.
HLE_BIND("__as6_cxx_missing",hle_cxx_virtual_missing)
HLE_BIND("__as6_cxx_noop",hle_cxx_noop)
HLE_BIND("__as6_cxx_self",hle_cxx_self)
HLE_BIND("__as6_cxx_zero",hle_cxx_zero)
HLE_BIND("__as6_cxx_eof",hle_cxx_eof)
HLE_BIND("__as6_cxx_buf_dtor",hle_streambuf_dtor)
HLE_BIND("__as6_cxx_strbuf_dtor",hle_stringbuf_dtor)
HLE_BIND("__as6_cxx_stream_dtor",hle_stream_dtor)
HLE_BIND("__as6_cxx_seekfail",hle_streambuf_seekfail)
HLE_BIND("__as6_cxx_strbuf_seekoff",hle_stringbuf_seekoff)
HLE_BIND("__as6_cxx_strbuf_seekpos",hle_stringbuf_seekpos)
HLE_BIND("__as6_cxx_strbuf_setbuf",hle_stringbuf_setbuf)
HLE_BIND("__as6_cxx_strbuf_showmany",hle_stringbuf_showmany)
HLE_BIND("__as6_cxx_strbuf_underflow",hle_stringbuf_underflow)
HLE_BIND("__as6_cxx_strbuf_pbackfail",hle_stringbuf_pbackfail)
HLE_BIND("__as6_cxx_strbuf_overflow",hle_stringbuf_overflow)

// --- guest-resident C++ data: vtables, construction tables, VTTs -------------
static gva_t CxxAllocate(GuestVM *vm,GuestCxxRuntime &r,const char *name,uint32_t bytes) {
    gva_t at=GuestAlloc(vm,bytes);std::vector<uint8_t> zero(bytes);if(at)GuestWrite(vm,at,zero.data(),zero.size());r.data[name]=at;return at;
}
static void CxxWords(GuestVM *vm,gva_t at,const std::vector<uint32_t> &words) {GuestWrite(vm,at,words.data(),words.size()*4);}
static gva_t CxxTypeName(GuestVM *vm,const char *name) {
    gva_t text=GuestAlloc(vm,strlen(name)+1);GuestWrite(vm,text,name,strlen(name)+1);return text;
}
static gva_t CxxTypeInfo(GuestVM *vm,GuestCxxRuntime &r,const char *name,gva_t base=0) {
    gva_t at=GuestAlloc(vm,base?12:8);
    GuestWriteU32(vm,at,r.data[base?"__ZTVN10__cxxabiv120__si_class_type_infoE":"__ZTVN10__cxxabiv117__class_type_infoE"]+8);
    GuestWriteU32(vm,at+4,CxxTypeName(vm,name));if(base)GuestWriteU32(vm,at+8,base);return at;
}
static gva_t CxxVmiTypeInfo(GuestVM *vm,GuestCxxRuntime &r,const char *name,uint32_t flags,
                            const std::vector<std::pair<gva_t,int32_t>> &bases) {
    gva_t at=GuestAlloc(vm,16+bases.size()*8);
    GuestWriteU32(vm,at,r.data["__ZTVN10__cxxabiv121__vmi_class_type_infoE"]+8);
    GuestWriteU32(vm,at+4,CxxTypeName(vm,name));GuestWriteU32(vm,at+8,flags);GuestWriteU32(vm,at+12,(uint32_t)bases.size());
    for(size_t i=0;i<bases.size();i++){GuestWriteU32(vm,at+16+i*8,bases[i].first);GuestWriteU32(vm,at+20+i*8,(uint32_t)bases[i].second);}
    return at;
}
static void CxxStreamTable(GuestVM *vm,gva_t at,gva_t type,uint32_t virtualOffset,bool twoBases) {
    gva_t dtor=GuestHLEAddress(vm,"__as6_cxx_stream_dtor");
    if(!twoBases)CxxWords(vm,at,{virtualOffset,0,type,dtor,dtor,(uint32_t)-(int32_t)virtualOffset,(uint32_t)-(int32_t)virtualOffset,type,dtor,dtor});
    else CxxWords(vm,at,{virtualOffset,0,type,dtor,dtor,virtualOffset-8,(uint32_t)-8,type,dtor,dtor,(uint32_t)-(int32_t)virtualOffset,(uint32_t)-(int32_t)virtualOffset,type,dtor,dtor});
}
static void CxxTables(GuestVM *vm,GuestCxxRuntime &r) {
    if(r.ready)return;r.ready=true;
    CxxAllocate(vm,r,"__ZNSs4_Rep20_S_empty_rep_storageE",REP_HDR+1);
    CxxAllocate(vm,r,"__ZSt7nothrow",1);
    gva_t typeTable=CxxAllocate(vm,r,"__ZTVN10__cxxabiv117__class_type_infoE",64);
    gva_t siTable=CxxAllocate(vm,r,"__ZTVN10__cxxabiv120__si_class_type_infoE",64);
    gva_t vmiTable=CxxAllocate(vm,r,"__ZTVN10__cxxabiv121__vmi_class_type_infoE",64);
    gva_t missing=GuestHLEAddress(vm,"__as6_cxx_missing"),noop=GuestHLEAddress(vm,"__as6_cxx_noop");
    for(gva_t table:{typeTable,siTable,vmiTable})for(uint32_t i=2;i<16;i++)GuestWriteU32(vm,table+i*4,i<4?noop:(i<6?GuestHLEAddress(vm,"__as6_cxx_zero"):missing));
    gva_t typeInfoType=CxxTypeInfo(vm,r,"St9type_info");
    gva_t classType=CxxTypeInfo(vm,r,"N10__cxxabiv117__class_type_infoE",typeInfoType);
    gva_t siType=CxxTypeInfo(vm,r,"N10__cxxabiv120__si_class_type_infoE",classType);
    gva_t vmiType=CxxTypeInfo(vm,r,"N10__cxxabiv121__vmi_class_type_infoE",classType);
    GuestWriteU32(vm,typeTable+4,classType);GuestWriteU32(vm,siTable+4,siType);GuestWriteU32(vm,vmiTable+4,vmiType);
    gva_t bufType=CxxTypeInfo(vm,r,"St15basic_streambufIcSt11char_traitsIcEE");
    gva_t strbufType=CxxTypeInfo(vm,r,"St15basic_stringbufIcSt11char_traitsIcESaIcEE",bufType);
    gva_t iosBaseType=CxxTypeInfo(vm,r,"St8ios_base");
    gva_t iosType=CxxTypeInfo(vm,r,"St9basic_iosIcSt11char_traitsIcEE",iosBaseType);
    // __offset_flags: low bits public|virtual=3, signed offset -12 points
    // at the vbase-offset word preceding the ostream/istream address point.
    gva_t ostreamType=CxxVmiTypeInfo(vm,r,"So",0,{{iosType,-12*256+3}});
    gva_t istreamType=CxxVmiTypeInfo(vm,r,"Si",0,{{iosType,-12*256+3}});
    gva_t iostreamType=CxxVmiTypeInfo(vm,r,"Sd",2,{{istreamType,2},{ostreamType,8*256+2}});
    gva_t osType=CxxTypeInfo(vm,r,"St19basic_ostringstreamIcSt11char_traitsIcESaIcEE",ostreamType);
    gva_t ssType=CxxTypeInfo(vm,r,"St18basic_stringstreamIcSt11char_traitsIcESaIcEE",iostreamType);
    gva_t baseBuf=CxxAllocate(vm,r,"__ZTVSt15basic_streambufIcSt11char_traitsIcEE",64);
    gva_t strBuf=CxxAllocate(vm,r,"__ZTVSt15basic_stringbufIcSt11char_traitsIcESaIcEE",64);
    const char *baseMethods[]={"__as6_cxx_buf_dtor","__as6_cxx_buf_dtor","__as6_cxx_noop","__as6_cxx_self","__as6_cxx_seekfail","__as6_cxx_seekfail","__as6_cxx_zero","__as6_cxx_zero","__ZNSt15basic_streambufIcSt11char_traitsIcEE6xsgetnEPci","__as6_cxx_eof","__ZNSt15basic_streambufIcSt11char_traitsIcEE5uflowEv","__as6_cxx_eof","__ZNSt15basic_streambufIcSt11char_traitsIcEE6xsputnEPKci","__as6_cxx_eof"};
    const char *stringMethods[]={"__as6_cxx_strbuf_dtor","__as6_cxx_strbuf_dtor","__as6_cxx_noop","__as6_cxx_strbuf_setbuf","__as6_cxx_strbuf_seekoff","__as6_cxx_strbuf_seekpos","__as6_cxx_zero","__as6_cxx_strbuf_showmany","__ZNSt15basic_streambufIcSt11char_traitsIcEE6xsgetnEPci","__as6_cxx_strbuf_underflow","__ZNSt15basic_streambufIcSt11char_traitsIcEE5uflowEv","__as6_cxx_strbuf_pbackfail","__ZNSt15basic_streambufIcSt11char_traitsIcEE6xsputnEPKci","__as6_cxx_strbuf_overflow"};
    GuestWriteU32(vm,baseBuf+4,bufType);GuestWriteU32(vm,strBuf+4,strbufType);
    for(uint32_t i=0;i<14;i++){GuestWriteU32(vm,baseBuf+8+i*4,GuestHLEAddress(vm,baseMethods[i]));GuestWriteU32(vm,strBuf+8+i*4,GuestHLEAddress(vm,stringMethods[i]));}
    gva_t ios=CxxAllocate(vm,r,"__ZTVSt9basic_iosIcSt11char_traitsIcEE",16),dtor=GuestHLEAddress(vm,"__as6_cxx_stream_dtor");CxxWords(vm,ios,{0,iosType,dtor,dtor});
    gva_t os=CxxAllocate(vm,r,"__ZTVSt19basic_ostringstreamIcSt11char_traitsIcESaIcEE",40);
    gva_t ss=CxxAllocate(vm,r,"__ZTVSt18basic_stringstreamIcSt11char_traitsIcESaIcEE",60);
    CxxStreamTable(vm,os,osType,44,false);CxxStreamTable(vm,ss,ssType,52,true);
    // Construction vtables carry the final virtual-base locations required by
    // the original inlined base constructors, before complete vptrs are set.
    gva_t osCtor=GuestAlloc(vm,40),ssIoCtor=GuestAlloc(vm,60),ssICtor=GuestAlloc(vm,40),ssOCtor=GuestAlloc(vm,40);
    CxxStreamTable(vm,osCtor,ostreamType,44,false);CxxStreamTable(vm,ssIoCtor,iostreamType,52,true);CxxStreamTable(vm,ssICtor,istreamType,52,false);CxxStreamTable(vm,ssOCtor,ostreamType,44,false);
    gva_t osVtt=CxxAllocate(vm,r,"__ZTTSt19basic_ostringstreamIcSt11char_traitsIcESaIcEE",16);CxxWords(vm,osVtt,{os+12,osCtor+12,osCtor+32,os+32});
    gva_t ssVtt=CxxAllocate(vm,r,"__ZTTSt18basic_stringstreamIcSt11char_traitsIcESaIcEE",32);CxxWords(vm,ssVtt,{ss+12,ssIoCtor+12,ssICtor+12,ssICtor+32,ssOCtor+12,ssOCtor+32,ssIoCtor+52,ssIoCtor+32});
    r.locale=GuestAlloc(vm,32);uint32_t locale[8]={1,0,0,0,0,0,0,0};GuestWrite(vm,r.locale,locale,sizeof(locale));
}
BOOL HLEStdCxxData(const char *symbol,GuestVM *vm,uint32_t *out) {
    if(!symbol||!vm||!out)return NO;
    auto &r=CxxRuntime(vm);auto found=r.data.find(symbol);if(found==r.data.end())return NO;
    *out=found->second;return YES;
}
void HLEInstallCxxAbi(void) { /* HLE_BIND registers the system ABI functions. */ }
