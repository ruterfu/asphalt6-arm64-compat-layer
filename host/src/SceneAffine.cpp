#include "SceneAffine.hpp"
#include "as6_arm_float.h"
#include <cstring>
#include <limits>

#if defined(__FAST_MATH__)
#error "Scene affine composition requires strict float32 arithmetic"
#endif
#pragma STDC FENV_ACCESS ON
#if defined(__clang__)
#pragma clang fp contract(off)
#endif
namespace as6::scene::affine {
namespace {
static_assert(sizeof(float)==4&&std::numeric_limits<float>::is_iec559,"IEEE32 required");
struct Pair { std::uint32_t low=0,high=0; };
Pair unpack(std::uint64_t x) noexcept {return {std::uint32_t(x),std::uint32_t(x>>32)};}
std::uint64_t pack(Pair x) noexcept {return std::uint64_t(x.low)|(std::uint64_t(x.high)<<32);}
bool interval(const void *p,std::size_t available,std::size_t used) noexcept {
    return p&&available>=used&&reinterpret_cast<std::uintptr_t>(p)<=UINTPTR_MAX-used;
}
bool overlaps(const void *a,std::size_t an,const void *b,std::size_t bn) noexcept {
    const auto x=reinterpret_cast<std::uintptr_t>(a),y=reinterpret_cast<std::uintptr_t>(b);
    return x<y+bn&&y<x+an;
}
std::uint32_t loadWord(const std::uint8_t *p) noexcept {
    return std::uint32_t(p[0])|(std::uint32_t(p[1])<<8)|
           (std::uint32_t(p[2])<<16)|(std::uint32_t(p[3])<<24);
}
bool normalOrZero(std::uint32_t value) noexcept {
    const auto magnitude=value&0x7fffffffu;
    return !magnitude||(magnitude>=0x00800000u&&magnitude<0x7f800000u);
}
#if defined(__aarch64__)
// All operations in this scope are owned byte accesses or the pinned, audited
// integer-only exact C mathematical backend. No user callback crosses it.
class NativeScope {
    std::uint64_t control_=0,status_=0;
    bool active_=false,clearPending_=true;
public:
    void prepare() noexcept {
        if(!active_){
            asm volatile("mrs %0,fpcr\n mrs %1,fpsr":"=r"(control_),"=r"(status_)::"memory");
            auto next=control_&~((3ULL<<22)|(1ULL<<24)|(1ULL<<25)|(0x1fULL<<8)|(1ULL<<15)|3ULL);
            next|=(1ULL<<24)|(1ULL<<25); // ARM NEON: RNE,FZ,DN.
            asm volatile("msr fpcr,%0\n isb"::"r"(next):"memory");active_=true;
        }
        if(clearPending_){asm volatile("msr fpsr,xzr":::"memory");clearPending_=false;}
    }
    void discardNativeFlags() noexcept {clearPending_=true;}
    std::uint32_t exceptions() const noexcept {
        std::uint64_t out;asm volatile("mrs %0,fpsr":"=r"(out)::"memory");
        return std::uint32_t(out)&0x9fu;
    }
    ~NativeScope(){
        if(active_)asm volatile("msr fpcr,%0\n msr fpsr,%1\n isb"::"r"(control_),"r"(status_):"memory");
    }
};
std::uint32_t nativeLane(bool multiply,std::uint32_t a,std::uint32_t b) noexcept {
    float x,y;std::memcpy(&x,&a,4);std::memcpy(&y,&b,4);
    volatile float rounded=multiply?x*y:x+y;
    float value=rounded;std::uint32_t bits;std::memcpy(&bits,&value,4);return bits;
}
#endif
class Composition {
    ReadMatrix parent_,local_;
    WriteMatrix destination_;
    Trace *trace_;
    bool fast_,good_=true;
    Pair middle_,accumulator_,term_;
    Result result_;
#if defined(__aarch64__)
    NativeScope native_;
#endif
    void record(AccessKind kind,const std::uint8_t *p,std::uint8_t size,std::uint32_t value) noexcept {
        if(trace_)trace_->accesses[trace_->count++]={kind,reinterpret_cast<std::uintptr_t>(p),value,result_.carry.fpscr,size};
    }
    std::uint32_t read(ReadMatrix matrix,std::size_t offset) noexcept {
        const auto *p=matrix.bytes+offset;const auto value=loadWord(p);
        ++result_.reads;record(AccessKind::Read,p,4,value);return value;
    }
    void write(std::size_t offset,std::uint32_t value,std::uint8_t size=4) noexcept {
        auto *p=destination_.bytes+offset;record(AccessKind::Write,p,size,value);
        for(unsigned i=0;i<size;++i)p[i]=std::uint8_t(value>>(8*i));
        ++result_.writes;
    }
    bool binary(Pair &destination,Pair a,Pair b,bool multiply) noexcept {
#if defined(__aarch64__)
        if(fast_&&normalOrZero(a.low)&&normalOrZero(a.high)&&normalOrZero(b.low)&&normalOrZero(b.high)){
            native_.prepare();Pair out{nativeLane(multiply,a.low,b.low),nativeLane(multiply,a.high,b.high)};
            const auto flags=native_.exceptions();
            if(normalOrZero(out.low)&&normalOrZero(out.high)&&!(flags&~0x10u)){
                destination=out;result_.carry.fpscr|=flags;++result_.nativeOperations;return true;
            }
            native_.discardNativeFlags();
        }
#else
        (void)fast_;
#endif
        // Native speculation is discarded before recomputing the same owned
        // operands. Reads and stores are never repeated by numerical fallback.
        as6_fp_result out{};
        const auto code=multiply?as6_neon_mul_2f32(pack(a),pack(b),result_.carry.fpscr,&out):
                                 as6_neon_add_2f32(pack(a),pack(b),result_.carry.fpscr,&out);
        if(code!=AS6_FP_OK){good_=false;return false;}
        destination=unpack(out.bits);result_.carry.fpscr=out.fpscr;++result_.softwareOperations;return true;
    }
    bool multiply(Pair &destination,Pair a,Pair b) noexcept {return binary(destination,a,b,true);}
    bool add(Pair &destination,Pair a,Pair b) noexcept {return binary(destination,a,b,false);}
    // One affine component, with each source load kept at its original point.
    // Later components can therefore consume earlier destination publications
    // when either input matrix overlaps the output.
    bool products(unsigned column,unsigned row,bool zeroBeforeAdd) noexcept {
        term_.low=read(local_,column*16);
        middle_.low=read(parent_,16+row*4);
        accumulator_.low=read(parent_,row*4);
        if(!multiply(accumulator_,accumulator_,term_))return false;
        term_.low=read(local_,column*16+4);
        if(!multiply(term_,middle_,term_)||!add(accumulator_,accumulator_,term_))return false;
        middle_.low=read(parent_,32+row*4);
        term_.low=read(local_,column*16+8);
        if(!multiply(term_,middle_,term_))return false;
        if(zeroBeforeAdd)write(column*16+12,0);
        return true;
    }
    Result finish(Status status) noexcept {
        result_.status=status;result_.carry.middle=pack(middle_);
        result_.carry.accumulator=pack(accumulator_);result_.carry.term=pack(term_);
        return result_;
    }
public:
    Composition(ReadMatrix parent,ReadMatrix local,WriteMatrix destination,Carry carry,bool fast,Trace *trace) noexcept:
        parent_(parent),local_(local),destination_(destination),trace_(trace),fast_(fast),
        middle_(unpack(carry.middle)),accumulator_(unpack(carry.accumulator)),term_(unpack(carry.term)) {result_.carry=carry;}
    Result run() noexcept {
        for(unsigned column=0;column<3;++column){
            for(unsigned row=0;row<3;++row){
                if(!products(column,row,row==2&&column!=0))return finish(Status::BackendFailure);
                if(!add(term_,accumulator_,term_))return finish(Status::BackendFailure);
                if(row==2&&column==0)write(12,0);
                write(column*16+row*4,term_.low);
            }
        }
        for(unsigned row=0;row<2;++row){
            if(!products(3,row,false)||!add(term_,accumulator_,term_))return finish(Status::BackendFailure);
            accumulator_.low=read(parent_,48+row*4);
            if(!add(term_,term_,accumulator_))return finish(Status::BackendFailure);
            write(48+row*4,term_.low);
        }
        // The final component uses the other accumulator destination, then
        // publishes the identity byte before the last add and structural word.
        if(!products(3,2,false)||!add(accumulator_,accumulator_,term_))return finish(Status::BackendFailure);
        term_.low=read(parent_,56);
        write(64,0,1);
        if(!add(term_,accumulator_,term_))return finish(Status::BackendFailure);
        write(60,0x3f800000u);write(56,term_.low);
        result_.structuralWord=0x3f800000u;
        return finish(good_?Status::Complete:Status::BackendFailure);
    }
};
}
Result compose(ReadMatrix parent,ReadMatrix local,WriteMatrix destination,Carry incoming,bool nativeFast,Trace *trace) noexcept {
    Result rejected;rejected.carry=incoming;
    if(!interval(parent.bytes,parent.size,60)||!interval(local.bytes,local.size,60)||
       !interval(destination.bytes,destination.size,65))return rejected;
    if(incoming.fpscr&(0x9f00u|(7u<<16)|(3u<<20))){rejected.status=Status::UnsupportedEnvironment;return rejected;}
    if(trace){
        if(!interval(trace,sizeof(*trace),sizeof(*trace))||
           overlaps(trace,sizeof(*trace),parent.bytes,60)||overlaps(trace,sizeof(*trace),local.bytes,60)||
           overlaps(trace,sizeof(*trace),destination.bytes,65)){
            rejected.status=Status::InvalidTrace;return rejected;
        }
        trace->count=0;
    }
    Composition composition(parent,local,destination,incoming,nativeFast,trace);
    return composition.run();
}
}
