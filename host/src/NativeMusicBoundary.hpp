#pragma once
#include "native_program.hpp"
#include <cstdint>
#if defined(AS6_ORIGINAL_UI_ABSENCE_FIXTURE) && !defined(AS6_NATIVE_MUSIC_INTEGRATION_FIXTURE)
#include <TargetConditionals.h>
#if !TARGET_OS_OSX || !defined(AS6_MACOS_MOTION_ABSENCE_FIXTURE)
#error Music absence is restricted to existing explicitly selected Foundation-only macOS tests
#endif
#define AS6_NATIVE_MUSIC_ABSENCE_FIXTURE 1
#endif

namespace as6_music_boundary {
#if defined(AS6_NATIVE_MUSIC_ABSENCE_FIXTURE)
inline bool isBoundary(std::uint32_t,bool) noexcept { return false; }
inline bool arm(as6aot::Context &,std::uint32_t) noexcept { return false; }
inline void cancel(as6aot::Context &) noexcept {}
inline as6aot::NativeFunction lookup(std::uint32_t,bool) noexcept { return nullptr; }
#else
bool isBoundary(std::uint32_t pc,bool thumb) noexcept;
// Called after the original stop/ISA/zero-budget guards, before --budget/body.
bool shouldSuspend(as6aot::Context &context,std::uint32_t pc) noexcept;
// A Host decision to retain the original path may resume this exact entry once.
bool arm(as6aot::Context &context,std::uint32_t pc) noexcept;
void cancel(as6aot::Context &context) noexcept;
// Own every legal entry of each private shard, including internal continuations.
as6aot::NativeFunction lookup(std::uint32_t pc,bool thumb) noexcept;
#endif
}
