#pragma once
#include "GuestNativeCore.hpp"
#include "SceneAffine.hpp"
#include <array>
#include <atomic>

namespace as6_scene_affine {
inline constexpr std::uint32_t Entry=0x4cacd8u,LastInstruction=0x4caf48u,Exit=0x4caf4cu;
inline constexpr std::uint64_t OriginalInstructions=157;
enum class Decision:std::uint8_t {Original,Handled};
enum class Reason:std::uint8_t {
    InvalidContext,BudgetMismatch,StopInside,InsufficientBudget,UnsupportedEnvironment,
    UnsupportedLayout,PermissionFailure,ReadFailure,KernelFailure,PublicationRejected,
    WorkspaceBusy,ExceptionBeforePublication,Complete
};
struct WriteEvent {
    std::uint32_t address=0,value=0;
    std::uint8_t width=0;
    std::array<std::uint8_t,4> bytes{};
};
struct Result {
    Decision decision=Decision::Original;
    Reason reason=Reason::InvalidContext;
    as6::scene::affine::Result computed;
    std::array<WriteEvent,17> writes{};
    std::size_t writeCount=0,overlayBytes=0,overlaySegments=0;
};
class Workspace;
Result queryDirect(as6native::Core &,as6aot::Context &,Workspace &,std::uint64_t sliceRemaining,
             std::uint32_t stop,bool stopThumb) noexcept;
// Fixed owned value storage. No heap allocation, resizing, guest pointer or
// borrowed Core span survives the queryDirect. Reuse is atomically excluded.
class Workspace {
    std::array<std::uint8_t,185> bytes_{};
    std::atomic_flag busy_=ATOMIC_FLAG_INIT;
    friend Result queryDirect(as6native::Core &,as6aot::Context &,Workspace &,std::uint64_t,std::uint32_t,bool) noexcept;
public:
    Workspace()=default;
    Workspace(const Workspace&)=delete;
    Workspace&operator=(const Workspace&)=delete;
};
// Direct in-slice primitive. The caller retains the exact real Core execution
// lease throughout computation and publication. Budget is the current slice;
// smaller slices execute the unchanged original instructions instead.
}
