#pragma once
#include "GuestNativeCore.hpp"
#include "NavLargeEffects.hpp"
#include <array>
#include <atomic>
#include <memory>
#include <new>
namespace as6_large_nav {
enum class Decision:std::uint8_t {Original,Handled};
enum class Reason:std::uint8_t {Complete,InvalidContext,StopInsideBody,ReturnInsideBody,UnknownReturn,InsufficientBudget,UnsupportedMode,ActiveMonitor,UnsupportedLayout,UnsupportedCount,Alias,ReadFailure,KernelFailure,PublicationRejected,WorkspaceUnavailable,WorkspaceBusy,WorkspaceTooSmall,BudgetMismatch,BudgetLowerBound,PermissionFailure,CapacityDeclined};
struct WriteEvent {std::uint32_t address=0,width=0;std::uint64_t value=0;};
struct Result {
 Decision decision=Decision::Original;Reason reason=Reason::InvalidContext;
 std::uint64_t originalInstructions=0;
 std::array<WriteEvent,63> writes{};std::size_t writeCount=0;
 as6::navigation::large_effects::Result computed;
};
class Workspace;
Result query(as6native::Core&,as6aot::Context&,Workspace&,std::uint64_t remainingTotalBudget,std::uint32_t stop,bool stopThumb) noexcept;
// Caller owns this fixed storage throughout the synchronous query. It holds
// Point values, never guest addresses, a lease, callbacks or a borrowed span.
// Construction attempts one nothrow allocation; query never allocates/resizes.
// Atomic exclusion prevents two queries sharing this storage at once. Actual
// VM owner, initialization and destruction lifetime remain separate obligations.
class Workspace {
 std::unique_ptr<as6::navigation::large_effects::Point[]> points_;
 std::size_t capacity_=0;
 std::atomic_flag busy_=ATOMIC_FLAG_INIT;
 friend Result query(as6native::Core&,as6aot::Context&,Workspace&,std::uint64_t,std::uint32_t,bool) noexcept;
public:
 enum class Storage:std::uint8_t {Allocate,Disabled};
 explicit Workspace(std::size_t capacity=65536,Storage=Storage::Allocate) noexcept;
 Workspace(const Workspace&)=delete;Workspace&operator=(const Workspace&)=delete;
 std::size_t capacity()const noexcept{return capacity_;}
 std::size_t bytes()const noexcept{return capacity_*sizeof(as6::navigation::large_effects::Point);}
};
// Context budget must already contain the explicit total remainder. A native
// slice counter is not silently treated as that total. Whole-function original
// ledger is debited once. Projection/monitor public-boundary proofs and all
// owner/return/control/alias/stop gates remain required. The actual VM callsite
// additionally authenticates the unique static linked provider and binds a
// fresh observer/source closure; this primitive alone grants no admission.
// Opaque snapshots/raw diagnostics do not establish complete FPSCR equivalence.
}
