#include "NativeSystemZlibProvider.hpp"
#include <algorithm>
#include <vector>
#include <cstring>
#include <new>

namespace {
using namespace as6native;
constexpr Bridge replacements[]={
    {0x33e8b0,0x5a600001,"__as6_system_inflateReset",false,true},
    {0x33e928,0x5a600002,"__as6_system_inflateInit2",false,true},
    {0x33ea2c,0x5a600003,"__as6_system_inflateInit",false,true},
    {0x33ea40,0x5a600004,"__as6_system_inflateEnd",false,true},
    {0x33ebd0,0x5a600005,"__as6_system_inflate",false,true},
};
const as6aot::NativeProgram *baseProgram=nullptr;
as6aot::NativeFunction Lookup(std::uint32_t pc,bool thumb) {
    if(!thumb)for(const auto &entry:replacements)if(entry.original_address==pc)return nullptr;
    return baseProgram?baseProgram->lookup(pc,thumb):nullptr;
}
struct OwnedProvider {
    const Provider *original;
    std::vector<Bridge> bridges;
    as6aot::NativeModule module{0,0x1ffffffffULL,Lookup};
    as6aot::NativeProgram program;
    Provider provider{};
    bool valid=false;
    explicit OwnedProvider(const Provider *base):original(base),
        program(&module,1,as6aot::layout::Size,as6aot::layout::pc) {
        if(!base||base->version!=ProviderVersion||!base->program||!base->program->valid()||
           (base->bridge_count&&!base->bridges))return;
        for(const auto &entry:replacements){
            if(!base->program->lookup(entry.original_address,false))return;
            for(std::size_t i=0;i<base->bridge_count;++i){const auto &old=base->bridges[i];
                if(!old.symbol)return;
                if((old.original_address==entry.original_address&&!old.thumb)||
                   old.native_bridge_id==entry.native_bridge_id||!std::strcmp(old.symbol,entry.symbol))return;
            }
        }
        if(base->bridge_count)bridges.assign(base->bridges,base->bridges+base->bridge_count);
        bridges.insert(bridges.end(),std::begin(replacements),std::end(replacements));
        std::sort(bridges.begin(),bridges.end(),[](const Bridge &a,const Bridge &b){
            return ((std::uint64_t(a.original_address)<<1)|a.thumb)<
                   ((std::uint64_t(b.original_address)<<1)|b.thumb);});
        baseProgram=base->program;
        provider=*base;provider.program=&program;provider.bridges=bridges.data();provider.bridge_count=bridges.size();
        valid=true;
    }
};
}
extern "C" const as6native::Provider *AS6ProviderWithSystemZlib(const as6native::Provider *base) {
    // The App has one immutable provider. Reject any attempt to switch it.
    try {
        static OwnedProvider owned(base);
        return owned.valid&&owned.original==base?&owned.provider:nullptr;
    } catch(const std::bad_alloc &){return nullptr;}
}
