#pragma once
#include "CollisionInverseCore.hpp"
namespace as6_collision_inverse_boundary {
class ImmutableLinkedProvider {
    friend const as6native::Provider *::AS6LinkedNativeProvider();
    ImmutableLinkedProvider() {}
};
const as6native::Provider *withInverse(const as6native::Provider *,ImmutableLinkedProvider);
struct DirectScope;
inline thread_local DirectScope *active=nullptr;
struct DirectScope {
    as6native::Core *const core;
    as6aot::Context *const context;
    const as6aot::DataAccess *const data;
    as6_collision_inverse::Workspace workspace;
    DirectScope *const previous;
    std::uint64_t attempts=0,handled=0,declined=0,instructions=0;
    // GuestVM supplies authority from the exact final linked-provider identity
    // and its owned data accessor, as for the existing scene source boundary.
    DirectScope(as6native::Core &owner,bool authorized):core(&owner),
        context(authorized?&owner.state().context():nullptr),
        data(owner.state().context().data_access),previous(active){active=this;}
    ~DirectScope(){active=previous;}
    DirectScope(const DirectScope&)=delete;
    DirectScope &operator=(const DirectScope&)=delete;
};
inline bool tryDirect(as6aot::Context &ctx,std::uint32_t stop,bool thumb) noexcept {
    auto *scope=active;
    if(!scope||scope->context!=&ctx||scope->data!=ctx.data_access)return false;
    ++scope->attempts;
    const auto result=as6_collision_inverse::queryDirect(*scope->core,ctx,scope->workspace,ctx.budget,stop,thumb);
    if(result.decision==as6_collision_inverse::Decision::Handled){
        ++scope->handled;scope->instructions+=result.instructions;return true;
    }
    ++scope->declined;return false;
}
}
