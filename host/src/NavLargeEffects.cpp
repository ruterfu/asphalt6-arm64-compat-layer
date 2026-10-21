#include "NavLargeEffects.hpp"
#include "NavIeee32.hpp"
#include <cstring>
#if defined(__FAST_MATH__)
#error "NavLine requires strict float32 operations"
#endif
#pragma STDC FENV_ACCESS ON
#if defined(__clang__)
#pragma clang fp contract(off)
#endif
namespace as6::navigation::large_effects {
namespace {
namespace fp=as6::math::ieee32;
using Word=std::uint32_t;
constexpr Word MinusOne=0xbf800000u,One=0x3f800000u;
Word word(float value) noexcept {Word bits;std::memcpy(&bits,&value,4);return bits;}
float value(Word bits) noexcept {float f;std::memcpy(&f,&bits,4);return f;}
bool normalOrZero(Word bits) noexcept {bits&=0x7fffffffu;return !bits||(bits>=0x00800000u&&bits<0x7f800000u);}
struct ExactMath {
 fp::Environment environment{};bool valid=true,compared=false;
 explicit ExactMath(FloatMode mode){environment.mode.rounding=fp::Rounding(mode.rounding);environment.mode.flushToZero=mode.flushToZero;environment.mode.defaultNaN=mode.defaultNaN;}
 Word operation(fp::Operation op,Word a,Word b) noexcept {const auto r=fp::evaluate(op,a,b,environment,false);valid &= r.status==fp::Status::Complete;environment=r.environment;return r.bits;}
 Word sub(Word a,Word b)noexcept{return operation(fp::Operation::SubtractPairLow,a,b);}
 Word mul(Word a,Word b)noexcept{return operation(fp::Operation::MultiplyPairLow,a,b);}
 Word add(Word a,Word b)noexcept{return operation(fp::Operation::AddPairLow,a,b);}
 Word divide(Word a,Word b)noexcept{return operation(fp::Operation::Divide,a,b);}
 fp::Relation compare(Word a,Word b,bool signaling=true)noexcept{const auto r=fp::evaluate(signaling?fp::Operation::CompareSignaling:fp::Operation::CompareQuiet,a,b,environment,false);valid &= r.status==fp::Status::Complete;environment=r.environment;compared=true;return r.relation;}
};
// One synchronous native segment. No callback, allocation, write or scheduler
// access occurs before the scope has restored the caller's full FP state.
struct HostScope {
 std::uint64_t control,status;
 HostScope(){asm volatile("mrs %0,fpcr\n mrs %1,fpsr":"=r"(control),"=r"(status)::"memory");
  const auto next=control&~((3ULL<<22)|(1ULL<<24)|(1ULL<<25)|(0x1fULL<<8)|(1ULL<<15)|3ULL);
  const std::uint64_t zero=0;asm volatile("msr fpcr,%0\n msr fpsr,%1\n isb"::"r"(next),"r"(zero):"memory");}
 ~HostScope(){asm volatile("msr fpcr,%0\n msr fpsr,%1\n isb"::"r"(control),"r"(status):"memory");}
 std::uint32_t exceptions()const {std::uint64_t flags;asm volatile("mrs %0,fpsr":"=r"(flags)::"memory");return std::uint32_t(flags)&0x9f;}
};
struct NativeMath {
 bool valid=true,compared=false;
 std::uint32_t finalNzcv=0;
 bool checked(Word a) noexcept {valid=valid&&normalOrZero(a);return valid;}
 Word operation(fp::Operation op,Word a,Word b) noexcept {
  if(!checked(a)||!checked(b))return 0;
  Word out=0;
  switch(op){case fp::Operation::AddPairLow:out=word(value(a)+value(b));break;
   case fp::Operation::SubtractPairLow:out=word(value(a)-value(b));break;
   case fp::Operation::MultiplyPairLow:out=word(value(a)*value(b));break;
   case fp::Operation::Divide:out=word(value(a)/value(b));break;
   default:valid=false;return 0;}
  // An exact subnormal need not raise UFC, so flags alone are insufficient.
  return checked(out)?out:0;
 }
 Word sub(Word a,Word b) noexcept {return operation(fp::Operation::SubtractPairLow,a,b);}
 Word mul(Word a,Word b) noexcept {return operation(fp::Operation::MultiplyPairLow,a,b);}
 Word add(Word a,Word b) noexcept {return operation(fp::Operation::AddPairLow,a,b);}
 Word divide(Word a,Word b) noexcept {return operation(fp::Operation::Divide,a,b);}
 fp::Relation compare(Word a,Word b,bool=true) noexcept {
  if(!checked(a)||!checked(b))return fp::Relation::Equal;
  compared=true;
  if(a==b||(!(a&0x7fffffffu)&&!(b&0x7fffffffu))){finalNzcv=0x60000000u;return fp::Relation::Equal;}
  const bool less=((a^b)&0x80000000u)?bool(a>>31):((a>>31)?a>b:a<b);
  finalNzcv=less?0x80000000u:0x20000000u;
  return less?fp::Relation::Less:fp::Relation::Greater;
 }
};
// The control flow and point geometry are shared by native and exact policies.
// The exact policy retains the original independent binary32 dependencies.
template<class Number>struct Geometry: Number {
 using Number::Number;
 using Number::sub;using Number::mul;using Number::add;using Number::divide;using Number::compare;
    Word distance(Point q,Point p) {
        // Original order: dx,dy,dy²,dz,dx²,(dx²+dy²),dz²,+dz².
        const auto dx=sub(word(q.x),word(p.x));
        const auto dy=sub(word(q.y),word(p.y));
        const auto yy=mul(dy,dy);
        const auto dz=sub(word(q.z),word(p.z));
        const auto xx=mul(dx,dx);
        const auto xy=add(xx,yy);
        const auto zz=mul(dz,dz);
        return add(xy,zz);
    }
    Word projection(Point q,Point a,Point b) {
        // Projection uses X/Z only. Preserve separate binary32 operations.
        const auto dx=sub(word(b.x),word(a.x));
        const auto qx=sub(word(q.x),word(a.x));
        const auto x=mul(dx,qx);
        const auto qz=sub(word(q.z),word(a.z));
        const auto dz=sub(word(b.z),word(a.z));
        const auto z=mul(dz,qz);
        const auto numerator=add(x,z);
        const auto zz=mul(dz,dz);
        const auto xx=mul(dx,dx);
        const auto denominator=add(xx,zz);
        return divide(numerator,denominator);
    }
    bool better(Word best,Word distance,bool &initial) {
        initial=fp::equal(compare(best,MinusOne,false));
        return initial||fp::greaterOrdered(compare(best,distance));
    }
};
FloatingPointEffects effects(const ExactMath &m) noexcept {return {m.environment.exceptionBits&0x9f,m.environment.nzcv,m.compared};}
FloatingPointEffects effects(const NativeMath &m) noexcept {return {0,m.finalNzcv,m.compared};}
Result tentativeFailure() noexcept {Result out;out.status=Status::ArithmeticFailure;return out;}
Result capacityDeclined() noexcept {Result out;out.status=Status::CapacityDeclined;return out;}
template<class Number>Result calculate(PointSpan span,Point q,Number &math) noexcept {
 Result out;
    // Exact original ARM basic-block instruction ledger, including predicated
    // instruction slots even when their stores/moves are not taken.
    out.originalInstructions=22; // 18320c..183260, supported positive count
    out.scratchWrites[out.scratchWriteCount++]=-1;
    Word best=MinusOne;
    const auto n=std::int32_t(span.count);
    Word previousProjection=0;
    for(std::int32_t i=0;i<n;++i){
        const auto previous=i?i-1:n-1;
        const auto beforePrevious=previous?previous-1:n-1;
        out.originalInstructions+=50; // 1832f4..1833b8
        const auto t=math.projection(q,span.points[previous],span.points[i]);
        if(!math.valid)return tentativeFailure();
        const auto afterStart=math.compare(t,0);
        if(!math.valid)return tentativeFailure();
        bool eligible=false;
        if(fp::atLeastOrdered(afterStart)){
            out.originalInstructions+=5; // 183264..183274
            const auto beforeEnd=math.compare(t,One);
            if(!math.valid)return tentativeFailure();
            eligible=!fp::greaterOrdered(beforeEnd);
        }else{
            out.originalInstructions+=17; // 1833bc..1833fc
            // For i>0 this is exactly the preceding iteration's projection.
            // Inputs/mode are immutable during this query. Repeating arithmetic
            // only re-raises the same sticky exceptions; divide changes no NZCV.
            // Keep the original instruction ledger and all comparisons below.
            const auto u=i?previousProjection:
                math.projection(q,span.points[beforePrevious],span.points[previous]);
            if(!math.valid)return tentativeFailure();
            const auto previousEnd=math.compare(u,One);
            if(!math.valid)return tentativeFailure();
            eligible=fp::greaterOrdered(previousEnd);
        }
        previousProjection=t;
        out.originalInstructions+=2; // 183278..18327c
        if(eligible){
            out.originalInstructions+=16; // 183280..1832bc
            const auto distance=math.distance(q,span.points[i]);
            if(!math.valid)return tentativeFailure();
            bool initial=false;
            const bool better=math.better(best,distance,initial);
            if(!math.valid)return tentativeFailure();
            if(!initial)out.originalInstructions+=3; // 1832c0..1832c8
            if(better){
                // Capacity is an admission limit, not an arithmetic failure.
                // Check before recording this improvement or any official pair.
                if(out.scratchWriteCount>=out.scratchWrites.size())return capacityDeclined();
                out.originalInstructions+=5; // 1832cc..1832dc
                best=distance;out.first=i;out.second=previous;
                out.scratchWrites[out.scratchWriteCount++]=previous;
            }
        }
        out.originalInstructions+=5; // 1832e0..1832f0
    }
    out.originalInstructions+=5; // 183400..183410, initial ordered pair writes
    if(out.first<0){
        out.usedNearestPointFallback=true;best=MinusOne;
        out.originalInstructions+=5; // 18342c..18343c
        std::int32_t nearest=-1;
        for(std::int32_t i=0;i<n;++i){
            out.originalInstructions+=15; // 183440..183478
            const auto distance=math.distance(q,span.points[i]);
            if(!math.valid)return tentativeFailure();
            bool initial=false;
            const bool better=math.better(best,distance,initial);
            if(!math.valid)return tentativeFailure();
            if(!initial)out.originalInstructions+=4; // 18347c..183488
            out.originalInstructions+=better?5:4; // 1834a4..b4 or 18348c..98
            if(i+1<n)out.originalInstructions+=2; // 18349c..1834a0
            if(better){best=distance;nearest=i;}
        }
        out.originalInstructions+=11+(nearest==0?2:0)+34;
        // 1834b8..1834e0, optional 183588..8c, 1834e4..183568.
        const auto next=nearest+1<n?nearest+1:0;
        const auto previous=nearest?nearest-1:n-1;
        const auto nextDistance=math.distance(q,span.points[next]);
        if(!math.valid)return tentativeFailure();
        const auto previousDistance=math.distance(q,span.points[previous]);
        if(!math.valid)return tentativeFailure();
        const auto closer=math.compare(nextDistance,previousDistance);
        if(!math.valid)return tentativeFailure();
        if(fp::greaterOrdered(closer)){out.first=nearest;out.second=previous;}
        else {out.first=next;out.second=nearest;}
    }
 out.originalInstructions+=6; // 183414..183428 public epilogue
 out.floatingPoint=effects(math);
 out.status=Status::Complete;return out;
}
}
Result closestSegment(PointSpan span,Point q,FloatMode mode) noexcept {
 Result out;
 if(!span.points||!span.count||span.count>65536)return out;
 if(mode.rounding>3){out.status=Status::UnsupportedFloatMode;return out;}
 if(mode.rounding==0){
  bool completed=false,capacityFailure=false;
  {
   HostScope scope;Geometry<NativeMath> math;
   auto tentative=calculate(span,q,math);
   // Native output is tentative until arithmetic and late exceptions pass.
   // Normal results can underflow to zero without an abnormal result word.
   capacityFailure=tentative.status==Status::CapacityDeclined;
   const auto flags=scope.exceptions();
   if(!capacityFailure&&math.valid&&tentative.status==Status::Complete&&!(flags&0x8f)){
    tentative.floatingPoint.exceptionDelta=flags;
    out=tentative;completed=true;
   }
  } // Restore the caller's full FP state before any decline/recomputation.
  // A capacity failure cannot become admissible by repeating exact arithmetic.
  if(capacityFailure)return capacityDeclined();
  if(completed){out.usedNativeArithmetic=true;return out;}
 }
 Geometry<ExactMath> math(mode);return calculate(span,q,math);
}
}
