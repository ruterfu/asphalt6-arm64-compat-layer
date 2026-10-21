#pragma once
#include "SceneAffineCore.hpp"
namespace as6_scene_boundary {
class ImmutableLinkedProvider {
    friend const as6native::Provider *::AS6LinkedNativeProvider();
    ImmutableLinkedProvider() {}
};
const as6native::Provider *withScene(const as6native::Provider *,ImmutableLinkedProvider);
struct DirectScope;
inline thread_local DirectScope *active=nullptr;
struct DirectScope {
    as6native::Core *const core;
    as6aot::Context *const context;
    const as6aot::DataAccess *const data;
    as6_scene_affine::Workspace workspace;
    DirectScope *const previous;
    std::uint64_t attempts=0,handled=0,declined=0,instructions=0;
    DirectScope(as6native::Core &owner,bool authorized):core(&owner),
        context(authorized?&owner.state().context():nullptr),
        data(owner.state().context().data_access),previous(active){active=this;}
    ~DirectScope(){active=previous;}
    DirectScope(const DirectScope&)=delete;
    DirectScope&operator=(const DirectScope&)=delete;
};
inline bool tryDirect(as6aot::Context &ctx,std::uint32_t stop,bool thumb) noexcept {
    auto *scope=active;
    if(!scope||scope->context!=&ctx||scope->data!=ctx.data_access)return false;
    ++scope->attempts;
    const auto result=as6_scene_affine::queryDirect(*scope->core,ctx,scope->workspace,ctx.budget,stop,thumb);
    if(result.decision==as6_scene_affine::Decision::Handled){
        ++scope->handled;scope->instructions+=as6_scene_affine::OriginalInstructions;return true;
    }
    ++scope->declined;return false;
}
}
