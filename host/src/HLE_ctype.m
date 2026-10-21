// The original compiler inlines ctype through _DefaultRuneLocale. This is a
// Darwin32 data ABI, not an imported function: runetype begins at +0x34, while
// the arm64 host puts it at +0x3c because its two function pointers are wider.
#import "HLE.h"
#import "GuestVM.h"

#include <runetype.h>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <unordered_map>
#include <vector>

struct GuestRuneRange32 { int32_t count; gva_t ranges; };
struct GuestRuneEntry32 { int32_t minimum, maximum, map; gva_t types; };
struct GuestRuneClass32 { char name[14]; uint16_t padding; uint32_t mask; };
struct GuestRuneLocale32 {
    char magic[8], encoding[32];
    gva_t getRune, putRune; // host function pointers must never enter guest data
    int32_t invalidRune;
    uint32_t runetype[256];
    int32_t maplower[256], mapupper[256];
    GuestRuneRange32 runetypeExt, maplowerExt, mapupperExt;
    gva_t variable;
    int32_t variableLength, classCount;
    gva_t classes;
};
static_assert(_CACHED_RUNES == 256 && sizeof(__darwin_rune_t) == 4, "Darwin cached rune units");
static_assert(sizeof(GuestRuneEntry32) == 16 && sizeof(GuestRuneClass32) == 20, "Darwin32 rune records");
static_assert(offsetof(GuestRuneLocale32, getRune) == 0x28, "Darwin32 function slot");
static_assert(offsetof(GuestRuneLocale32, putRune) == 0x2c, "Darwin32 function slot");
static_assert(offsetof(GuestRuneLocale32, invalidRune) == 0x30, "Darwin32 invalid rune");
static_assert(offsetof(GuestRuneLocale32, runetype) == 0x34, "original inline classification offset");
static_assert(offsetof(GuestRuneLocale32, maplower) == 0x434, "Darwin32 lowercase table");
static_assert(offsetof(GuestRuneLocale32, mapupper) == 0x834, "Darwin32 uppercase table");
static_assert(sizeof(GuestRuneLocale32) == 0xc5c, "Darwin32 locale size");

static gva_t CopyRuneData(GuestVM *vm, const void *bytes, size_t count) {
    if (!bytes || !count) return 0;
    gva_t address = GuestAlloc(vm, count);
    return address && GuestWrite(vm, address, bytes, count) ? address : 0;
}

static bool CopyRuneRange(GuestVM *vm, const _RuneRange &source, GuestRuneRange32 &out) {
    out.count = source.__nranges;
    if (!out.count) return true;
    if (out.count < 0 || !source.__ranges) return false;
    std::vector<GuestRuneEntry32> entries((size_t)out.count);
    for (int i = 0; i < out.count; i++) {
        const _RuneEntry &entry = source.__ranges[i];
        entries[i].minimum = entry.__min;
        entries[i].maximum = entry.__max;
        entries[i].map = entry.__map;
        if (entry.__types) {
            int64_t count = (int64_t)entry.__max - entry.__min + 1;
            if (count <= 0 || count > UINT32_MAX / 4) return false;
            entries[i].types = CopyRuneData(vm, entry.__types, (size_t)count * 4);
            if (!entries[i].types) return false;
        }
    }
    out.ranges = CopyRuneData(vm, entries.data(), entries.size() * sizeof(entries[0]));
    return out.ranges != 0;
}

BOOL GuestCTypeDataValue(GuestVM *vm, const char *symbol, uint32_t *out) {
    if (!vm || !symbol || !out || strcmp(symbol, "__DefaultRuneLocale")) return NO;
    static std::unordered_map<void *, gva_t> locales;
    void *key = (__bridge void *)vm;
    auto found = locales.find(key);
    if (found != locales.end()) { *out = found->second; return YES; }

    const _RuneLocale &host = _DefaultRuneLocale;
    GuestRuneLocale32 guest = {};
    memcpy(guest.magic, host.__magic, sizeof(guest.magic));
    memcpy(guest.encoding, host.__encoding, sizeof(guest.encoding));
    guest.invalidRune = host.__invalid_rune;
    memcpy(guest.runetype, host.__runetype, sizeof(guest.runetype));
    memcpy(guest.maplower, host.__maplower, sizeof(guest.maplower));
    memcpy(guest.mapupper, host.__mapupper, sizeof(guest.mapupper));
    // These are data tables, not guesses about character classes or GL
    // versions. Preserve any extended data too, translating all data pointers.
    if (!CopyRuneRange(vm, host.__runetype_ext, guest.runetypeExt) ||
        !CopyRuneRange(vm, host.__maplower_ext, guest.maplowerExt) ||
        !CopyRuneRange(vm, host.__mapupper_ext, guest.mapupperExt)) return NO;
    guest.variableLength = host.__variable_len;
    if (guest.variableLength < 0) return NO;
    if (guest.variableLength) {
        guest.variable = CopyRuneData(vm, host.__variable, (size_t)guest.variableLength);
        if (!guest.variable) return NO;
    }
    guest.classCount = host.__ncharclasses;
    if (guest.classCount < 0) return NO;
    if (guest.classCount) {
        if (!host.__charclasses) return NO;
        std::vector<GuestRuneClass32> classes((size_t)guest.classCount);
        for (int i = 0; i < guest.classCount; i++) {
            memcpy(classes[i].name, host.__charclasses[i].__name, sizeof(classes[i].name));
            classes[i].mask = host.__charclasses[i].__mask;
        }
        guest.classes = CopyRuneData(vm, classes.data(), classes.size() * sizeof(classes[0]));
        if (!guest.classes) return NO;
    }
    gva_t address = CopyRuneData(vm, &guest, sizeof(guest));
    if (!address) return NO;
    locales[key] = address;
    *out = address;
    GuestTrace(vm, @"[ctype] copied host _DefaultRuneLocale into Darwin32 data at %#x (runetype +0x34)", address);
    return YES;
}
