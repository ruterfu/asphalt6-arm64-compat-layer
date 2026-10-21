#pragma once
#include "GuestNativeProvider.hpp"

namespace as6_vertex_boundary {
constexpr std::uint32_t Entry=0x545abcu,LastInstruction=0x545b68u,Exit=0x545b6cu;
constexpr std::uint64_t InstructionsPerVertex=44;
class ImmutableLinkedProvider {
    friend const as6native::Provider *::AS6LinkedNativeProvider();
    ImmutableLinkedProvider() {}
};
const as6native::Provider *withVertices(const as6native::Provider *,ImmutableLinkedProvider);
// Called after the original stop/ISA/zero-budget checks, before --budget.
bool shouldSuspend(as6aot::Context &,std::uint32_t stop,bool stopThumb) noexcept;
bool isBoundary(const as6aot::Context &) noexcept;
bool arm(as6aot::Context &) noexcept;
void cancel(as6aot::Context &) noexcept;
bool stopInsideLoop(std::uint32_t stop,bool stopThumb) noexcept;
}
