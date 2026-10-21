#pragma once
#include <array>
#include <cstddef>
#include <cstdint>

namespace as6_render_plan {
// One cache belongs to one owned Host buffer mirror. The owner serializes
// queries and invalidates before every mutation/replacement of those bytes.
// No guest pointer, thread, GL state or mutable span is retained here.
class IndexRangeCache {
    struct Entry {
        std::size_t bufferBytes=0;
        std::uint32_t offset=0,count=0,maximum=0;
        unsigned width=0;
        bool valid=false;
    };
    std::array<Entry,8> entries_{};
    unsigned next_=0;
    static bool admitted(std::size_t bytes,std::uint32_t offset,std::uint32_t count,unsigned width) noexcept {
        return (width==1||width==2||width==4)&&count>=MinimumIndices&&
            offset<=bytes&&std::uint64_t(count)*width<=bytes-offset;
    }
public:
    static constexpr unsigned MinimumIndices=4096,Capacity=8;
    void invalidate() noexcept {for(auto &entry:entries_)entry.valid=false;next_=0;}
    bool find(std::size_t bytes,std::uint32_t offset,std::uint32_t count,
              unsigned width,std::uint32_t &maximum) const noexcept {
        if(!admitted(bytes,offset,count,width))return false;
        for(const auto &entry:entries_)if(entry.valid&&entry.bufferBytes==bytes&&
            entry.offset==offset&&entry.count==count&&entry.width==width){maximum=entry.maximum;return true;}
        return false;
    }
    void remember(std::size_t bytes,std::uint32_t offset,std::uint32_t count,
                  unsigned width,std::uint32_t maximum) noexcept {
        if(!admitted(bytes,offset,count,width)||(width==1&&maximum>255)||(width==2&&maximum>65535))return;
        for(auto &entry:entries_)if(entry.valid&&entry.bufferBytes==bytes&&entry.offset==offset&&
            entry.count==count&&entry.width==width){entry.maximum=maximum;return;}
        entries_[next_]={bytes,offset,count,maximum,width,true};next_=(next_+1)%entries_.size();
    }
};
} // namespace as6_render_plan
