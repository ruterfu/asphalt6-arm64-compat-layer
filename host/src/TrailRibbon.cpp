#include "TrailRibbon.hpp"
#include <algorithm>
#include <cfenv>
#include <cmath>
#include <cstring>
#include <limits>
#include <new>
#include <utility>

#if defined(__FAST_MATH__)
#error "Trail geometry requires strict separate float32 arithmetic"
#endif
#pragma STDC FENV_ACCESS ON
#if defined(__clang__)
#pragma clang fp contract(off)
#endif
namespace as6::geometry::trail {
namespace {
struct Reject {Status status;};
std::uint32_t bits(float x){std::uint32_t u;std::memcpy(&u,&x,4);return u;}
bool normalOrZero(float x){const auto u=bits(x)&0x7fffffffu;return !u||(u>=0x00800000u&&u<0x7f800000u);}
void input(float x){if(!normalOrZero(x))throw Reject{Status::UnsupportedInput};}
void input(Vec3 v){input(v.x);input(v.y);input(v.z);}
class HostFloatScope {
#if defined(__aarch64__)
 std::uint64_t control_,status_;
#else
 std::fenv_t environment_{};
#endif
public:
 explicit HostFloatScope(FloatMode mode){
#if defined(__aarch64__)
  __asm__ volatile("mrs %0, fpcr":"=r"(control_)::"memory");
  __asm__ volatile("mrs %0, fpsr":"=r"(status_)::"memory");
  auto control=control_&~((3ULL<<22)|(1ULL<<24)|(1ULL<<25)|(0x1fULL<<8)|(1ULL<<15)|3ULL);
  if(mode.flushToZero)control|=1ULL<<24;if(mode.defaultNaN)control|=1ULL<<25;
  const std::uint64_t zero=0;
  __asm__ volatile("msr fpcr,%0\n msr fpsr,%1\n isb"::"r"(control),"r"(zero):"memory");
#else
  (void)mode;if(std::fegetenv(&environment_)||std::fesetround(FE_TONEAREST))throw Reject{Status::UnsupportedEnvironment};std::feclearexcept(FE_ALL_EXCEPT);
#endif
 }
 ~HostFloatScope(){
#if defined(__aarch64__)
  __asm__ volatile("msr fpcr,%0\n msr fpsr,%1\n isb"::"r"(control_),"r"(status_):"memory");
#else
  std::fesetenv(&environment_);
#endif
 }
 std::uint32_t exceptions()const{
#if defined(__aarch64__)
  std::uint64_t s;__asm__ volatile("mrs %0,fpsr":"=r"(s)::"memory");return std::uint32_t(s)&0x9fu;
#else
  auto s=std::fetestexcept(FE_ALL_EXCEPT);return ((s&FE_INVALID)?1:0)|((s&FE_DIVBYZERO)?2:0)|((s&FE_OVERFLOW)?4:0)|((s&FE_UNDERFLOW)?8:0)|((s&FE_INEXACT)?16:0);
#endif
 }
};
struct Arithmetic {
 FloatEffects effects;
 static float checked(float x){if(!normalOrZero(x))throw Reject{Status::UnsupportedArithmetic};return x;}
 float add(float a,float b)const{return checked(a+b);}
 float sub(float a,float b)const{return checked(a-b);}
 float mul(float a,float b)const{return checked(a*b);}
 float div(float a,float b)const{return checked(a/b);}
 float sqrt(float a)const{return checked(std::sqrt(a));}
 int compare(float a,float b){effects.compared=true;if(a<b){effects.nzcv=0x80000000u;return -1;}if(a>b){effects.nzcv=0x20000000u;return 1;}effects.nzcv=0x60000000u;return 0;}
 Vec3 add(Vec3 a,Vec3 b)const{return{add(a.x,b.x),add(a.y,b.y),add(a.z,b.z)};}
 Vec3 sub(Vec3 a,Vec3 b)const{return{sub(a.x,b.x),sub(a.y,b.y),sub(a.z,b.z)};}
 Vec3 mul(Vec3 a,float b)const{return{mul(a.x,b),mul(a.y,b),mul(a.z,b)};}
 float squared(Vec3 a)const{return add(add(mul(a.x,a.x),mul(a.y,a.y)),mul(a.z,a.z));}
};
void write(std::vector<BytePatch>&patches,std::size_t offset,const void *source,std::size_t bytes){
 if(!bytes)return;
 auto first=std::lower_bound(patches.begin(),patches.end(),offset,[](const auto &patch,std::size_t start){return patch.offset+patch.bytes.size()<start;});
 auto last=first;auto start=offset,end=offset+bytes;
 while(last!=patches.end()&&last->offset<=end){start=std::min(start,last->offset);end=std::max(end,last->offset+last->bytes.size());++last;}
 BytePatch merged;merged.offset=start;merged.bytes.resize(end-start);
 for(auto prior=first;prior!=last;++prior)std::memcpy(merged.bytes.data()+prior->offset-start,prior->bytes.data(),prior->bytes.size());
 // Copy the latest store last, even when its bytes equal an earlier value.
 std::memcpy(merged.bytes.data()+offset-start,source,bytes);
 first=patches.erase(first,last);patches.insert(first,std::move(merged));
}
struct Update {
 const Pose &pose;const Config &config;const IndexSource &source;Result &out;Arithmetic f;
 void stateWrite(StateField field){out.stateWrites|=field;}
 void cursor(unsigned value){if(value>config.vertexCapacity)throw Reject{Status::InvalidState};out.state.vertexCursor=std::uint16_t(value);stateWrite(VertexCursor);}
 void rewindPair(){auto old=int(out.state.vertexCursor)-2;if(old<0)old+=config.vertexCapacity;cursor(unsigned(old));}
 void indexRewind(){auto old=int(out.state.indexCursor)-6;if(old<0)old+=config.indexCapacity;if(old<0||old>config.indexCapacity)throw Reject{Status::InvalidState};out.state.indexCursor=std::uint16_t(old);stateWrite(IndexCursor);}
 void removeCount(){if(out.state.usedIndices<6)throw Reject{Status::InvalidState};out.state.usedIndices-=6;stateWrite(UsedIndices);}
 std::array<std::uint8_t,4> color(std::uint8_t alpha){
  auto c=config.colorBytes;c[3]=alpha;
  if(config.premultiplyColor){const auto scale=f.div(float(alpha),255.0f);for(unsigned j=0;j<3;j++){const auto x=f.mul(float(c[j]),scale);const auto n=x>0?std::uint32_t(x):0u;c[j]=std::uint8_t(std::min(n,255u));}}
  return c;
 }
 Vec3 offset(float halfWidth){
  const auto axis=[&](float x,float y,float z){return f.mul(halfWidth,f.add(f.sub(f.mul(y,0.0f),x),f.mul(z,0.0f)));};
  return{axis(pose.axes[0].x,pose.axes[1].x,pose.axes[2].x),axis(pose.axes[0].y,pose.axes[1].y,pose.axes[2].y),axis(pose.axes[0].z,pose.axes[1].z,pose.axes[2].z)};
 }
 void pair(Vec3 center,Vec3 widthOffset,const std::array<std::uint8_t,4>&c){
  const auto start=out.state.vertexCursor;if(std::size_t(start)+2>config.vertexCapacity)throw Reject{Status::InvalidState};
  const auto left=config.flipU?config.uEndpoints[0]:config.uEndpoints[1];
  const auto right=config.flipU?config.uEndpoints[1]:config.uEndpoints[0];
  Vertex36 a{f.add(widthOffset,center),{left,out.state.v},{0,1,0},c};
  Vertex36 b{f.sub(center,widthOffset),{right,out.state.v},{0,1,0},c};
  const std::array<Vertex36,2> pair{a,b};write(out.vertexWrites,std::size_t(start)*36,pair.data(),sizeof(pair));cursor(unsigned(start)+2);
 }
 void tailColor(unsigned vertex,const std::array<std::uint8_t,4>&c){if(vertex>=config.vertexCapacity)throw Reject{Status::InvalidState};write(out.vertexWrites,std::size_t(vertex)*36+32,c.data(),c.size());}
 void addQuad(bool ended){
  const auto p=out.state.indexCursor;const auto v=out.state.vertexCursor,cap=config.vertexCapacity,base=config.baseVertex;
  if(std::size_t(p)+6>config.indexCapacity)throw Reject{Status::InvalidState};
  const auto previous=[&](unsigned back){return std::uint16_t((unsigned(cap)+v-back)%cap+base);};
  std::array<std::uint16_t,6> indices;
  if(ended)indices={std::uint16_t(base+v),std::uint16_t(base+v+1),std::uint16_t(base+v),std::uint16_t(base+v),std::uint16_t(base+v+1),std::uint16_t(base+v)};
  else indices={std::uint16_t(base+v),previous(1),previous(2),std::uint16_t(base+v),std::uint16_t(base+v+1),previous(1)};
  out.state.indexCursor=std::uint16_t(p+6);stateWrite(IndexCursor);write(out.indexWrites,std::size_t(p)*2,indices.data(),sizeof(indices));
  if(out.state.usedIndices<config.indexCapacity){out.state.usedIndices+=6;stateWrite(UsedIndices);}
 }
 void remember(Vec3 point,bool ended){out.state.lastPosition=point;out.state.lastAlpha=config.colorBytes[3];out.state.lastEnded=ended;stateWrite(LastPosition);stateWrite(LastAlpha);stateWrite(LastEnded);}
 void run(){
  if(out.state.vertexCursor>=config.vertexCapacity)cursor(0);
  if(out.state.indexCursor>=config.indexCapacity){
   if(config.indexCapacity<6||out.state.indexCursor<6)throw Reject{Status::InvalidState};
   const auto count=std::size_t(config.indexCapacity-6);
   if(count){std::vector<std::uint16_t> indices(count);if(!source.readIndices(6,indices.data(),count))throw Reject{Status::SourceFailure};write(out.indexWrites,0,indices.data(),count*2);}
   out.state.indexCursor-=6;stateWrite(IndexCursor);removeCount();
  }
  input(pose.position);for(const auto &a:pose.axes)input(a);input(config.width);
  auto halfWidth=f.mul(config.width,.5f);
  if(config.widthUsesAlpha)halfWidth=f.mul(halfWidth,f.div(float(config.colorBytes[3]),255.0f));
  const auto widthOffset=offset(halfWidth);
  if(out.state.first){out.state.first=false;stateWrite(First);out.state.v=0;stateWrite(V);pair(pose.position,widthOffset,color(config.fadeTail?0:config.colorBytes[3]));remember(pose.position,false);return;}
  input(out.state.lastPosition);input(config.minimumDistance);
  const auto delta=f.sub(out.state.lastPosition,pose.position);const auto distanceSquared=f.squared(delta),minimumSquared=f.mul(config.minimumDistance,config.minimumDistance);
  if(f.compare(minimumSquared,distanceSquared)>0)return;
  auto currentColor=color(config.colorBytes[3]);
  const bool ended=config.colorBytes[3]==0&&out.state.lastAlpha==0;
  input(out.state.v);input(config.uvStep);out.state.v=f.add(out.state.v,config.uvStep);stateWrite(V);
  auto remembered=pose.position;
  if(out.state.lastEnded&&ended){rewindPair();indexRewind();removeCount();}
  else if(config.smoothJoin&&out.state.usedIndices>6){
   const auto savedCursor=out.state.vertexCursor;rewindPair();
   const auto length=f.sqrt(distanceSquared);auto radius=f.mul(length,.5f);
   if(f.compare(radius,halfWidth)>0)radius=halfWidth;
   auto direction=delta;
   if(f.compare(distanceSquared,0)!=0)direction=f.mul(direction,f.div(1,length));
   remembered=f.add(f.mul(direction,radius),pose.position);
   pair(remembered,widthOffset,currentColor);cursor(savedCursor);
   currentColor=color(0);
  }
  addQuad(ended);pair(pose.position,widthOffset,currentColor);
  if(config.fadeTail){const auto c=color(0);const auto n=config.vertexCapacity;tailColor((unsigned(out.state.vertexCursor)+2)%n,c);tailColor((unsigned(out.state.vertexCursor)+3)%n,c);}
  remember(remembered,ended);
 }
};
}
Result update(const Pose &pose,const Config &config,const State &state,const IndexSource &source,FloatMode mode)noexcept{
 Result result;result.state=state;
 if(mode.rounding!=Rounding::Nearest||mode.exceptionEnables||mode.vectorLength||mode.vectorStride){result.status=Status::UnsupportedEnvironment;return result;}
 if(config.vertexCapacity<4||config.vertexCapacity>32766||(config.vertexCapacity&1)||
    config.indexCapacity<6||config.indexCapacity>32766||config.indexCapacity%6||
    state.vertexCursor>config.vertexCapacity||(state.vertexCursor&1)||
    state.indexCursor>config.indexCapacity||state.indexCursor%6||
    state.usedIndices>config.indexCapacity||state.usedIndices%6)return result;
 try{
  HostFloatScope host(mode);input(pose.position);for(const auto &axis:pose.axes)input(axis);input(config.width);input(config.minimumDistance);input(config.uvStep);input(config.uEndpoints[0]);input(config.uEndpoints[1]);input(state.v);input(state.lastPosition);
  Update operation{pose,config,source,result,{}};operation.run();const auto exceptions=host.exceptions();if(exceptions&0x8fu)throw Reject{Status::UnsupportedArithmetic};
  result.floatingPoint=operation.f.effects;result.floatingPoint.exceptionBits=exceptions;result.status=Status::Complete;
 }catch(const Reject&r){result.status=r.status;}catch(const std::bad_alloc&){result.status=Status::ResourceLimit;}catch(...){result.status=Status::UnsupportedInput;}
 if(result.status!=Status::Complete){result.state=state;result.vertexWrites.clear();result.indexWrites.clear();result.stateWrites=0;result.floatingPoint={};}
 return result;
}
}
