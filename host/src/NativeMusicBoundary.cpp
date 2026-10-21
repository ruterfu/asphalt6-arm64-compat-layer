#include "NativeMusicBoundary.hpp"
#include <algorithm>
#include <array>

extern "C" as6aot::NativeFunction as6_native_music_lookup_00409(std::uint32_t,bool);
extern "C" as6aot::NativeFunction as6_native_music_lookup_00410(std::uint32_t,bool);
extern "C" as6aot::NativeFunction as6_native_music_lookup_00411(std::uint32_t,bool);
extern "C" as6aot::NativeFunction as6_native_music_lookup_00412(std::uint32_t,bool);
extern "C" as6aot::NativeFunction as6_native_music_lookup_00415(std::uint32_t,bool);

namespace as6_music_boundary {
namespace {
constexpr std::array<std::uint32_t,14> Entries{
    0xdf498u,0xdf53cu,0xdfa68u,0xdfa88u,0xdfaa0u,0xe00b8u,0xe0108u,
    0xe0968u,0xe20e4u,0xe241cu,0xe24c4u,0xe24fcu,0xe253cu,0xe25a4u
};
thread_local const as6aot::Context *resumeContext=nullptr;
thread_local std::uint32_t resumePC=0;
}
bool isBoundary(std::uint32_t pc,bool thumb) noexcept {
    return !thumb&&std::binary_search(Entries.begin(),Entries.end(),pc);
}
bool shouldSuspend(as6aot::Context &context,std::uint32_t pc) noexcept {
    if(resumeContext==&context&&resumePC==pc&&context.next_pc==pc&&!context.isa_thumb){
        resumeContext=nullptr;resumePC=0;return false;
    }
    return true;
}
bool arm(as6aot::Context &context,std::uint32_t pc) noexcept {
    if(resumeContext||!isBoundary(pc,context.isa_thumb)||context.next_pc!=pc)return false;
    resumeContext=&context;resumePC=pc;return true;
}
void cancel(as6aot::Context &context) noexcept {
    if(resumeContext==&context){resumeContext=nullptr;resumePC=0;}
}
as6aot::NativeFunction lookup(std::uint32_t pc,bool thumb) noexcept {
    using Lookup=as6aot::NativeFunction(*)(std::uint32_t,bool);
    // Bounds are derived from each unchanged private shard entry table.
    const auto key=(std::uint64_t(pc)<<1)|std::uint64_t(thumb);
    if(key<0x1bdc68ULL||key>0x1c5210ULL)return nullptr;
    struct Shard { std::uint64_t first,last;Lookup lookup; };
    constexpr Shard shards[]{
        {0x1bdc68ULL,0x1bee68ULL,as6_native_music_lookup_00409},
        {0x1bee70ULL,0x1bff80ULL,as6_native_music_lookup_00410},
        {0x1bff88ULL,0x1c1060ULL,as6_native_music_lookup_00411},
        {0x1c1068ULL,0x1c20f0ULL,as6_native_music_lookup_00412},
        {0x1c41c8ULL,0x1c5210ULL,as6_native_music_lookup_00415},
    };
    for(const auto &shard:shards)
        if(key>=shard.first&&key<=shard.last)return shard.lookup(pc,thumb);
    return nullptr;
}
}
