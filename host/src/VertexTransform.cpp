#include "VertexTransform.hpp"
#include <cstring>
#include <limits>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif
#if defined(__FAST_MATH__)
#error "Exact vertex kernels require strict floating point arithmetic"
#endif

namespace as6::geometry::vertex {
namespace {
static_assert(sizeof(float)==4&&std::numeric_limits<float>::is_iec559,"IEEE binary32 required");
bool admitted(std::uint32_t bits) {
    const auto value=bits&0x7fffffffu;
    return !value||(value>=0x0d800000u&&value<=0x71800000u);
}
std::uint32_t load(const std::uint8_t *p) {
    return std::uint32_t(p[0])|(std::uint32_t(p[1])<<8)|
        (std::uint32_t(p[2])<<16)|(std::uint32_t(p[3])<<24);
}
void store(std::uint8_t *p,std::uint32_t value) {
    p[0]=std::uint8_t(value);p[1]=std::uint8_t(value>>8);
    p[2]=std::uint8_t(value>>16);p[3]=std::uint8_t(value>>24);
}
bool extent(std::size_t stride,std::uint16_t count,std::size_t available,std::size_t &used) {
    if(stride<12||!count||std::size_t(count)>std::numeric_limits<std::size_t>::max()/stride)return false;
    const auto prefix=std::size_t(count-1)*stride;
    if(prefix>std::numeric_limits<std::size_t>::max()-12)return false;
    used=prefix+12;return used<=available;
}
struct Pair {std::uint32_t lo=0,hi=0;};
std::uint64_t packed(Pair p) {return std::uint64_t(p.lo)|(std::uint64_t(p.hi)<<32);}

#if defined(__aarch64__)
class FloatScope {
    std::uint64_t oldControl=0,oldStatus=0;
public:
    FloatScope() {
        asm volatile("mrs %0,fpcr\n mrs %1,fpsr":"=r"(oldControl),"=r"(oldStatus));
        const std::uint64_t neonControl=(1u<<24)|(1u<<25); // RNE, FZ, DN; traps disabled.
        asm volatile("msr fpcr,%0\n msr fpsr,xzr\n isb"::"r"(neonControl):"memory");
    }
    ~FloatScope() {
        asm volatile("msr fpcr,%0\n msr fpsr,%1\n isb"::"r"(oldControl),"r"(oldStatus):"memory");
    }
    std::uint32_t effects() const {
        std::uint64_t value=0;asm volatile("mrs %0,fpsr":"=r"(value));return std::uint32_t(value)&0x9fu;
    }
};
std::uint32_t mul(std::uint32_t a,std::uint32_t b) {
    float x,y,z;std::memcpy(&x,&a,4);std::memcpy(&y,&b,4);
    asm volatile("fmul %s0,%s1,%s2":"=w"(z):"w"(x),"w"(y));
    std::uint32_t out;std::memcpy(&out,&z,4);return out;
}
std::uint32_t add(std::uint32_t a,std::uint32_t b) {
    float x,y,z;std::memcpy(&x,&a,4);std::memcpy(&y,&b,4);
    asm volatile("fadd %s0,%s1,%s2":"=w"(z):"w"(x),"w"(y));
    std::uint32_t out;std::memcpy(&out,&z,4);return out;
}
Pair mul(Pair a,Pair b,bool &ok) {
    Pair out{mul(a.lo,b.lo),mul(a.hi,b.hi)};
    const bool underflowToZero=!(out.lo&0x7fffffffu)&&(a.lo&0x7fffffffu)&&(b.lo&0x7fffffffu);
    ok=ok&&admitted(out.lo)&&!underflowToZero;return out;
}
Pair add(Pair a,Pair b,bool &ok) {
    Pair out{add(a.lo,b.lo),add(a.hi,b.hi)};
    const bool underflowToZero=!(out.lo&0x7fffffffu)&&
        ((a.lo&0x7fffffffu)!=(b.lo&0x7fffffffu));
    ok=ok&&admitted(out.lo)&&!underflowToZero;return out;
}
// Every lane models a different vertex; no fused multiply/add is permitted.
uint32x4_t magnitude(uint32x4_t bits) {return vandq_u32(bits,vdupq_n_u32(0x7fffffff));}
bool admittedVector(uint32x4_t bits) {
    const auto m=magnitude(bits);
    const auto valid=vorrq_u32(vceqq_u32(m,vdupq_n_u32(0)),
        vandq_u32(vcgeq_u32(m,vdupq_n_u32(0x0d800000)),vcleq_u32(m,vdupq_n_u32(0x71800000))));
    return vminvq_u32(valid)==0xffffffffu;
}
float32x4_t broadcast(std::uint32_t bits) {return vreinterpretq_f32_u32(vdupq_n_u32(bits));}
float32x4_t vectorMul(float32x4_t a,float32x4_t b,bool &ok) {
    const auto out=vmulq_f32(a,b);
    const auto am=magnitude(vreinterpretq_u32_f32(a)),bm=magnitude(vreinterpretq_u32_f32(b)),om=magnitude(vreinterpretq_u32_f32(out));
    const auto under=vandq_u32(vceqq_u32(om,vdupq_n_u32(0)),vandq_u32(vmvnq_u32(vceqq_u32(am,vdupq_n_u32(0))),vmvnq_u32(vceqq_u32(bm,vdupq_n_u32(0)))));
    ok=ok&&admittedVector(vreinterpretq_u32_f32(out))&&vmaxvq_u32(under)==0;return out;
}
float32x4_t vectorAdd(float32x4_t a,float32x4_t b,bool &ok) {
    const auto out=vaddq_f32(a,b);
    const auto am=magnitude(vreinterpretq_u32_f32(a)),bm=magnitude(vreinterpretq_u32_f32(b)),om=magnitude(vreinterpretq_u32_f32(out));
    const auto under=vandq_u32(vceqq_u32(om,vdupq_n_u32(0)),vmvnq_u32(vceqq_u32(am,bm)));
    ok=ok&&admittedVector(vreinterpretq_u32_f32(out))&&vmaxvq_u32(under)==0;return out;
}
float32x4_t vectorRow(float32x4_t x,float32x4_t y,float32x4_t z,const std::array<std::uint32_t,4>&row,bool &ok) {
    const auto a=vectorMul(x,broadcast(row[0]),ok);
    const auto b=vectorMul(y,broadcast(row[1]),ok);
    const auto c=vectorAdd(a,b,ok);
    const auto d=vectorMul(z,broadcast(row[2]),ok);
    const auto e=vectorAdd(c,d,ok);
    return vectorAdd(e,broadcast(row[3]),ok);
}
bool tryVector(const SourceSpan &source,const ScratchSpan &scratch,std::uint16_t currentCount,
    std::uint16_t iterations,const Affine3x4 &matrix,const LoopInput &input,Result &result) noexcept {
    FloatScope environment;
    std::uint32_t lastY=0,lastZ=0,lastOutputZ=0;unsigned done=0;
    for(;done+4<=iterations;done+=4){
        std::uint32_t words[12];if(source.stride==12)std::memcpy(words,source.bytes+done*12,sizeof(words));
        else for(unsigned lane=0;lane<4;++lane)
            std::memcpy(words+lane*3,source.bytes+std::size_t(done+lane)*source.stride,12);
        const auto bits=vld3q_u32(words);
        if(!admittedVector(bits.val[0])||!admittedVector(bits.val[1])||!admittedVector(bits.val[2]))return false;
        bool ok=true;
        const auto x=vreinterpretq_f32_u32(bits.val[0]),y=vreinterpretq_f32_u32(bits.val[1]),z=vreinterpretq_f32_u32(bits.val[2]);
        const auto ox=vectorRow(x,y,z,matrix.x,ok),oy=vectorRow(x,y,z,matrix.y,ok),oz=vectorRow(x,y,z,matrix.z,ok);
        if(!ok)return false;
        uint32x4x3_t output{{vreinterpretq_u32_f32(ox),vreinterpretq_u32_f32(oy),vreinterpretq_u32_f32(oz)}};
        vst3q_u32(words,output);std::memcpy(scratch.bytes+done*12,words,sizeof(words));
        lastY=vgetq_lane_u32(bits.val[1],3);lastZ=vgetq_lane_u32(bits.val[2],3);lastOutputZ=vgetq_lane_u32(output.val[2],3);
    }
    const auto effects=environment.effects();
    if(done<iterations){
        LoopInput tailInput=input;tailInput.fpscr|=effects;
        const auto tail=transform({source.bytes+std::size_t(done)*source.stride,source.size-std::size_t(done)*source.stride,source.stride},
            {scratch.bytes+done*12,scratch.size-done*12,12},std::uint16_t(currentCount-done),std::uint16_t(iterations-done),matrix,tailInput);
        if(tail.status!=Status::Complete)return false;
        result=tail;
    }else{
        result.status=Status::Complete;result.fpscr=input.fpscr|effects;
        result.d3ToD7={std::uint64_t(lastY),std::uint64_t(lastZ),std::uint64_t(lastY),std::uint64_t(matrix.z[3]),std::uint64_t(lastOutputZ)};
    }
    result.vectorizedVertices=done;
    result.written=iterations;result.sourceAdvance=std::size_t(iterations)*source.stride;
    result.destinationAdvance=std::size_t(iterations)*12;result.remaining=currentCount-iterations;
    result.r3=result.remaining;result.nzcv=result.remaining?0x20000000u:0x60000000u;
    return true;
}

#endif
} // namespace

Result transform(const SourceSpan &source,const ScratchSpan &scratch,std::uint16_t currentCount,
                 std::uint16_t iterations,
                 const Affine3x4 &matrix,const LoopInput &input) noexcept {
    Result result;result.fpscr=input.fpscr;
    std::size_t sourceUsed=0,destinationUsed=0;
    if(!currentCount||!iterations||iterations>currentCount||!source.bytes||!scratch.bytes||
       !extent(source.stride,iterations,source.size,sourceUsed)||
       !extent(scratch.stride,iterations,scratch.size,destinationUsed))return result;
    const auto a=reinterpret_cast<std::uintptr_t>(source.bytes),b=reinterpret_cast<std::uintptr_t>(scratch.bytes);
    if(sourceUsed>UINTPTR_MAX-a||destinationUsed>UINTPTR_MAX-b||
       (a<b+destinationUsed&&b<a+sourceUsed))return result;
    if(input.fpscr&(0x9f00u|(7u<<16)|(3u<<20))){result.status=Status::UnsupportedEnvironment;return result;}
    const Affine3x4 coefficients=matrix;
    for(const auto *row:{&coefficients.x,&coefficients.y,&coefficients.z})
        for(auto bits:*row)if(!admitted(bits)){result.status=Status::UnsupportedFloat;return result;}
#if !defined(__aarch64__)
    result.status=Status::UnsupportedPlatform;return result;
#else
    // Positive-zero secondary lanes remain positive zero in every original
    // paired operation. This proven domain admits four independent vertices.
    if(scratch.stride==12&&iterations>=4) {
        bool zero=true;for(auto bits:input.oddS)zero=zero&&bits==0;
        if(zero&&tryVector(source,scratch,currentCount,iterations,coefficients,input,result))return result;
    }
    FloatScope environment;
    Pair d3{0,input.oddS[0]},d4{0,input.oddS[1]},d5{0,input.oddS[2]},
         d6{0,input.oddS[3]},d7{0,input.oddS[4]};
    const auto *src=source.bytes;auto *dst=scratch.bytes;
    for(std::uint32_t remaining=iterations;remaining;--remaining){
        const auto x=load(src),y=load(src+4),z=load(src+8);
        if(!admitted(x)||!admitted(y)||!admitted(z)){result.status=Status::UnsupportedFloat;return result;}
        bool ok=true;
        // Exact ordered D-register pipeline, including secondary lane carry.
        d7.lo=coefficients.x[0];d3.lo=y;d6.lo=x;
        d6=mul(d6,d7,ok);d7.lo=coefficients.x[1];d7=mul(d3,d7,ok);d4.lo=z;
        d6=add(d6,d7,ok);d7.lo=coefficients.x[2];d7=mul(d4,d7,ok);
        d7=add(d6,d7,ok);d6.lo=coefficients.x[3];d7=add(d7,d6,ok);
        const auto outX=d7.lo;
        d7.lo=coefficients.y[0];d5.lo=x;d6=mul(d5,d7,ok);
        d7.lo=coefficients.y[1];d7=mul(d3,d7,ok);d6=add(d6,d7,ok);
        d7.lo=coefficients.y[2];d7=mul(d4,d7,ok);d7=add(d6,d7,ok);
        d6.lo=coefficients.y[3];d7=add(d7,d6,ok);
        const auto outY=d7.lo;
        d7.lo=coefficients.z[0];d6=mul(d5,d7,ok);d5.lo=y;
        d7.lo=coefficients.z[1];d7=mul(d5,d7,ok);d6=add(d6,d7,ok);
        d7.lo=coefficients.z[2];d7=mul(d4,d7,ok);d7=add(d6,d7,ok);
        d6.lo=coefficients.z[3];d7=add(d7,d6,ok);
        if(!ok){result.status=Status::UnsupportedFloat;return result;}
        store(dst,outX);store(dst+4,outY);store(dst+8,d7.lo);++result.written;
        if(remaining>1){src+=source.stride;dst+=scratch.stride;}
    }
    const auto effects=environment.effects();
    result.status=Status::Complete;result.fpscr=input.fpscr|effects;
    result.d3ToD7={packed(d3),packed(d4),packed(d5),packed(d6),packed(d7)};
    result.sourceAdvance=std::size_t(iterations)*source.stride;
    result.destinationAdvance=std::size_t(iterations)*scratch.stride;
    result.remaining=std::uint32_t(currentCount)-iterations;result.r3=result.remaining;
    result.nzcv=result.remaining?0x20000000u:0x60000000u; // CMP remaining,#0.
    return result;
#endif
}
} // namespace as6::geometry::vertex
