// Darwin armv7 wchar_t is a signed 32-bit code unit. The original game stores
// UTF-32LE strings and inlines pointer arithmetic with a four-byte stride.
// These imports must operate on guest memory, never host-dereference its VA.
#import "HLE.h"
#import "GuestVM.h"

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstdint>
#include <cstring>
#include <cwchar>
#include <string>
#include <vector>

static_assert(sizeof(wchar_t) == 4 && (wchar_t)-1 < 0,
              "the Darwin host and guest wide-code-unit ABI must agree");
static constexpr uint64_t kGuestAddressEnd = 1ull << 32;

static void WideFault(GuestVM *vm, const char *symbol) {
    GuestTrace(vm, @"[wchar] %s accessed invalid guest memory (lr=%#x)", symbol, GuestLR(vm));
    GuestSetRet(vm, UINT32_MAX);
    GuestRequestHalt(vm);
}

static bool WideUnit(GuestVM *vm, gva_t src, uint32_t index, uint32_t &value) {
    uint64_t address = (uint64_t)src + (uint64_t)index * 4;
    return src && address + 4 <= kGuestAddressEnd && GuestRead(vm, (gva_t)address, &value, 4);
}

static bool WideLength(GuestVM *vm, gva_t src, uint32_t &length) {
    for (uint32_t i = 0;; i++) {
        uint32_t value;
        if (!WideUnit(vm, src, i, value)) return false;
        if (!value) { length = i; return true; }
    }
}

static bool WideRead(GuestVM *vm, gva_t src, std::wstring &out,
                     uint32_t limit = UINT32_MAX) {
    out.clear();
    for (uint32_t i = 0; i < limit; i++) {
        uint32_t value;
        if (!WideUnit(vm, src, i, value)) return false;
        if (!value) return true;
        out.push_back((wchar_t)(int32_t)value);
    }
    return true;
}

static bool WideCopy(GuestVM *vm, gva_t dst, gva_t src, uint32_t count) {
    uint64_t bytes = (uint64_t)count * 4;
    if (!bytes) return true;
    if (!dst || !src || (uint64_t)dst + bytes > kGuestAddressEnd ||
        (uint64_t)src + bytes > kGuestAddressEnd) return false;
    uint8_t buffer[4096];
    // Copy backwards for overlapping right shifts, including across chunks.
    bool backwards = dst > src && dst < (uint64_t)src + bytes;
    uint64_t done = 0;
    while (done < bytes) {
        size_t take = (size_t)std::min<uint64_t>(sizeof(buffer), bytes - done);
        uint64_t offset = backwards ? bytes - done - take : done;
        if (!GuestRead(vm, src + (uint32_t)offset, buffer, take) ||
            !GuestWrite(vm, dst + (uint32_t)offset, buffer, take)) return false;
        done += take;
    }
    return true;
}

HLE_DEFINE(hle_wcslen) {
    uint32_t length;
    if (!WideLength(vm, GuestArg(vm, 0), length)) { WideFault(vm, "wcslen"); return; }
    GuestSetRet(vm, length);
}
HLE_BIND("_wcslen", hle_wcslen)

HLE_DEFINE(hle_wcscpy) {
    gva_t dst = GuestArg(vm, 0), src = GuestArg(vm, 1);
    uint32_t length;
    if (!WideLength(vm, src, length) || !WideCopy(vm, dst, src, length + 1)) {
        WideFault(vm, "wcscpy"); return;
    }
    GuestSetRet(vm, dst);
}
HLE_BIND("_wcscpy", hle_wcscpy)

HLE_DEFINE(hle_wcscmp) {
    gva_t a = GuestArg(vm, 0), b = GuestArg(vm, 1);
    for (uint32_t i = 0;; i++) {
        uint32_t av, bv;
        if (!WideUnit(vm, a, i, av) || !WideUnit(vm, b, i, bv)) {
            WideFault(vm, "wcscmp"); return;
        }
        if (av != bv) { GuestSetRet(vm, (int32_t)av < (int32_t)bv ? UINT32_MAX : 1); return; }
        if (!av) { GuestSetRet(vm, 0); return; }
    }
}
HLE_BIND("_wcscmp", hle_wcscmp)

HLE_DEFINE(hle_wmemcmp) {
    gva_t a = GuestArg(vm, 0), b = GuestArg(vm, 1);
    uint32_t count = GuestArg(vm, 2);
    for (uint32_t i = 0; i < count; i++) {
        uint32_t av, bv;
        if (!WideUnit(vm, a, i, av) || !WideUnit(vm, b, i, bv)) {
            WideFault(vm, "wmemcmp"); return;
        }
        if (av != bv) { GuestSetRet(vm, (int32_t)av < (int32_t)bv ? UINT32_MAX : 1); return; }
    }
    GuestSetRet(vm, 0);
}
HLE_BIND("_wmemcmp", hle_wmemcmp)

HLE_DEFINE(hle_wmemchr) {
    gva_t src = GuestArg(vm, 0);
    uint32_t wanted = GuestArg(vm, 1), count = GuestArg(vm, 2);
    for (uint32_t i = 0; i < count; i++) {
        uint32_t value;
        if (!WideUnit(vm, src, i, value)) { WideFault(vm, "wmemchr"); return; }
        if (value == wanted) { GuestSetRet(vm, src + i * 4); return; }
    }
    GuestSetRet(vm, 0);
}
HLE_BIND("_wmemchr", hle_wmemchr)

HLE_DEFINE(hle_wmemcpy) {
    gva_t dst = GuestArg(vm, 0);
    if (!WideCopy(vm, dst, GuestArg(vm, 1), GuestArg(vm, 2))) {
        WideFault(vm, "wmemcpy/wmemmove"); return;
    }
    GuestSetRet(vm, dst);
}
HLE_BIND("_wmemcpy", hle_wmemcpy)
HLE_BIND("_wmemmove", hle_wmemcpy)

// Format one conversion at a time after copying every pointed-to argument out
// of guest memory. Darwin armv7 varargs are consecutive 32-bit words: even a
// double can begin in r3 and continue in the first stack word (original
// swprintf call at 0x42faa8). No host va_list can represent those guest words.
static bool WideFormat(GuestVM *vm, const std::wstring &format,
                       uint32_t capacity, std::wstring &out) {
    int arg = 3;
    auto Word = [&]() { return GuestArg(vm, arg++); };
    auto Pair = [&]() { uint64_t lo = Word(); return lo | ((uint64_t)Word() << 32); };
    for (size_t i = 0; i < format.size();) {
        if (format[i] != L'%') { out.push_back(format[i++]); continue; }
        i++;
        if (i == format.size()) return false;
        if (format[i] == L'%') { out.push_back(L'%'); i++; continue; }
        std::wstring spec = L"%";
        bool left = false;
        while (i < format.size() && std::wcschr(L"-+ #0'", format[i])) {
            if (format[i] == L'-') left = true;
            spec.push_back(format[i++]);
        }
        int width = 0;
        if (i < format.size() && format[i] == L'*') {
            int32_t requested = (int32_t)Word();
            if (requested == INT_MIN) return false;
            left = left || requested < 0;
            width = requested < 0 ? -requested : requested;
            spec += std::to_wstring(requested);
            i++;
        } else {
            while (i < format.size() && format[i] >= L'0' && format[i] <= L'9') {
                if (width > (INT_MAX - 9) / 10) return false;
                width = width * 10 + (format[i] - L'0');
                spec.push_back(format[i++]);
            }
        }
        int precision = -1;
        if (i < format.size() && format[i] == L'.') {
            i++;
            if (i < format.size() && format[i] == L'*') { precision = (int32_t)Word(); i++; }
            else {
                precision = 0;
                while (i < format.size() && format[i] >= L'0' && format[i] <= L'9') {
                    if (precision > (INT_MAX - 9) / 10) return false;
                    precision = precision * 10 + (format[i++] - L'0');
                }
            }
            if (precision >= 0) spec += L"." + std::to_wstring(precision);
        }
        wchar_t length = 0;
        bool twice = false;
        if (i < format.size() && std::wcschr(L"hlqjztL", format[i])) {
            length = format[i++];
            if (i < format.size() && format[i] == length && (length == L'h' || length == L'l')) {
                twice = true; i++;
            }
        }
        if (i == format.size()) return false;
        wchar_t conversion = format[i++];
        bool integer = std::wcschr(L"diuoxX", conversion) != nullptr;
        bool wideInteger = (length == L'l' && twice) || length == L'q' || length == L'j';
        bool wideString = conversion == L'S' || length == L'l';
        if (integer) {
            if (wideInteger) spec += L"ll";
            else if (length == L'h') spec += twice ? L"hh" : L"h";
        } else if ((conversion == L's' || conversion == L'c' || conversion == L'S' || conversion == L'C') &&
                   (wideString || conversion == L'C')) spec += L"l";
        if (conversion == L'S') conversion = L's';
        if (conversion == L'C') conversion = L'c';
        spec.push_back(conversion);
        // Wide strings and characters already contain the original UTF-32
        // units. Copy them directly: routing them through the host's locale
        // conversion can reject perfectly valid original game text.
        auto AppendText = [&](const std::wstring &value) -> bool {
            size_t padding = (size_t)width > value.size() ? (size_t)width - value.size() : 0;
            if (out.size() + value.size() + padding >= capacity) return false;
            if (!left) out.append(padding, L' ');
            out.append(value);
            if (left) out.append(padding, L' ');
            return true;
        };
        auto Append = [&](auto value) -> bool {
            size_t maximum = (size_t)capacity + 1;
            size_t size = std::min<size_t>(128, maximum);
            if (!size) return false;
            for (;;) {
                std::vector<wchar_t> buffer(size);
                errno = 0;
                int count = std::swprintf(buffer.data(), buffer.size(), spec.c_str(), value);
                if (count >= 0) { out.append(buffer.data(), (size_t)count); return true; }
                if (errno == EILSEQ || errno == EINVAL || size == maximum) return false;
                size = std::min(maximum, size * 2);
            }
        };
        bool ok = true;
        if (conversion == L's') {
            gva_t address = Word();
            std::wstring text;
            if (wideString) {
                text = L"(null)";
                if (address && !WideRead(vm, address, text, precision >= 0 ? (uint32_t)precision : UINT32_MAX)) {
                    WideFault(vm, "swprintf wide argument"); return false;
                }
                if (precision >= 0 && text.size() > (size_t)precision) text.resize((size_t)precision);
            } else {
                std::string bytes = "(null)";
                if (address) {
                    size_t count = GuestStrLen(vm, address, UINT32_MAX - address);
                    bytes.resize(count);
                    uint8_t nul = 1;
                    if ((count && !GuestRead(vm, address, bytes.data(), count)) ||
                        !GuestRead(vm, address + (uint32_t)count, &nul, 1) || nul) {
                        WideFault(vm, "swprintf narrow argument"); return false;
                    }
                }
                std::mbstate_t state = {};
                for (size_t offset = 0; offset < bytes.size() &&
                     (precision < 0 || text.size() < (size_t)precision);) {
                    wchar_t unit;
                    size_t consumed = std::mbrtowc(&unit, bytes.data() + offset, bytes.size() - offset, &state);
                    if (consumed == (size_t)-1 || consumed == (size_t)-2) return false;
                    if (!consumed) break;
                    text.push_back(unit);
                    offset += consumed;
                }
            }
            ok = AppendText(text);
        } else if (conversion == L'c') {
            uint32_t code = Word();
            wint_t unit = wideString || spec.find(L"lc") != std::wstring::npos
                              ? (wint_t)code : std::btowc((int)(unsigned char)code);
            ok = unit != WEOF && AppendText(std::wstring(1, (wchar_t)unit));
        } else if (conversion == L'p') {
            ok = Append((void *)(uintptr_t)Word()); // numeric rendering only
        } else if (integer) {
            if (conversion == L'd' || conversion == L'i')
                ok = wideInteger ? Append((long long)Pair()) : Append((int32_t)Word());
            else ok = wideInteger ? Append((unsigned long long)Pair()) : Append(Word());
        } else if (std::wcschr(L"fFeEgGaA", conversion)) {
            uint64_t bits = Pair();
            double value;
            memcpy(&value, &bits, sizeof(value));
            ok = Append(value); // guest long double is also 64 bits
        } else if (conversion == L'n') {
            gva_t address = Word();
            uint64_t count = out.size();
            size_t bytes = wideInteger ? 8 : length == L'h' ? (twice ? 1 : 2) : 4;
            if (!address || !GuestWrite(vm, address, &count, bytes)) {
                WideFault(vm, "swprintf count argument"); return false;
            }
        } else return false;
        if (!ok) return false;
    }
    return true;
}

HLE_DEFINE(hle_swprintf) { // (wide_dst r0, capacity_in_wchars r1, wide_format r2, ...)
    gva_t dst = GuestArg(vm, 0), format = GuestArg(vm, 2);
    uint32_t capacity = GuestArg(vm, 1);
    if (!dst || !capacity || (uint64_t)dst + (uint64_t)capacity * 4 > kGuestAddressEnd) {
        GuestSetRet(vm, UINT32_MAX); return;
    }
    std::wstring fmt, text;
    if (!WideRead(vm, format, fmt)) { WideFault(vm, "swprintf format"); return; }
    bool complete = WideFormat(vm, fmt, capacity, text);
    size_t take = std::min<size_t>(text.size(), capacity - 1);
    uint32_t nul = 0;
    if ((take && !GuestWrite(vm, dst, text.data(), take * 4)) ||
        !GuestWrite(vm, dst + (uint32_t)take * 4, &nul, 4)) {
        WideFault(vm, "swprintf destination"); return;
    }
    GuestSetRet(vm, complete && text.size() < capacity ? (uint32_t)text.size() : UINT32_MAX);
}
HLE_BIND("_swprintf", hle_swprintf)
