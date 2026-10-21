#include "NativeTrailAdapter.hpp"
#include <array>
#include <cstring>
#include <new>

namespace as6_trail {
namespace {
namespace trail=as6::geometry::trail;
constexpr std::uint64_t NodeExtent=0x181,OriginalStackExtent=0x11c;
bool range(std::uint32_t at,std::uint64_t bytes) {
    return at>=4096&&bytes&&bytes<=0x100000000ULL-at;
}
bool overlaps(std::uint32_t a,std::uint64_t an,std::uint32_t b,std::uint64_t bn) {
    return an&&bn&&std::uint64_t(a)<std::uint64_t(b)+bn&&std::uint64_t(b)<std::uint64_t(a)+an;
}
std::uint16_t half(const std::uint8_t *p) {return std::uint16_t(p[0])|(std::uint16_t(p[1])<<8);}
std::uint32_t word(const std::uint8_t *p) {
    return std::uint32_t(p[0])|(std::uint32_t(p[1])<<8)|
           (std::uint32_t(p[2])<<16)|(std::uint32_t(p[3])<<24);
}
template<class T>T value(const std::uint8_t *p) {
    T result;std::memcpy(&result,p,sizeof result);return result;
}
template<class T>void put(std::uint8_t *p,const T &v) {std::memcpy(p,&v,sizeof v);}
trail::FloatMode floatMode(std::uint32_t fpscr) {
    trail::FloatMode out;out.rounding=trail::Rounding((fpscr>>22)&3);
    out.flushToZero=(fpscr>>24)&1;out.defaultNaN=(fpscr>>25)&1;
    out.exceptionEnables=(fpscr>>8)&0x9f;out.vectorLength=(fpscr>>16)&7;out.vectorStride=(fpscr>>20)&3;
    return out;
}
class Indices final:public trail::IndexSource {
    const Storage &storage_;
    const std::uint32_t address_,capacity_;
public:
    mutable bool failed=false;
    mutable std::uint64_t bytesRead=0;
    Indices(const Storage &s,std::uint32_t at,std::uint32_t count):storage_(s),address_(at),capacity_(count) {}
    bool readIndices(std::uint32_t first,std::uint16_t *out,std::size_t count) const override {
        if(first>capacity_||count>capacity_-first||(!out&&count)){failed=true;return false;}
        if(!count)return true;
        const auto at=std::uint64_t(address_)+std::uint64_t(first)*2;
        if(at>0xffffffffULL||!range(std::uint32_t(at),std::uint64_t(count)*2)||
           !storage_.read(storage_.owner,std::uint32_t(at),out,count*2)) {failed=true;return false;}
        bytesRead+=std::uint64_t(count)*2;return true;
    }
};
}
Result update(const Storage &storage,std::uint32_t node,std::uint32_t stackPointer,
              std::uint32_t fpscr) noexcept {
    Result result;
    if(!storage.owner||!storage.read||!storage.publish)return result;
    if((node&3)||!range(node,NodeExtent)||(stackPointer&3)||
       stackPointer<4096+OriginalStackExtent) {result.reason=Reason::InvalidNode;return result;}
    try {
        std::array<std::uint8_t,NodeExtent> raw{};
        struct Field {std::size_t at,bytes;};
        // Exact fixed input union:116bytes in10reads. Vtable, padding and
        // unrelated scene-node attributes do not become required inputs.
        constexpr Field inputs[]={{0x10,12},{0x20,12},{0x30,12},{0x40,12},
            {0x11c,6},{0x124,12},{0x148,1},{0x14c,18},{0x160,6},{0x168,25}};
        for(const auto f:inputs)
            if(!storage.read(storage.owner,node+std::uint32_t(f.at),raw.data()+f.at,f.bytes)) {
                result.reason=Reason::ReadFailure;return result;
            }
        trail::Pose pose{{value<trail::Vec3>(raw.data()+0x10),value<trail::Vec3>(raw.data()+0x20),
                          value<trail::Vec3>(raw.data()+0x30)},value<trail::Vec3>(raw.data()+0x40)};
        trail::Config config;
        config.baseVertex=half(raw.data()+0x158);config.indexCapacity=half(raw.data()+0x15a);
        config.vertexCapacity=half(raw.data()+0x16c);
        config.width=value<float>(raw.data()+0x170);config.minimumDistance=value<float>(raw.data()+0x174);
        config.uvStep=value<float>(raw.data()+0x178);
        config.uEndpoints={value<float>(raw.data()+0x128),value<float>(raw.data()+0x12c)};
        std::memcpy(config.colorBytes.data(),raw.data()+0x11c,4);
        config.flipU=raw[0x17c]!=0;config.fadeTail=raw[0x17d]!=0;config.smoothJoin=raw[0x17e]!=0;
        config.widthUsesAlpha=raw[0x17f]!=0;config.premultiplyColor=raw[0x180]!=0;
        trail::State state;
        state.v=value<float>(raw.data()+0x124);state.lastPosition=value<trail::Vec3>(raw.data()+0x14c);
        state.usedIndices=half(raw.data()+0x15c);state.indexCursor=half(raw.data()+0x164);
        state.vertexCursor=half(raw.data()+0x16e);state.lastAlpha=raw[0x120];
        state.first=raw[0x148]!=0;state.lastEnded=raw[0x121]!=0;
        const auto indexAddress=word(raw.data()+0x160),vertexAddress=word(raw.data()+0x168);
        const auto indexBytes=std::uint64_t(config.indexCapacity)*2,vertexBytes=std::uint64_t(config.vertexCapacity)*36;
        if((indexAddress&1)||(vertexAddress&3)||!range(indexAddress,indexBytes)||!range(vertexAddress,vertexBytes)) {
            result.reason=Reason::InvalidBuffers;return result;
        }
        const auto frame=stackPointer-std::uint32_t(OriginalStackExtent);
        if(overlaps(node,NodeExtent,indexAddress,indexBytes)||overlaps(node,NodeExtent,vertexAddress,vertexBytes)||
           overlaps(indexAddress,indexBytes,vertexAddress,vertexBytes)||
           overlaps(node,NodeExtent,frame,OriginalStackExtent)||
           overlaps(indexAddress,indexBytes,frame,OriginalStackExtent)||
           overlaps(vertexAddress,vertexBytes,frame,OriginalStackExtent)) {
            result.reason=Reason::InputOutputAlias;return result;
        }
        Indices source(storage,indexAddress,config.indexCapacity);
        auto computed=trail::update(pose,config,state,source,floatMode(fpscr));
        result.kernelStatus=computed.status;result.indexBytesRead=source.bytesRead;
        if(computed.status!=trail::Status::Complete) {
            result.reason=source.failed?Reason::ReadFailure:Reason::KernelUnsupported;return result;
        }
        if(computed.stateWrites&~0xffu) {result.reason=Reason::KernelUnsupported;return result;}
        std::array<as6hostdata::DataMemory::WriteSpan,as6hostdata::DataMemory::MaximumWriteSpans> writes{};
        std::size_t count=0;
        const auto append=[&](std::uint32_t address,const void *bytes,std::size_t amount) {
            if(!amount||!bytes||!range(address,amount)||count==writes.size())return false;
            writes[count++]={address,bytes,amount};return true;
        };
        const auto patches=[&](const auto &values,std::uint32_t address,std::uint64_t extent,std::uint64_t &total) {
            std::uint64_t previousEnd=0;
            for(const auto &patch:values) {
                if(patch.offset<previousEnd||patch.offset>extent||patch.bytes.size()>extent-patch.offset||
                   !append(std::uint32_t(std::uint64_t(address)+patch.offset),patch.bytes.data(),patch.bytes.size()))return false;
                previousEnd=patch.offset+patch.bytes.size();total+=patch.bytes.size();
            }
            return true;
        };
        if(!patches(computed.vertexWrites,vertexAddress,vertexBytes,result.vertexBytesWritten)||
           !patches(computed.indexWrites,indexAddress,indexBytes,result.indexBytesWritten)) {
            result.reason=Reason::KernelUnsupported;return result;
        }
        // Prepare only originally touched StateFields. Untouched bool bytes
        // retain their exact incoming representation, including nonzero values.
        put(raw.data()+0x124,computed.state.v);put(raw.data()+0x14c,computed.state.lastPosition);
        put(raw.data()+0x15c,computed.state.usedIndices);put(raw.data()+0x164,computed.state.indexCursor);
        put(raw.data()+0x16e,computed.state.vertexCursor);raw[0x120]=computed.state.lastAlpha;
        raw[0x148]=std::uint8_t(computed.state.first);raw[0x121]=std::uint8_t(computed.state.lastEnded);
        struct StateField {std::uint32_t bit;std::size_t at,bytes;};
        constexpr StateField outputs[]={{trail::V,0x124,4},{trail::LastPosition,0x14c,12},
            {trail::UsedIndices,0x15c,2},{trail::IndexCursor,0x164,2},{trail::VertexCursor,0x16e,2},
            {trail::LastAlpha,0x120,1},{trail::First,0x148,1},{trail::LastEnded,0x121,1}};
        for(const auto f:outputs)if(computed.stateWrites&f.bit) {
            if(!append(node+std::uint32_t(f.at),raw.data()+f.at,f.bytes)) {
                result.reason=Reason::ResourceLimit;return result;
            }
            result.stateBytesWritten+=f.bytes;
        }
        if(count&&!storage.publish(storage.owner,writes.data(),count)) {
            result.reason=Reason::PublicationRejected;return result;
        }
        // No fallible step follows the sole publication.
        result.publicationSpans=count;result.floatingPoint=computed.floatingPoint;
        result.reason=Reason::Complete;result.decision=Decision::Handled;return result;
    } catch(const std::bad_alloc &) {result.reason=Reason::ResourceLimit;return result;}
      catch(...) {result.reason=Reason::KernelUnsupported;return result;}
}
}
