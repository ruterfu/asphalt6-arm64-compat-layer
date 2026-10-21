#include "CollisionInverseState.hpp"
#include "as6_arm_float.h"
#include <cstring>

#if defined(__FAST_MATH__)
#error "Collision inverse state requires strict IEEE32 arithmetic"
#endif
#pragma STDC FENV_ACCESS ON
#if defined(__clang__)
#pragma clang fp contract(off)
#endif

namespace as6::collision::inverse_state {
namespace {
using Word=std::uint32_t;
struct Pair {Word low=0,high=0;};
Pair unpack(std::uint64_t x) noexcept {return {Word(x),Word(x>>32)};}
std::uint64_t pack(Pair x) noexcept {return std::uint64_t(x.low)|(std::uint64_t(x.high)<<32);}
#if defined(__aarch64__)
bool normalOrZero(Word x) noexcept {
    x&=0x7fffffffu;return !x||(x>=0x00800000u&&x<0x7f800000u);
}
bool normalOrZero(Pair x) noexcept {return normalOrZero(x.low)&&normalOrZero(x.high);}
class NativeScope {
    std::uint64_t control_=0,status_=0;bool active_=false;
public:
    void prepare() noexcept {
        if(!active_){
            asm volatile("mrs %0,fpcr\n mrs %1,fpsr":"=r"(control_),"=r"(status_)::"memory");
            auto next=control_&~((3ULL<<22)|(1ULL<<24)|(1ULL<<25)|(0x1fULL<<8)|(1ULL<<15)|3ULL);
            next|=(1ULL<<24)|(1ULL<<25);
            asm volatile("msr fpcr,%0\n isb"::"r"(next):"memory");active_=true;
        }
        asm volatile("msr fpsr,xzr":::"memory");
    }
    Word exceptions() const noexcept {
        std::uint64_t out;asm volatile("mrs %0,fpsr":"=r"(out)::"memory");return Word(out)&0x9fu;
    }
    ~NativeScope(){
        if(active_)asm volatile("msr fpcr,%0\n msr fpsr,%1\n isb"::"r"(control_),"r"(status_):"memory");
    }
};
Word nativeLane(bool multiply,Word a,Word b) noexcept {
    float x,y;std::memcpy(&x,&a,4);std::memcpy(&y,&b,4);
    volatile float rounded=multiply?x*y:x+y;
    float answer=rounded;Word result;std::memcpy(&result,&answer,4);return result;
}
#endif
class Arithmetic {
    bool good_=true,fast_=false;
#if defined(__aarch64__)
    NativeScope native_;
#endif
    bool accept(Word code,const as6_fp_result &out) noexcept {
        if(code!=AS6_FP_OK||out.reserved){good_=false;return false;}
        fpscr=out.fpscr;++softwareOperations;return true;
    }
    Pair binary(Pair a,Pair b,bool multiply) noexcept {
#if defined(__aarch64__)
        if(fast_&&normalOrZero(a)&&normalOrZero(b)){
            native_.prepare();Pair result{nativeLane(multiply,a.low,b.low),nativeLane(multiply,a.high,b.high)};
            const auto flags=native_.exceptions();
            if(normalOrZero(result)&&!(flags&~0x10u)){
                fpscr|=flags;++nativeOperations;return result;
            }
        }
#endif
        as6_fp_result out{};
        const auto code=multiply?as6_neon_mul_2f32(pack(a),pack(b),fpscr,&out):
                                 as6_neon_add_2f32(pack(a),pack(b),fpscr,&out);
        if(!accept(code,out))return {};
        return unpack(out.bits);
    }
public:
    Word fpscr=0,nativeOperations=0,softwareOperations=0;
    Arithmetic(Word incoming,bool fast) noexcept:fast_(fast),fpscr(incoming){}
    bool good() const noexcept {return good_;}
    Pair multiply(Pair a,Pair b) noexcept {return binary(a,b,true);}
    Pair add(Pair a,Pair b) noexcept {return binary(a,b,false);}
    Word subtractProduct(Word oldDestination,Word n,Word m) noexcept {
#if defined(__aarch64__)
        // VFP controls are distinct from NEON. Native speculation is admitted
        // only in RNE with normal/zero inputs, product, output and no exception
        // other than inexact. All other cases use the exact scalar helper.
        if(fast_&&!(fpscr&(3u<<22))&&normalOrZero(oldDestination)&&normalOrZero(n)&&normalOrZero(m)){
            native_.prepare();float d,x,y;std::memcpy(&d,&oldDestination,4);std::memcpy(&x,&n,4);std::memcpy(&y,&m,4);
            volatile float roundedProduct=x*y;float product=roundedProduct;Word productBits;
            std::memcpy(&productBits,&product,4);
            volatile float rounded=d-product;float answer=rounded;Word result;
            std::memcpy(&result,&answer,4);const auto flags=native_.exceptions();
            if(normalOrZero(productBits)&&normalOrZero(result)&&!(flags&~0x10u)){
                fpscr|=flags;++nativeOperations;return result;
            }
        }
#endif
        as6_fp_result out{};const auto code=as6_vfp_mls_f32(oldDestination,n,m,fpscr,&out);
        if(!accept(code,out))return 0;
        return Word(out.bits);
    }
    Word divide(Word a,Word b) noexcept {
#if defined(__aarch64__)
        if(fast_&&!(fpscr&(3u<<22))&&normalOrZero(a)&&normalOrZero(b)){
            native_.prepare();float x,y;std::memcpy(&x,&a,4);std::memcpy(&y,&b,4);
            volatile float rounded=x/y;float answer=rounded;Word result;
            std::memcpy(&result,&answer,4);const auto flags=native_.exceptions();
            if(normalOrZero(result)&&!(flags&~0x10u)){
                fpscr|=flags;++nativeOperations;return result;
            }
        }
#endif
        as6_fp_result out{};const auto code=as6_vfp_div_f32(a,b,fpscr,&out);
        if(!accept(code,out))return 0;
        return Word(out.bits);
    }
    Word absolute(Word a) noexcept {
        as6_fp_result out{};const auto code=as6_vfp_abs_f32(a,fpscr,&out);
        if(!accept(code,out))return 0;
        return Word(out.bits);
    }
    void compare(Word a,Word b) noexcept {
        as6_fp_result out{};const auto code=as6_vfp_cmpe_f32(a,b,fpscr,&out);
        accept(code,out);
    }
};
template<unsigned Offset,unsigned Width,Word Pc>
void store(Word value,std::array<Word,38> &scratch,const Arithmetic &fp,Result &out) noexcept {
    static_assert(Offset<=148&&Offset%4==0&&(Width==1||Width==4));
    constexpr Word mask=Width==1?0xffu:0xffffffffu;
    value&=mask;scratch[Offset/4]=(scratch[Offset/4]&~mask)|value;
    out.writes[out.writeCount++]={Offset,Width,value,fp.fpscr,Pc};
}
}

Result compute(const Input &input,bool nativeFast) noexcept {
    Result result;result.fp=input.fp;result.gpr=input.gpr;result.fpscr=input.fpscr;
    if(input.fpscr&(0x9f00u|(7u<<16)|(3u<<20)))return result;
    std::array<Pair,16> pair{};
    for(unsigned i=0;i<16;++i)pair[i]=unpack(input.fp[i]);
    // Every original scratch read is dominated by its own earlier store.
    // Original matrix input [152,216) cannot alias scratch [0,149).
    std::array<Word,38> scratch{};
    Arithmetic fp(input.fpscr,nativeFast);
    const auto finish=[&](Word nextPc,Word instructions) noexcept {
        result.status=fp.good()?Status::Complete:Status::BackendFailure;
        result.nextPc=nextPc;result.originalInstructions=instructions;
        result.fpscr=fp.fpscr;result.nativeOperations=fp.nativeOperations;
        result.softwareOperations=fp.softwareOperations;
        for(unsigned i=0;i<16;++i)result.fp[i]=pack(pair[i]);
        return result;
    };
    // The fixed compiler-visible schedule preserves scalar low-lane updates,
    // paired high-lane carry, exception order and each original scratch write.
    // There is no runtime instruction stream, opcode switch or guest access.
#include "InverseSchedule.inc"
    return finish(InverseExit,220);
}
}
