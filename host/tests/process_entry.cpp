#include "ProcessArguments.hpp"
#include "atomic_access.hpp"
#include "native_state.hpp"
#include "native_program.hpp"
#include <cassert>
#include <cstdio>
#include <cstring>

extern "C" const as6aot::NativeProgram *AS6NativeProgram();
int main() {
    using namespace as6aot;
    unsigned checks=0;
    for(unsigned offset:{0u,8u,16u,128u}) {
        ArmAtomicMemory memory;assert(memory.map(0x3ffef000,4096,3)==ArmAtomicMemory::Error::None);
        AtomicAccess access(memory);assert(access.valid());NativeState state(access.access());
        const uint32_t sp=0x3ffef000+offset,argv0=0x3ffef200;
        const char executable[]="AS6NativeGame";
        assert(memory.write(argv0,executable,sizeof(executable))==ArmAtomicMemory::Error::None);
        assert(as6native::WriteProcessArguments(sp,argv0,[&](uint32_t at,const void *bytes,size_t length) {
            return memory.write(at,bytes,length)==ArmAtomicMemory::Error::None;
        }));
        state.set_register(13,sp);state.set_register(15,0x2764);state.context().budget=32;
        assert(AS6NativeProgram()->execute(state.context(),0x2788,false)==Returned);
        uint32_t value=0;assert(state.get_register(0,value)&&value==1);
        assert(state.get_register(1,value)&&value==sp+4);
        assert(state.get_register(2,value)&&value==sp+12);
        assert(state.get_register(3,value)&&value==sp+16);
        assert(state.get_register(4,value)&&value==0);
        assert(state.get_register(13,value)&&value==sp);
        uint32_t actual=0;assert(memory.read(sp+4,&actual,4)==ArmAtomicMemory::Error::None&&actual==argv0);
        char path[sizeof(executable)]{};assert(memory.read(actual,path,sizeof(path))==ArmAtomicMemory::Error::None&&!strcmp(path,executable));
        assert(state.context().next_pc==0x2788&&state.context().budget==23);
        checks+=12;
    }
    unsigned calls=0;auto writer=[&](uint32_t,const void*,size_t){++calls;return true;};
    assert(!as6native::WriteProcessArguments(0,4,writer));
    assert(!as6native::WriteProcessArguments(8,0,writer));
    assert(!as6native::WriteProcessArguments(9,4,writer));
    assert(!as6native::WriteProcessArguments(0xfffffff8,4,writer));assert(calls==0);
    assert(!as6native::WriteProcessArguments(0x1000,4,[](uint32_t,const void*,size_t){return false;}));checks+=6;
    printf("{\"passed\":true,\"checks\":%u,\"actual_original_entry\":\"0x2764..0x2788\",\"scope\":\"crt argument parsing before original main call\",\"whole_game_complete\":false}\n",checks);
}
