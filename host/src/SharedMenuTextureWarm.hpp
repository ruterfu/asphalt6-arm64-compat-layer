#pragma once
// Isolated proposal: no production integration, no app run.
#import "GuestVM.h"
#import "GuestObjC.h"
#import <UIKit/UIKit.h>
#import <OpenGLES/EAGL.h>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstring>

extern "C" gva_t GuestGLView(void);
extern "C" BOOL GuestDiagnosticSnapshotLockHeld(GuestVM *);

namespace as6_shared_menu_warm {
// These are the five bitmap exports of shared main_menu_2d_hud.swf (file58).
// All original post-title destinations5/6/7 use movie slot7. Let the original
// SwfTextureLoader choose the actual file/_hires variant and cache key.
constexpr const char *kNames[] = {"MenuHud.tga", "GLLive.tga", "company_logos.tga", "CarSelect.tga", "AsphaltStore.tga"};
struct State {
    __weak GuestVM *owner = nil;
    gva_t manager = 0;
    std::array<gva_t, 5> pins{};
    bool attempted = false, released = false, busy = false;
};
inline bool original(GuestVM *vm, gva_t function, const uint32_t *arguments, int count, uint32_t &result) {
    result = GuestCall(vm, function, arguments, count, 100000000);
    return GuestLastExecutionResult(vm) == GuestExecutionSuccess && !GuestHasStopRequest(vm);
}
inline bool cacheContains(GuestVM *vm, gva_t manager, gva_t texture) {
    const auto begin = GuestReadU32(vm, manager + 0x18), end = GuestReadU32(vm, manager + 0x1c);
    if (!begin || end < begin || (end - begin) % 8 || end - begin > 8 * 8192) return false;
    for (gva_t p = begin; p < end; p += 8) if (GuestReadU32(vm, p) == texture) return true;
    return false;
}
// Exact original intrusive-pointer semantics, under the VM lock/main thread.
// ITexture reference count is +4 (SwfTextureLoader5a7e0..5a7ec;
// TextureManager cleanup50d17c..50d18c). No cache table is edited.
inline bool retainPin(GuestVM *vm, gva_t texture) {
    uint32_t count = 0;
    if (!GuestRead(vm, texture + 4, &count, 4) || !count || count >= 0x7ffffffeu) return false;
    ++count; return GuestWrite(vm, texture + 4, &count, 4);
}
inline bool releasePinWithCacheOwner(GuestVM *vm, gva_t manager, gva_t texture) {
    if (!cacheContains(vm, manager, texture)) return false;
    uint32_t count = 0;
    if (!GuestRead(vm, texture + 4, &count, 4) || count < 2 || count >= 0x7fffffffu) return false;
    --count; return GuestWrite(vm, texture + 4, &count, 4);
}

// Proposed narrow call after GuestObjCSend decoded SEL and before dispatching
// the current EAGLView's drawView. The original event pump also sends this SEL.
inline bool beforeMessage(GuestVM *vm, gva_t receiver, SEL selector, State &state) {
    if (receiver != GuestGLView() || !selector || strcmp(sel_getName(selector), "drawView")) return true;
    if (state.owner != vm) { state.owner = vm; state.manager = 0; state.pins = {}; state.attempted = state.released = state.busy = false; }
    // Completed/disabled warming has no further original calls or memory reads.
    if (state.released) return true;
    if (GuestHasStopRequest(vm)) return false;
    // GuestDiagnosticSnapshotLockHeld is exactly VM-lock-held && nativeDepth0
    // in GuestVM.mm. An unavailable optional warm boundary is a soft skip.
    if (state.busy || !NSThread.isMainThread || !GuestDiagnosticSnapshotLockHeld(vm)) return true;
    // App must already have completed its initial CreateInstance; no singleton
    // is constructed by this optimization. Startup movies remain untouched.
    const auto applicationSlot = GuestReadU32(vm, 0x700bec);
    if (!applicationSlot || !GuestReadU32(vm, applicationSlot) || GuestReadU32(vm, receiver + 0x60) != 5) return true;
    const auto stret = GuestStretDestination();
    bool warmStarted = false, warmCompleted = false;
    std::chrono::steady_clock::time_point warmStart;
    state.busy = true;
    @try {
        uint32_t stack = 0, device = 0;
        if (!original(vm, 0x15330, nullptr, 0, stack)) return false;
        if (!stack) return true;
        if (!original(vm, 0x14570, nullptr, 0, device)) return false;
        if (!device) return true;
        const auto menu = GuestReadU32(vm, stack + 0x64);
        const auto driver = GuestReadU32(vm, device + 0x10);
        const auto manager = driver ? GuestReadU32(vm, driver + 0xbc) : 0;
        if (!manager) return true;
        if (state.attempted) {
            if (state.released || menu == 4 || manager != state.manager) return true;
            uint32_t swf = 0, hud = 0;
            if (!original(vm, 0x16538, nullptr, 0, swf)) return false;
            if (!swf) return true;
            const uint32_t args[] = {swf, 7};
            if (!original(vm, 0x56100, args, 2, hud)) return false;
            uint8_t active = 0;
            if (!hud || !GuestRead(vm, hud + 0x124, &active, 1) || !active || !GuestReadU32(vm, hud + 0x3c)) return true;
            unsigned released = 0, held = 0;
            for (auto &texture : state.pins) if (texture) {
                const auto before = GuestReadU32(vm, texture + 4);
                const auto address = texture;
                const bool didRelease = releasePinWithCacheOwner(vm, manager, texture);
                const auto after = GuestReadU32(vm, texture + 4);
                char line[192];
                snprintf(line, sizeof(line), "[shared-menu-warm] release texture=%#x refs=%u->%u cache-owner=%d", address, before, after, int(didRelease));
                GuestRawLog(line);
                if (didRelease) { texture = 0; ++released; } else ++held;
            }
            state.released = true;
            char line[160];
            snprintf(line, sizeof(line), "[shared-menu-warm] real HUD7 active; released=%u retained-until-VM-teardown=%u", released, held);
            GuestRawLog(line);
            return !GuestHasStopRequest(vm);
        }
        if (menu != 4) return true;
        uint32_t overwrite = 0;
        if (!original(vm, 0x1c3f88, nullptr, 0, overwrite)) return false;
        if (overwrite) return true; // Loader otherwise substitutes track-loading textures.
        id contextObject = GuestObjCUnwrap(vm, GuestReadU32(vm, receiver + 0x34));
        // Never switch contexts for an optional optimization. In the normal
        // title render path the original Game context is already current.
        if (![contextObject isKindOfClass:EAGLContext.class] || EAGLContext.currentContext != contextObject) {
            state.attempted = state.released = true;
            GuestRawLog("[shared-menu-warm] skipped: original Game EAGLContext is not current");
            return !GuestHasStopRequest(vm);
        }
        state.attempted = true; state.manager = manager;
        warmStarted = true; warmStart = std::chrono::steady_clock::now();
        char begin[160];
        snprintf(begin, sizeof(begin), "[shared-menu-warm] begin menu=4 manager=%#x textures=5", manager);
        GuestRawLog(begin);
        unsigned retained = 0;
        for (unsigned i = 0; i < state.pins.size(); ++i) {
            const auto name = GuestWriteCString(vm, @(kNames[i]));
            if (!name) {
                GuestRawLog("[shared-menu-warm] optional string allocation unavailable; skipping remaining textures");
                if (GuestHasStopRequest(vm)) return false;
                break;
            }
            const uint32_t args[] = {name, 0, 0};
            uint32_t texture = 0;
            if (!original(vm, 0x5a44c, args, 3, texture)) return false;
            if (!texture || !cacheContains(vm, manager, texture)) {
                char line[160];
                snprintf(line, sizeof(line), "[shared-menu-warm] skipped name=%s texture=%#x cache-miss=1", kNames[i], texture);
                GuestRawLog(line);
                if (GuestHasStopRequest(vm)) return false;
                continue;
            }
            bool duplicate = false;
            for (unsigned j = 0; j < i; ++j) if (state.pins[j] == texture) duplicate = true;
            const auto before = GuestReadU32(vm, texture + 4);
            const bool pinned = !duplicate && retainPin(vm, texture);
            const auto after = GuestReadU32(vm, texture + 4);
            if (pinned) { state.pins[i] = texture; ++retained; }
            char line[224];
            snprintf(line, sizeof(line), "[shared-menu-warm] pin name=%s texture=%#x refs=%u->%u retained=%d duplicate=%d", kNames[i], texture, before, after, int(pinned), int(duplicate));
            GuestRawLog(line);
            if (GuestHasStopRequest(vm)) return false;
        }
        char line[160];
        snprintf(line, sizeof(line), "[shared-menu-warm] title menu4 retained=%u/5 shared HUD7 textures; no SWF instance/advance", retained);
        GuestRawLog(line);
        if (!retained) state.released = true;
        warmCompleted = true;
    } @finally {
        if (warmStarted) {
            const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - warmStart).count();
            char line[160];
            snprintf(line, sizeof(line), "[shared-menu-warm] end completed=%d elapsed_ms=%.3f", int(warmCompleted), double(elapsed) / 1000.);
            GuestRawLog(line);
        }
        GuestSetStretDestination(stret);
        state.busy = false;
    }
    return !GuestHasStopRequest(vm);
}
}
