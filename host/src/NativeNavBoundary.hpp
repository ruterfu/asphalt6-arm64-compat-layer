#pragma once
#include "native_program.hpp"
namespace as6_nav_boundary {
constexpr std::uint32_t Entry=0x18320c,LastInstruction=0x18358c;
bool shouldSuspend(as6aot::Context &,std::uint32_t,bool) noexcept;
bool arm(as6aot::Context &) noexcept;
void cancel(as6aot::Context &) noexcept;
bool pending(const as6aot::Context &) noexcept;
bool isBoundary(const as6aot::Context &) noexcept;
}
