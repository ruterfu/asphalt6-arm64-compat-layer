#pragma once
#include "native_program.hpp"
#if defined(AS6_ORIGINAL_UI_ABSENCE_FIXTURE)
#include <TargetConditionals.h>
#if !TARGET_OS_OSX || !defined(AS6_MACOS_MOTION_ABSENCE_FIXTURE)
#error Original UI absence is restricted to explicitly selected Foundation-only macOS tests
#endif
#endif

namespace as6_original_ui {
constexpr std::uint32_t Advance = 0x3231b4u;
constexpr std::uint32_t Touch = 0x323534u;
constexpr std::uint32_t Display = 0x32278cu;
// Real SWFUnLoad entry: every cached character is still owned here.
constexpr std::uint32_t Unload = 0x563c0u;
#if defined(AS6_ORIGINAL_UI_ABSENCE_FIXTURE)
inline bool isBoundary(std::uint32_t,bool) { return false; }
inline bool suppressed() { return false; }
struct Suppress {};
inline bool arm(as6aot::Context &,std::uint32_t) { return false; }
inline void cancel(as6aot::Context &) {}
inline as6aot::Status boundary(as6aot::Context &c,bool,std::uint32_t,bool) { return c.status=as6aot::InvalidState; }
#else
bool isBoundary(std::uint32_t pc, bool thumb);
bool suppressed();
struct Suppress {
    Suppress();
    ~Suppress();
    Suppress(const Suppress &) = delete;
    Suppress &operator=(const Suppress &) = delete;
};
// Only arm after returning to Host and completing the adapter. The token is
// tied to this CPU context and exact original PC, and is consumed once.
bool arm(as6aot::Context &ctx, std::uint32_t pc);
void cancel(as6aot::Context &ctx);
as6aot::Status boundary(as6aot::Context &, bool, std::uint32_t, bool);
#endif
}
