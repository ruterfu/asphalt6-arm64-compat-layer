#include "NavIeee32.hpp"
#include "as6_arm_float.h"
#include <cstring>
#if defined(__FAST_MATH__)
#error "IEEE32 prototype requires strict float32"
#endif
#pragma STDC FENV_ACCESS ON
#if defined(__clang__)
#pragma clang fp contract(off)
#endif
namespace as6::math::ieee32 {
namespace {
std::uint32_t pack(Environment e){return (std::uint32_t(e.mode.rounding)<<22)|(std::uint32_t(e.mode.flushToZero)<<24)|(std::uint32_t(e.mode.defaultNaN)<<25)|(std::uint32_t(e.mode.alternativeHalf)<<26)|(std::uint32_t(e.mode.exceptionEnables)<<8)|(std::uint32_t(e.mode.vectorLength)<<16)|(std::uint32_t(e.mode.vectorStride)<<20)|(e.exceptionBits&0x9fu)|(e.nzcv&0xf0000000u);}
bool supported(Mode m){return std::uint8_t(m.rounding)<4&&!m.exceptionEnables&&!m.vectorLength&&!m.vectorStride;}
bool normalOrZero(std::uint32_t a){a&=0x7fffffffu;return !a||(a>=0x00800000u&&a<0x7f800000u);}
float value(std::uint32_t a){float out;std::memcpy(&out,&a,4);return out;}
std::uint32_t bits(float a){std::uint32_t out;std::memcpy(&out,&a,4);return out;}
std::int32_t integer(std::uint32_t a){std::int32_t out;std::memcpy(&out,&a,4);return out;}
std::uint32_t integerBits(std::int32_t a){std::uint32_t out;std::memcpy(&out,&a,4);return out;}
Relation relation(std::uint32_t nibble){switch(nibble&15){case 8:return Relation::Less;case 6:return Relation::Equal;case 2:return Relation::Greater;default:return Relation::Unordered;}}
bool pair(Operation op){return op==Operation::AddPairLow||op==Operation::SubtractPairLow||op==Operation::MultiplyPairLow;}
struct HostScope {
 std::uint64_t control,status;
 explicit HostScope(Mode mode,bool isPair){
  asm volatile("mrs %0,fpcr\n mrs %1,fpsr":"=r"(control),"=r"(status)::"memory");
  auto next=control&~((3ULL<<22)|(1ULL<<24)|(1ULL<<25)|(0x1fULL<<8)|(1ULL<<15)|3ULL);
  if(isPair||mode.flushToZero)next|=1ULL<<24;if(isPair||mode.defaultNaN)next|=1ULL<<25;
  const std::uint64_t zero=0;asm volatile("msr fpcr,%0\n msr fpsr,%1\n isb"::"r"(next),"r"(zero):"memory");
 }
 ~HostScope(){asm volatile("msr fpcr,%0\n msr fpsr,%1\n isb"::"r"(control),"r"(status):"memory");}
 std::uint32_t exceptions()const {std::uint64_t out;asm volatile("mrs %0,fpsr":"=r"(out)::"memory");return std::uint32_t(out)&0x9fu;}
};
bool fast(Operation op,std::uint32_t a,std::uint32_t b,Result &out){
 if(op==Operation::Absolute){out.bits=a&0x7fffffffu;out.path=Path::Bits;return true;}
 const bool unary=op==Operation::FromSigned||op==Operation::ToSignedTowardZero;
 if((op!=Operation::FromSigned&&!normalOrZero(a))||(!unary&&!normalOrZero(b)))return false;
 if(!pair(op)&&out.environment.mode.rounding!=Rounding::Nearest)return false;
 HostScope scope(out.environment.mode,pair(op));std::uint32_t result=0;
 switch(op){
 case Operation::AddPairLow:result=bits(value(a)+value(b));break;
 case Operation::SubtractPairLow:result=bits(value(a)-value(b));break;
 case Operation::MultiplyPairLow:result=bits(value(a)*value(b));break;
 case Operation::Divide:result=bits(value(a)/value(b));break;
 case Operation::FromSigned:result=bits(float(integer(a)));break;
 case Operation::ToSignedTowardZero:{const auto x=value(a);if(x<-2147483648.0f||x>=2147483648.0f)return false;result=integerBits(std::int32_t(x));break;}
 case Operation::CompareQuiet:case Operation::CompareSignaling:{
  const auto x=value(a),y=value(b);const auto nibble=x<y?8u:x>y?2u:6u;
  out.relation=relation(nibble);out.environment.nzcv=nibble<<28;result=nibble;break;
 }
 case Operation::Absolute:return false;
 }
 const auto raised=scope.exceptions();if(raised&0x8fu)return false;
 if((pair(op)||op==Operation::Divide||op==Operation::FromSigned)&&!normalOrZero(result))return false;
 out.bits=result;out.environment.exceptionBits|=raised;out.path=Path::Native;return true;
}
}
Result evaluate(Operation op,std::uint32_t a,std::uint32_t b,Environment environment,bool nativeFast)noexcept{
 Result out;out.environment=environment;
 if(std::uint8_t(op)>std::uint8_t(Operation::CompareSignaling))return out;
 if(!supported(environment.mode)){out.status=Status::UnsupportedEnvironment;return out;}
 // Native speculation lives in an isolated HostScope. If it produces a rare
 // result/exception, no tentative bits or flags are published; software retries
 // precisely this mathematical operation with its original owned operands.
 if(nativeFast&&fast(op,a,b,out)){out.status=Status::Complete;return out;}
 out.environment=environment;out.path=Path::Software;
 as6_fp_result computed{};const auto control=pack(environment);std::uint32_t status=AS6_FP_UNSUPPORTED_OPERATION;
 switch(op){
 case Operation::AddPairLow:status=as6_neon_add_2f32(std::uint64_t(a),std::uint64_t(b),control,&computed);break;
 case Operation::SubtractPairLow:status=as6_neon_sub_2f32(std::uint64_t(a),std::uint64_t(b),control,&computed);break;
 case Operation::MultiplyPairLow:status=as6_neon_mul_2f32(std::uint64_t(a),std::uint64_t(b),control,&computed);break;
 case Operation::Divide:status=as6_vfp_div_f32(a,b,control,&computed);break;
 case Operation::Absolute:status=as6_vfp_abs_f32(a,control,&computed);break;
 case Operation::FromSigned:status=as6_vfp_s32_to_f32(a,control,&computed);break;
 case Operation::ToSignedTowardZero:status=as6_vfp_f32_to_s32_rtz(a,control,&computed);break;
 case Operation::CompareQuiet:status=as6_vfp_cmp_f32(a,b,control,&computed);break;
 case Operation::CompareSignaling:status=as6_vfp_cmpe_f32(a,b,control,&computed);break;
 }
 if(status!=AS6_FP_OK){out.status=status==AS6_FP_UNSUPPORTED_ENVIRONMENT?Status::UnsupportedEnvironment:Status::LibraryRejected;return out;}
 out.bits=std::uint32_t(computed.bits);out.environment.exceptionBits=computed.fpscr&0x9fu;out.environment.nzcv=computed.fpscr&0xf0000000u;
 if(op==Operation::CompareQuiet||op==Operation::CompareSignaling)out.relation=relation(out.bits);
 out.status=Status::Complete;return out;
}
bool equal(Relation r)noexcept{return r==Relation::Equal;}
bool notEqual(Relation r)noexcept{return r!=Relation::Equal;}
bool negativeComparison(Relation r)noexcept{return r==Relation::Less;}
bool notNegativeComparison(Relation r)noexcept{return r!=Relation::Less;}
bool lessIncludingUnordered(Relation r)noexcept{return r==Relation::Less||r==Relation::Unordered;}
bool atMostIncludingUnordered(Relation r)noexcept{return r!=Relation::Greater;}
bool greaterOrdered(Relation r)noexcept{return r==Relation::Greater;}
bool atLeastOrdered(Relation r)noexcept{return r==Relation::Equal||r==Relation::Greater;}
}
