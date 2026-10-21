#pragma once
#include "GuestNativeProvider.hpp"
#include "UIAppendFunction.hpp"
namespace as6_ui_work_boundary {
constexpr std::uint32_t Entry=0x324b48,Exit=0x324b98;
class ImmutableLinkedProvider {
    friend const as6native::Provider *::AS6LinkedNativeProvider();
    ImmutableLinkedProvider() {}
};
const as6native::Provider *withWork(const as6native::Provider *,ImmutableLinkedProvider);
// Bound only inside the real Core execution lease. No host callback or
// scheduler handoff can retain this stack scope. Context and DataAccess
// identity must both match; nested scopes restore the previous binding.
struct DirectScope;
inline thread_local DirectScope *active=nullptr;
struct DirectScope {
    as6aot::Context *const context;
    const as6aot::DataAccess *const data;
    const as6_ui_append::Storage storage;
    DirectScope *const previous;
    std::uint64_t attempts=0,handled=0,declined=0,instructions=0;
    DirectScope(as6aot::Context &c,as6_ui_append::Storage s,bool authorized)
        :context(authorized?&c:nullptr),data(c.data_access),storage(s),previous(active) {
        active=this;
    }
    DirectScope(const DirectScope&)=delete;
    DirectScope& operator=(const DirectScope&)=delete;
    ~DirectScope(){active=previous;}
};
inline bool tryDirect(as6aot::Context &c,std::uint32_t stop,bool thumb) noexcept {
    auto *scope=active;
    if(!scope||scope->context!=&c||scope->data!=c.data_access)return false;
    ++scope->attempts;
    const auto result=as6_ui_append_function::append(scope->storage,c,stop,thumb);
    if(result.handled){++scope->handled;scope->instructions+=result.instructions;}
    else ++scope->declined;
    return result.handled;
}
}
