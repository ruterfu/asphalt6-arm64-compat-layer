// CoreFoundation's C APIs still receive guest addresses and Darwin armv7 word
// layouts. Opaque CF references, toll-free Foundation objects, guest constant
// strings, and numeric out-parameters need distinct translations.
#import "HLE.h"
#import "GuestVM.h"
#import "GuestObjC.h"
#include "GuestCFCallbacks.hpp"

#import <CoreFoundation/CoreFoundation.h>
#include <cstdint>
#include <cstring>
#include <string>
#include <unordered_map>

// Hold decoded guest constants for the complete host call. Host handle tables
// already own their objects; only a copied guest constant needs a temporary +1.
struct GuestCFArg {
    CFTypeRef value = nullptr;
    bool temporary = false;
    GuestCFArg(GuestVM *vm, gva_t word) {
        if (!word) return;
        if (GuestIsHostObject(word)) {
            value = (__bridge CFTypeRef)GuestObjCUnwrap(vm, word);
        } else if (void *opaque = HLEUnwrapOpaque(vm, word)) {
            value = (CFTypeRef)opaque;
        } else if (NSString *text = GuestObjCCFString(vm, word)) {
            value = (__bridge_retained CFTypeRef)text;
            temporary = true;
        }
    }
    ~GuestCFArg() { if (temporary && value) CFRelease(value); }
    GuestCFArg(const GuestCFArg &) = delete;
    GuestCFArg &operator=(const GuestCFArg &) = delete;
};

static void CFFault(GuestVM *vm, const char *name) {
    GuestTrace(vm, @"[cf] %s received an invalid guest pointer or callback table (lr=%#x)", name, GuestLR(vm));
    GuestSetRet(vm, 0);
    GuestRequestFault(vm);
}

static gva_t WrapCFProperty(GuestVM *vm, CFTypeRef value) {
    // Values obtained from a CFBundle info dictionary or the original audio
    // route dictionary are toll-free property-list objects, usable by ObjC too.
    return value ? GuestObjCWrap(vm, (__bridge id)value) : 0;
}

static void *CFArrayCallback(GuestVM *vm, gva_t word, int field, bool &valid) {
    (void)field;
    if (!word) return nullptr;
    if (void *host = HLEUnwrapOpaque(vm, word)) return host;
    // An original function identity is not a host CF callback pointer. It needs
    // an offline-generated typed native callback adapter. Never inspect old
    // instruction bytes or guess callback semantics from their encoding.
    GuestTrace(vm, @"[native] CF array callback %#x lacks a generated native ABI adapter", word);
    valid = false;
    return nullptr;
}

// Data imports are read by the guest CPU before any CF function is called.
// Copy the 32-bit layout; host callback addresses become opaque tokens that
// CFArrayCreateMutable below translates back into real host function pointers.
BOOL GuestCFDataValue(GuestVM *vm, const char *symbol, uint32_t *out) {
    if (!vm || !symbol || !out) return NO;
    if (strcmp(symbol, "_kCFTypeArrayCallBacks") && strcmp(symbol, "_kCFAllocatorDefault")) return NO;
    static std::unordered_map<void *, std::unordered_map<std::string, gva_t>> data;
    auto &cache = data[(__bridge void *)vm];
    auto found = cache.find(symbol);
    if (found != cache.end()) { *out = found->second; return YES; }
    gva_t address;
    if (!strcmp(symbol, "_kCFAllocatorDefault")) {
        address = GuestAlloc(vm, 4);
        if (!address) return NO;
        GuestWriteU32(vm, address, 0);
    } else {
        uint32_t words[5] = {0,
            HLEWrapOpaque(vm, reinterpret_cast<void *>(kCFTypeArrayCallBacks.retain)),
            HLEWrapOpaque(vm, reinterpret_cast<void *>(kCFTypeArrayCallBacks.release)),
            HLEWrapOpaque(vm, reinterpret_cast<void *>(kCFTypeArrayCallBacks.copyDescription)),
            HLEWrapOpaque(vm, reinterpret_cast<void *>(kCFTypeArrayCallBacks.equal))};
        address = GuestAlloc(vm, sizeof(words));
        if (!address || !GuestWrite(vm, address, words, sizeof(words))) return NO;
    }
    cache[symbol] = address;
    *out = address;
    return YES;
}

HLE_DEFINE(hle_CFArrayCreateMutable) {
    gva_t allocatorWord = GuestArg(vm, 0), callbacksWord = GuestArg(vm, 2);
    CFAllocatorRef allocator = nullptr;
    if (allocatorWord) {
        void *pointer = HLEUnwrapOpaque(vm, allocatorWord);
        if (pointer && pointer == HLEHostSymbol("_kCFAllocatorDefault")) allocator = kCFAllocatorDefault;
        else if (pointer) allocator = (CFAllocatorRef)pointer;
        else { CFFault(vm, "CFArrayCreateMutable allocator"); return; }
    }
    const CFArrayCallBacks *callbacks = nullptr;
    CFArrayCallBacks rawCallbacks = {};
    if (callbacksWord) {
        void *pointer = HLEUnwrapOpaque(vm, callbacksWord);
        if (pointer && (pointer == &kCFTypeArrayCallBacks || pointer == HLEHostSymbol("_kCFTypeArrayCallBacks"))) {
            callbacks = &kCFTypeArrayCallBacks;
        } else {
            uint32_t words[5];
            if (!GuestRead(vm, callbacksWord, words, sizeof(words)) || words[0]) {
                CFFault(vm, "CFArrayCreateMutable callbacks"); return;
            }
            const auto fixed = as6cf::prepare(vm, allocatorWord, words, rawCallbacks);
            if (fixed == as6cf::TableResult::Rejected) { CFFault(vm, "CFArrayCreateMutable fixed callbacks"); return; }
            bool valid = true;
            if (fixed == as6cf::TableResult::Unrelated) {
            rawCallbacks.retain = reinterpret_cast<CFArrayRetainCallBack>(CFArrayCallback(vm, words[1], 1, valid));
            rawCallbacks.release = reinterpret_cast<CFArrayReleaseCallBack>(CFArrayCallback(vm, words[2], 2, valid));
            rawCallbacks.copyDescription = reinterpret_cast<CFArrayCopyDescriptionCallBack>(CFArrayCallback(vm, words[3], 3, valid));
            rawCallbacks.equal = reinterpret_cast<CFArrayEqualCallBack>(CFArrayCallback(vm, words[4], 4, valid));
            }
            if (!valid) { CFFault(vm, "CFArrayCreateMutable callbacks"); return; }
            callbacks = &rawCallbacks;
        }
    }
    CFIndex capacity = (int32_t)GuestArg(vm, 1);
    if (capacity < 0) { CFFault(vm, "CFArrayCreateMutable capacity"); return; }
    CFMutableArrayRef array = CFArrayCreateMutable(allocator, capacity, callbacks);
    // Preserve the Create ownership until the guest calls CFRelease. The ObjC
    // handle table separately owns its stable reference for mixed CF/ObjC use.
    GuestSetRet(vm, WrapCFProperty(vm, array));
}
HLE_BIND("_CFArrayCreateMutable", hle_CFArrayCreateMutable)

HLE_DEFINE(hle_CFBundleGetMainBundle) {
    GuestSetRet(vm, HLEWrapOpaque(vm, (void *)CFBundleGetMainBundle()));
}
HLE_BIND("_CFBundleGetMainBundle", hle_CFBundleGetMainBundle)

HLE_DEFINE(hle_CFBundleGetValueForInfoDictionaryKey) {
    GuestCFArg bundle(vm, GuestArg(vm, 0)), key(vm, GuestArg(vm, 1));
    CFTypeRef value = bundle.value && key.value
        ? CFBundleGetValueForInfoDictionaryKey((CFBundleRef)bundle.value, (CFStringRef)key.value) : nullptr;
    GuestSetRet(vm, WrapCFProperty(vm, value));
}
HLE_BIND("_CFBundleGetValueForInfoDictionaryKey", hle_CFBundleGetValueForInfoDictionaryKey)

HLE_DEFINE(hle_CFDictionaryGetValue) {
    GuestCFArg dictionary(vm, GuestArg(vm, 0)), key(vm, GuestArg(vm, 1));
    const void *value = dictionary.value && key.value
        ? CFDictionaryGetValue((CFDictionaryRef)dictionary.value, key.value) : nullptr;
    GuestSetRet(vm, WrapCFProperty(vm, (CFTypeRef)value));
}
HLE_BIND("_CFDictionaryGetValue", hle_CFDictionaryGetValue)

HLE_DEFINE(hle_CFNumberGetValue) {
    GuestCFArg number(vm, GuestArg(vm, 0));
    uint32_t requested = GuestArg(vm, 1);
    gva_t destination = GuestArg(vm, 2);
    if (!number.value || !destination) { GuestSetRet(vm, 0); return; }
    CFNumberType hostType;
    size_t bytes;
    switch (requested) {
        case kCFNumberSInt8Type: case kCFNumberCharType:
            hostType = kCFNumberSInt8Type; bytes = 1; break;
        case kCFNumberSInt16Type: case kCFNumberShortType:
            hostType = kCFNumberSInt16Type; bytes = 2; break;
        case kCFNumberSInt32Type: case kCFNumberIntType: case kCFNumberLongType:
        case kCFNumberCFIndexType: case kCFNumberNSIntegerType:
            hostType = kCFNumberSInt32Type; bytes = 4; break;
        case kCFNumberSInt64Type: case kCFNumberLongLongType:
            hostType = kCFNumberSInt64Type; bytes = 8; break;
        case kCFNumberFloat32Type: case kCFNumberFloatType: case kCFNumberCGFloatType:
            hostType = kCFNumberFloat32Type; bytes = 4; break;
        case kCFNumberFloat64Type: case kCFNumberDoubleType:
            hostType = kCFNumberFloat64Type; bytes = 8; break;
        default: GuestSetRet(vm, 0); return;
    }
    if ((uint64_t)destination + bytes > (1ull << 32)) { CFFault(vm, "CFNumberGetValue destination"); return; }
    alignas(16) uint8_t value[16] = {};
    Boolean result = CFNumberGetValue((CFNumberRef)number.value, hostType, value);
    if (!GuestWrite(vm, destination, value, bytes)) { CFFault(vm, "CFNumberGetValue destination"); return; }
    GuestSetRet(vm, result ? 1 : 0);
}
HLE_BIND("_CFNumberGetValue", hle_CFNumberGetValue)

HLE_DEFINE(hle_CFRelease) {
    gva_t word = GuestArg(vm, 0);
    // Original __cfstring constants are immortal. The host decoding is merely
    // a temporary view and must not be released as though the guest created it.
    if (!word || GuestSectionContains(vm, "__cfstring", word)) return;
    GuestCFArg object(vm, word);
    if (object.value) CFRelease(object.value);
}
HLE_BIND("_CFRelease", hle_CFRelease)

HLE_DEFINE(hle_CFRunLoopGetCurrent) {
    GuestSetRet(vm, HLEWrapOpaque(vm, (void *)CFRunLoopGetCurrent()));
}
HLE_BIND("_CFRunLoopGetCurrent", hle_CFRunLoopGetCurrent)

HLE_DEFINE(hle_CFRunLoopRunInMode) {
    GuestCFArg mode(vm, GuestArg(vm, 0));
    // Darwin armv7: mode=r0, double's low/high words=r1/r2, Boolean=r3.
    // GuestArgD uses double-ordinal indexing, so decode this mixed signature.
    uint64_t bits = GuestArg(vm, 1) | ((uint64_t)GuestArg(vm, 2) << 32);
    double seconds;
    memcpy(&seconds, &bits, sizeof(seconds));
    Boolean returnAfterSource = GuestArg(vm, 3) != 0;
    if (!mode.value) { CFFault(vm, "CFRunLoopRunInMode mode"); return; }
    SInt32 result = CFRunLoopRunInMode((CFStringRef)mode.value, seconds, returnAfterSource);
    GuestSetRet(vm, (uint32_t)result);
}
HLE_BIND("_CFRunLoopRunInMode", hle_CFRunLoopRunInMode)
