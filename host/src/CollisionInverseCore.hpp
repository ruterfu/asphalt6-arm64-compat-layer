#pragma once
#include "GuestNativeCore.hpp"
#include <atomic>

namespace as6_collision_inverse {
inline constexpr std::uint32_t Entry=0x1b2020u,LastInstruction=0x1b238cu;
inline constexpr std::uint32_t SmallExit=0x1b1e38u,InverseExit=0x1b2390u;
inline constexpr std::uint32_t ThresholdAddress=0x1b23f0u,ThresholdWord=0x358637bdu;
enum class Decision:std::uint8_t {Original,Handled};
enum class Reason:std::uint8_t {
    InvalidContext,BudgetMismatch,StopInside,InsufficientBudget,UnsupportedLayout,
    LiteralAlias,ReadFailure,ThresholdChanged,KernelFailure,PublicationRejected,
    WorkspaceBusy,ExceptionBeforePublication,Complete
};
struct Result {
    Decision decision=Decision::Original;
    Reason reason=Reason::InvalidContext;
    std::uint64_t instructions=0;
    std::uint32_t writes=0,nativeOperations=0,softwareOperations=0;
};
class Workspace;
Result queryDirect(as6native::Core &,as6aot::Context &,Workspace &,
                   std::uint64_t,std::uint32_t,bool) noexcept;
// An owned, reentry-excluded query. No guest pointer or worker callback is
// retained; all architectural and data effects publish under one Core lease.
class Workspace {
    std::atomic_flag busy_=ATOMIC_FLAG_INIT;
    friend Result queryDirect(as6native::Core &,as6aot::Context &,Workspace &,
                              std::uint64_t,std::uint32_t,bool) noexcept;
public:
    Workspace()=default;
    Workspace(const Workspace&)=delete;
    Workspace &operator=(const Workspace&)=delete;
};
}
