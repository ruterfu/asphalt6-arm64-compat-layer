#include "NativeCollisionQuery.hpp"
#include <array>
#include <cstring>
#include <limits>
#include <new>
#include <unordered_map>

namespace as6_collision {
namespace {
using namespace as6::collision;
constexpr std::size_t MaximumNodes=65536;
constexpr std::size_t MaximumTriangleBytes=64u*1024u*1024u;
constexpr std::uint32_t MaximumCapacity=1048576;
bool range(std::uint32_t at,std::uint64_t bytes) {
    return at>=4096&&bytes&&bytes<=0x100000000ULL-at;
}
bool overlaps(std::uint32_t a,std::uint64_t an,std::uint32_t b,std::uint64_t bn) {
    return an&&bn&&std::uint64_t(a)<std::uint64_t(b)+bn&&
           std::uint64_t(b)<std::uint64_t(a)+an;
}
std::uint32_t word(const std::uint8_t *bytes) {
    return std::uint32_t(bytes[0])|(std::uint32_t(bytes[1])<<8)|
           (std::uint32_t(bytes[2])<<16)|(std::uint32_t(bytes[3])<<24);
}
template<class T> T value(const std::uint8_t *bytes) {
    T out;std::memcpy(&out,bytes,sizeof(out));return out;
}
FloatMode floatMode(std::uint32_t fpscr) {
    FloatMode mode;
    mode.rounding=RoundingMode((fpscr>>22)&3);
    mode.flushToZero=(fpscr>>24)&1;mode.defaultNaN=(fpscr>>25)&1;
    mode.exceptionEnables=(fpscr>>8)&0x9f;
    mode.vectorLength=(fpscr>>16)&7;mode.vectorStride=(fpscr>>20)&3;
    return mode;
}
class Source final:public TreeSource {
    struct Descriptor {Node node;std::uint32_t triangles;};
    const Storage &storage_;
    std::uint32_t output_,count_;
    std::uint64_t outputBytes_;
    mutable std::unordered_map<NodeId,Descriptor> nodes_;
    bool independent(std::uint32_t at,std::uint64_t bytes) const {
        if(overlaps(at,bytes,output_,outputBytes_)||overlaps(at,bytes,count_,4)) {
            failure=Reason::InputOutputAlias;return false;
        }
        return true;
    }
public:
    mutable Reason failure=Reason::Complete;
    mutable std::size_t triangleBytesRead=0;
    Source(const Storage &storage,std::uint32_t output,std::uint64_t bytes,std::uint32_t count)
        :storage_(storage),output_(output),count_(count),outputBytes_(bytes) {}
    std::size_t nodeCount() const {return nodes_.size();}
    bool readNode(NodeId id,Node &out) const override {
        auto found=nodes_.find(id);
        if(found!=nodes_.end()){out=found->second.node;return true;}
        if(!id||id>std::numeric_limits<std::uint32_t>::max()||
           (id&3)||!range(std::uint32_t(id),68)) {failure=Reason::InvalidNode;return false;}
        if(nodes_.size()>=MaximumNodes){failure=Reason::ResourceLimit;return false;}
        const auto address=std::uint32_t(id);
        if(!independent(address,68))return false;
        std::array<std::uint8_t,68> raw{};
        if(!storage_.read(storage_.owner,address,raw.data(),raw.size())) {
            failure=Reason::ReadFailure;return false;
        }
        const auto begin=word(raw.data()),end=word(raw.data()+4),capacity=word(raw.data()+8);
        if(end<begin||capacity<end||(std::uint64_t(end)-begin)%56||
           ((begin|end|capacity)&3)||
           (begin!=end&&!range(begin,std::uint64_t(end)-begin))) {
            failure=Reason::InvalidNode;return false;
        }
        if(begin!=end&&!independent(begin,std::uint64_t(end)-begin))return false;
        Descriptor descriptor{};descriptor.triangles=begin;
        descriptor.node.triangleCount=(end-begin)/56;
        descriptor.node.bounds.minimum=value<Vec3>(raw.data()+44);
        descriptor.node.bounds.maximum=value<Vec3>(raw.data()+56);
        for(unsigned i=0;i<8;++i)descriptor.node.children[i]=word(raw.data()+12+4*i);
        out=descriptor.node;nodes_.emplace(id,std::move(descriptor));return true;
    }
    bool readTriangles(NodeId id,std::uint32_t first,TriangleSection *out,std::size_t count) const override {
        const auto found=nodes_.find(id);
        if(found==nodes_.end()||first>found->second.node.triangleCount||
           count>found->second.node.triangleCount-first||(!out&&count)) {
            failure=Reason::InvalidNode;return false;
        }
        if(count>(MaximumTriangleBytes-triangleBytesRead)/56) {
            failure=Reason::ResourceLimit;return false;
        }
        if(!count)return true;
        const auto at=std::uint64_t(found->second.triangles)+std::uint64_t(first)*56;
        const auto bytes=count*56;
        if(at>std::numeric_limits<std::uint32_t>::max()||!range(std::uint32_t(at),bytes)) {
            failure=Reason::InvalidNode;return false;
        }
        if(!storage_.read(storage_.owner,std::uint32_t(at),out,bytes)) {
            failure=Reason::ReadFailure;return false;
        }
        triangleBytesRead+=bytes;return true;
    }
};
}
Result query(const Storage &storage,std::uint32_t selector,std::uint32_t root,
             std::uint32_t fpscr) noexcept {
    Result result;
    if(!storage.owner||!storage.read||!storage.publish)return result;
    if((selector&3)||!range(selector,0xb4)||!root) {
        result.reason=Reason::InvalidSelector;return result;
    }
    try {
        std::array<std::uint8_t,128> raw{};
        std::array<std::uint8_t,12> descriptor{};
        if(!storage.read(storage.owner,selector+0x24,raw.data(),raw.size())||
           !storage.read(storage.owner,selector+0xa8,descriptor.data(),descriptor.size())) {
            result.reason=Reason::ReadFailure;return result;
        }
        const auto output=word(descriptor.data()),capacity=word(descriptor.data()+4),
                   initial=word(descriptor.data()+8);
        const auto bytes=std::uint64_t(capacity)*56;
        if(!capacity||capacity>MaximumCapacity||initial>=capacity||(output&3)||!range(output,bytes)) {
            result.reason=Reason::InvalidSelector;return result;
        }
        if(overlaps(output,bytes,selector+0x24,raw.size())||
           overlaps(output,bytes,selector+0xa8,descriptor.size())) {
            result.reason=Reason::InputOutputAlias;return result;
        }
        Query q;
        q.start=value<Vec3>(raw.data());q.end=value<Vec3>(raw.data()+12);
        q.segmentLengthSquared=value<float>(raw.data()+24);
        q.unitDirection=value<Vec3>(raw.data()+28);
        q.segmentBounds.minimum=value<Vec3>(raw.data()+40);
        q.segmentBounds.maximum=value<Vec3>(raw.data()+52);
        q.outputTransform=value<std::array<float,16>>(raw.data()+64);
        Source source(storage,output,bytes,selector+0xb0);
        auto computed=collectOctreeLine(source,root,q,capacity,initial,floatMode(fpscr));
        result.kernelStatus=computed.status;result.nodesRead=source.nodeCount();
        result.triangleBytesRead=source.triangleBytesRead;
        if(computed.status!=QueryStatus::Complete) {
            result.reason=source.failure==Reason::Complete?Reason::KernelUnsupported:source.failure;
            return result;
        }
        if(computed.totalCount<initial||computed.totalCount>=capacity||
           computed.appended.size()!=computed.totalCount-initial) {
            result.reason=Reason::KernelUnsupported;return result;
        }
        // Empty results have no data effect in the original; avoid a redundant
        // write that would needlessly invalidate an exclusive reservation.
        if(!computed.appended.empty()) {
            const auto destination=std::uint64_t(output)+std::uint64_t(initial)*56;
            const as6hostdata::DataMemory::WriteSpan writes[]{
                {std::uint32_t(destination),computed.appended.data(),computed.appended.size()*56},
                {selector+0xb0,&computed.totalCount,4}
            };
            if(!storage.publish(storage.owner,writes,2)) {
                result.reason=Reason::PublicationRejected;return result;
            }
        }
        result.totalCount=computed.totalCount;result.floatingPoint=computed.floatingPoint;
        result.reason=Reason::Complete;result.decision=Decision::Handled;return result;
    } catch(const std::bad_alloc &) {result.reason=Reason::ResourceLimit;return result;}
      catch(...) {result.reason=Reason::KernelUnsupported;return result;}
}
}
