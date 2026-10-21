#pragma once
#include <array>
#include <cstdint>

namespace as6::collision::inverse_state {
inline constexpr std::uint32_t Entry=0x1b2020u;
inline constexpr std::uint32_t SmallExit=0x1b1e38u,InverseExit=0x1b2390u;
inline constexpr std::uint32_t EpsilonBits=0x358637bdu;
struct Input {
    std::array<std::uint32_t,16> matrix{};
    std::array<std::uint64_t,16> fp{}; // D0..D15, both lanes, arbitrary IEEE32.
    std::array<std::uint32_t,4> gpr{}; // r0..r3.
    std::uint32_t stackAddress=0,fpscr=0;
};
struct WriteEvent {
    std::uint16_t offset=0;
    std::uint8_t size=0;
    std::uint32_t value=0,fpscrAtWrite=0,originalPc=0;
};
enum class Status:std::uint8_t {Complete,UnsupportedEnvironment,BackendFailure};
struct Result {
    Status status=Status::UnsupportedEnvironment;
    std::uint32_t nextPc=Entry,originalInstructions=0;
    std::array<std::uint64_t,16> fp{};
    std::array<std::uint32_t,4> gpr{};
    std::uint32_t fpscr=0,apsrNzcv=0;
    std::array<WriteEvent,38> writes{};
    std::uint32_t writeCount=0,nativeOperations=0,softwareOperations=0;
};
// Owned numerical value kernel. No guest memory, register layout, Core,
// callback, dispatch, allocation, or borrowed storage. Input is never changed.
// All incoming upper lanes are modeled; no zero-upper-lane admission gate.
// The caller independently validates the original epsilon literal, budget,
// stops, memory permissions, aliases and ordered publication under its lease.
// Merge apsrNzcv into NG/ZR/CY/OV bytes; do not rewrite the raw cpsr container.
// GPR4..15 and D16..31 are untouched by the original block (PC is nextPc).
Result compute(const Input &,bool nativeFast=true) noexcept;
}
