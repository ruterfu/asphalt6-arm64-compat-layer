#include "NativeUIWorkBoundary.hpp"
extern "C" as6aot::NativeFunction as6_native_ui_work_lookup_01501(std::uint32_t,bool);
namespace as6_ui_work_boundary {namespace {
const as6aot::NativeProgram *baseProgram=nullptr;
as6aot::NativeFunction lookup(std::uint32_t pc,bool thumb) {
    const auto key=(std::uint64_t(pc)<<1)|thumb;
    if(key>=6591176ULL&&key<=6595272ULL)
        if(auto fn=as6_native_ui_work_lookup_01501(pc,thumb))return fn;
    return baseProgram->lookup(pc,thumb);
}
struct Owned {
    const as6native::Provider *const original;
    const as6aot::NativeModule module{0,0x1ffffffffULL,lookup};
    const as6aot::NativeProgram program{&module,1,as6aot::layout::Size,as6aot::layout::pc};
    as6native::Provider provider;
    explicit Owned(const as6native::Provider *p):original(p),provider(*p) {
        baseProgram=p->program;provider.program=&program;
    }
};
}
const as6native::Provider *withWork(const as6native::Provider *p,ImmutableLinkedProvider) {
    if(!p||p->version!=as6native::ProviderVersion||!p->program||!p->program->valid()||
       p->program->register_size()!=as6aot::layout::Size||
       !p->program->lookup(Entry,false))return nullptr;
    static const Owned owned(p);
    return owned.original==p&&baseProgram==p->program&&owned.program.valid()?&owned.provider:nullptr;
}
}
