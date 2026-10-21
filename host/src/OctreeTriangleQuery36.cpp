#include "OctreeTriangleQuery36.hpp"
#include <algorithm>
#include <cfenv>
#include <cmath>
#include <cstring>
#include <limits>
#include <new>
#include <utility>

#if defined(__FAST_MATH__)
#error "Collision predicates require strict float32 arithmetic"
#endif
#pragma STDC FENV_ACCESS ON
#if defined(__clang__)
#pragma clang fp contract(off)
#endif

namespace as6::collision36 {
namespace {
struct Rejected { QueryStatus status; };
std::uint32_t bits(float value) noexcept {
    std::uint32_t result;std::memcpy(&result,&value,4);return result;
}
bool normalOrZero(float value) noexcept {
    const auto magnitude=bits(value)&0x7fffffffu;
    return !magnitude || (magnitude>=0x00800000u && magnitude<0x7f800000u);
}
void input(float value) {
    if(!normalOrZero(value))throw Rejected{QueryStatus::UnsupportedInput};
}
void input(Vec3 value) {input(value.x);input(value.y);input(value.z);}
void input(Bounds value) {
    input(value.minimum);input(value.maximum);
    if(value.minimum.x>value.maximum.x || value.minimum.y>value.maximum.y ||
       value.minimum.z>value.maximum.z)throw Rejected{QueryStatus::UnsupportedInput};
}

// Native host state is thread-local architectural FP state. Restore every bit,
// including pre-existing exception flags, on every success/fallback path.
class HostFloatScope {
#if defined(__aarch64__)
    std::uint64_t control_,status_;
#else
    std::fenv_t environment_{};
#endif
public:
    explicit HostFloatScope(FloatMode mode) {
#if defined(__aarch64__)
        __asm__ volatile("mrs %0, fpcr" : "=r"(control_) :: "memory");
        __asm__ volatile("mrs %0, fpsr" : "=r"(status_) :: "memory");
        // RNE, no traps, no alternate handling. FZ/DN match scalar controls;
        // unsupported tiny/nonfinite intermediates are rejected before publish.
        auto control=control_&~((3ULL<<22)|(1ULL<<24)|(1ULL<<25)|(0x1fULL<<8)|(1ULL<<15)|3ULL);
        if(mode.flushToZero)control|=1ULL<<24;
        if(mode.defaultNaN)control|=1ULL<<25;
        const std::uint64_t zero=0;
        __asm__ volatile("msr fpcr, %0" :: "r"(control) : "memory");
        __asm__ volatile("msr fpsr, %0" :: "r"(zero) : "memory");
#else
        (void)mode;
        if(std::fegetenv(&environment_) || std::fesetround(FE_TONEAREST))
            throw Rejected{QueryStatus::UnsupportedFloatMode};
        std::feclearexcept(FE_ALL_EXCEPT);
#endif
    }
    ~HostFloatScope() noexcept {
#if defined(__aarch64__)
        __asm__ volatile("msr fpcr, %0" :: "r"(control_) : "memory");
        __asm__ volatile("msr fpsr, %0" :: "r"(status_) : "memory");
#else
        std::fesetenv(&environment_);
#endif
    }
    std::uint32_t exceptions() const noexcept {
#if defined(__aarch64__)
        std::uint64_t value;__asm__ volatile("mrs %0, fpsr" : "=r"(value) :: "memory");
        return std::uint32_t(value)&0x9fu;
#else
        const auto value=std::fetestexcept(FE_ALL_EXCEPT);
        return ((value&FE_INVALID)?1u:0u)|((value&FE_DIVBYZERO)?2u:0u)|
               ((value&FE_OVERFLOW)?4u:0u)|((value&FE_UNDERFLOW)?8u:0u)|
               ((value&FE_INEXACT)?16u:0u);
#endif
    }
};

struct Arithmetic {
    FloatEffects effects;
    static float checked(float value) {
        if(!normalOrZero(value))throw Rejected{QueryStatus::UnsupportedArithmetic};
        return value;
    }
    float add(float a,float b) const {return checked(a+b);}
    float sub(float a,float b) const {return checked(a-b);}
    float mul(float a,float b) const {return checked(a*b);}
    float div(float a,float b) const {return checked(a/b);}
    float sqrt(float a) const {return checked(std::sqrt(a));}
    int compare(float a,float b) {
        effects.compared=true;
        if(a<b){effects.nzcv=0x80000000u;return -1;}
        if(a>b){effects.nzcv=0x20000000u;return 1;}
        effects.nzcv=0x60000000u;return 0;
    }
    Vec3 sub(Vec3 a,Vec3 b) const {return {sub(a.x,b.x),sub(a.y,b.y),sub(a.z,b.z)};}
    Vec3 mul(Vec3 a,float b) const {return {mul(a.x,b),mul(a.y,b),mul(a.z,b)};}
    float dot(Vec3 a,Vec3 b) const {
        return add(add(mul(a.x,b.x),mul(a.y,b.y)),mul(a.z,b.z));
    }
    // Original 491230..491248: multiplication rounds before VMLS.
    // This is the reverse cross product, in original operation order.
    Vec3 cross(Vec3 a,Vec3 b) const {
        return {sub(mul(a.z,b.y),mul(a.y,b.z)),
                sub(mul(a.x,b.z),mul(a.z,b.x)),
                sub(mul(a.y,b.x),mul(a.x,b.y))};
    }
};

float component(Vec3 value,unsigned axis) {
    return axis==0?value.x:(axis==1?value.y:value.z);
}
bool nodeIntersects(Arithmetic &f,const Query &q,const Bounds &box) {
    for(unsigned axis=0;axis<3;++axis)
        if(f.compare(component(box.minimum,axis),component(q.segmentBounds.maximum,axis))>0)return false;
    for(unsigned axis=0;axis<3;++axis)
        if(f.compare(component(box.maximum,axis),component(q.segmentBounds.minimum,axis))<0)return false;
    float lower=0,upper=1;
    for(unsigned axis=0;axis<3;++axis) {
        const auto start=component(q.start,axis),end=component(q.end,axis);
        const auto minimum=component(box.minimum,axis),maximum=component(box.maximum,axis);
        const auto direction=f.compare(start,end);
        const auto delta=f.sub(end,start); // Also performed before early rejects.
        float lo=0,hi=1;
        if(direction<0) {
            if(f.compare(maximum,start)<0 || f.compare(minimum,end)>0)return false;
            if(f.compare(minimum,start)>0)lo=f.div(f.sub(minimum,start),delta);
            if(f.compare(maximum,end)<0)hi=f.div(f.sub(maximum,start),delta);
        } else {
            if(f.compare(maximum,end)<0 || f.compare(minimum,start)>0)return false;
            if(f.compare(maximum,start)<0)lo=f.div(f.sub(maximum,start),delta);
            if(f.compare(minimum,end)>0)hi=f.div(f.sub(minimum,start),delta);
        }
        if(axis==0) {
            if(f.compare(lo,0)<=0)lo=0;
            if(f.compare(hi,1)>=0)hi=1;
        } else {
            if(f.compare(lower,lo)>=0)lo=lower;
            if(f.compare(upper,hi)<=0)hi=upper;
        }
        if(f.compare(lo,hi)>0)return false;
        lower=lo;upper=hi;
    }
    return true;
}
bool triangleBoundsIntersect(Arithmetic &f,const Query &q,const Triangle &triangle) {
    for(unsigned axis=0;axis<3;++axis) {
        const auto minimum=component(q.segmentBounds.minimum,axis);
        if(f.compare(minimum,component(triangle.vertices[0],axis))>0 &&
           f.compare(minimum,component(triangle.vertices[1],axis))>0 &&
           f.compare(minimum,component(triangle.vertices[2],axis))>0)return false;
        const auto maximum=component(q.segmentBounds.maximum,axis);
        if(f.compare(maximum,component(triangle.vertices[0],axis))<0 &&
           f.compare(maximum,component(triangle.vertices[1],axis))<0 &&
           f.compare(maximum,component(triangle.vertices[2],axis))<0)return false;
    }
    return true;
}
bool sameSide(Arithmetic &f,Vec3 point,Vec3 opposite,Vec3 a,Vec3 b) {
    const auto edge=f.sub(b,a);
    return f.compare(f.dot(f.cross(edge,f.sub(point,a)),f.cross(edge,f.sub(opposite,a))),0)>=0;
}
bool triangleIntersects(Arithmetic &f,const Query &q,const Triangle &triangle) {
    if(!triangleBoundsIntersect(f,q,triangle))return false;
    const auto a=triangle.vertices[0],b=triangle.vertices[1],c=triangle.vertices[2];
    auto normal=f.cross(f.sub(b,a),f.sub(c,a));
    const auto lengthSquared=f.dot(normal,normal);
    if(f.compare(lengthSquared,0)!=0)normal=f.mul(normal,f.div(1,f.sqrt(lengthSquared)));
    const auto denominator=f.dot(normal,q.unitDirection);
    // Original bit pattern 0x358637bd.
    if(f.compare(std::fabs(denominator),1.0e-6f)<=0)return false;
    const auto t=f.div(-f.sub(f.dot(normal,q.start),f.dot(normal,a)),denominator);
    const auto displacement=f.mul(q.unitDirection,t);
    const Vec3 point{f.add(q.start.x,displacement.x),f.add(q.start.y,displacement.y),f.add(q.start.z,displacement.z)};
    if(!sameSide(f,point,a,b,c) || !sameSide(f,point,b,a,c) || !sameSide(f,point,c,a,b))return false;
    const auto fromStart=f.sub(point,q.start);
    if(f.compare(q.segmentLengthSquared,f.dot(fromStart,fromStart))<=0)return false;
    const auto fromEnd=f.sub(point,q.end);
    return f.compare(q.segmentLengthSquared,f.dot(fromEnd,fromEnd))>0;
}
Vec3 transformed(Arithmetic &f,Vec3 point,const std::array<float,16> &m) {
    const auto y=f.add(f.add(f.add(f.mul(point.x,m[1]),f.mul(point.y,m[5])),f.mul(point.z,m[9])),m[13]);
    const auto z=f.add(f.add(f.add(f.mul(point.x,m[2]),f.mul(point.y,m[6])),f.mul(point.z,m[10])),m[14]);
    const auto x=f.add(f.add(f.add(f.mul(point.x,m[0]),f.mul(point.y,m[4])),f.mul(point.z,m[8])),m[12]);
    return {x,y,z};
}
struct Frame {NodeId id;Node node;unsigned nextChild=0;};
}

QueryResult collectOctreeLine(const TreeSource &source,NodeId root,const Query &query,
                             std::uint32_t capacity,std::uint32_t initialCount,FloatMode mode) noexcept {
    QueryResult result;result.totalCount=initialCount;
    if(mode.rounding!=RoundingMode::Nearest || mode.exceptionEnables || mode.vectorLength || mode.vectorStride) {
        result.status=QueryStatus::UnsupportedFloatMode;return result;
    }
    if(capacity<=initialCount){result.status=QueryStatus::UnsupportedCapacity;return result;}
    if(root==NoNode){result.status=QueryStatus::InvalidTree;return result;}
    try {
        HostFloatScope host(mode);
        input(query.start);input(query.end);input(query.unitDirection);input(query.segmentLengthSquared);
        input(query.segmentBounds);
        if(!query.skipOutputTransform) {
            // Original 4915d8..4917cc never reads the fourth matrix row.
            constexpr unsigned used[]{0,1,2,4,5,6,8,9,10,12,13,14};
            for(unsigned index:used)input(query.outputTransform[index]);
        }
        if(query.segmentLengthSquared<0)throw Rejected{QueryStatus::UnsupportedInput};
        Arithmetic arithmetic;
        std::vector<Frame> stack;
        std::uint64_t nodeVisits=0,triangleVisits=0;
        std::array<Triangle,32> batch;
        const auto enter=[&](NodeId id) {
            if(++nodeVisits>1048576)throw Rejected{QueryStatus::ResourceLimit};
            for(const auto &frame:stack)if(frame.id==id)throw Rejected{QueryStatus::InvalidTree};
            Node node;
            if(!source.readNode(id,node))throw Rejected{QueryStatus::SourceFailure};
            input(node.bounds);
            if(!nodeIntersects(arithmetic,query,node.bounds))return;
            for(std::uint32_t first=0;first<node.triangleCount;) {
                const auto count=std::min<std::size_t>(batch.size(),node.triangleCount-first);
                triangleVisits+=count;
                if(triangleVisits>16777216)throw Rejected{QueryStatus::ResourceLimit};
                if(!source.readTriangles(id,first,batch.data(),count))throw Rejected{QueryStatus::SourceFailure};
                for(std::size_t i=0;i<count;++i) {
                    const auto &triangle=batch[i];
                    for(const auto &vertex:triangle.vertices)input(vertex);
                    if(!triangleIntersects(arithmetic,query,triangle))continue;
                    // Reaching capacity has sibling semantics that are not yet
                    // admitted. Do not publish even the earlier staged hits.
                    if(result.appended.size()+1>=std::uint64_t(capacity)-initialCount)
                        throw Rejected{QueryStatus::UnsupportedCapacity};
                    Triangle output;
                    std::memcpy(&output,&triangle,sizeof(output));
                    // Original 4915cc..4915d4 bypasses every matrix operation
                    // when identityByte is nonzero. Preserve signed-zero bits.
                    if(!query.skipOutputTransform)
                        for(auto &vertex:output.vertices)vertex=transformed(arithmetic,vertex,query.outputTransform);
                    result.appended.push_back(output);
                }
                first+=std::uint32_t(count);
            }
            stack.push_back({id,node,0});
        };
        enter(root);
        while(!stack.empty()) {
            auto &frame=stack.back();
            if(frame.nextChild==8){stack.pop_back();continue;}
            const auto child=frame.node.children[frame.nextChild++];
            if(child!=NoNode)enter(child);
        }
        const auto exceptions=host.exceptions();
        if(exceptions&0x8fu)throw Rejected{QueryStatus::UnsupportedArithmetic};
        result.totalCount=initialCount+std::uint32_t(result.appended.size());
        result.floatingPoint=arithmetic.effects;result.floatingPoint.exceptionBits=exceptions;
        result.status=QueryStatus::Complete;
    } catch(const Rejected &error) {result.status=error.status;}
      catch(const std::bad_alloc &) {result.status=QueryStatus::ResourceLimit;}
      catch(...) {result.status=QueryStatus::SourceFailure;}
    if(result.status!=QueryStatus::Complete) {
        result.appended.clear();result.totalCount=initialCount;result.floatingPoint={};
    }
    return result;
}
}
