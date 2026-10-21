#pragma once
#include <cstdint>

namespace as6native {
// Darwin32 crt at original 0x2764 expects the argv words immediately after
// argc, followed by envp NULL and the Apple argument-array NULL.
template<class Writer>
bool WriteProcessArguments(std::uint32_t sp,std::uint32_t argv0,Writer write) {
    if (!argv0 || !sp || (sp&7u) || std::uint64_t(sp)+20>0x100000000ULL) return false;
    const std::uint32_t frame[]={1,argv0,0,0,0};
    return write(sp,frame,sizeof(frame));
}
}
