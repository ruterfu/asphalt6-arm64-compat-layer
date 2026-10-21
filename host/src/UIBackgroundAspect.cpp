#include "UIBackgroundAspect.hpp"
#include "DecodedArtwork.hpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <new>
#pragma clang fp contract(off)
namespace as6_ui_background {
namespace {
struct ArtSpec {unsigned kind,width,height;const char*sha;};
struct Patch {unsigned kind,x0,y0,x1,y1;double a,b,c,d,tx,ty,stage_w,stage_h;bool mirror_grid;};
struct Spec {unsigned asset,width,height,descriptor,type;size_t file_size;const char*sha;const Patch*patches;size_t patch_count;};
#include "ui_art_pins.hpp"
#include "ui_profile_pins.hpp"
const Spec* Find(Profile p){for(const auto&s:kSpecs)if(s.asset==static_cast<unsigned>(p))return &s;return nullptr;}
unsigned U16(const uint8_t*p){return unsigned(p[0])|unsigned(p[1])<<8;}
bool DecodeRLE(const uint8_t*source,size_t bytes,size_t pixels,std::vector<uint8_t>&decoded,size_t&tail){
 decoded.resize(pixels*4);size_t input=18,output=0;
 while(output<pixels){
  if(input>=bytes)return false;const unsigned packet=source[input++],count=(packet&127)+1;
  if(count>pixels-output)return false;
  if(packet&128){if(bytes-input<4)return false;for(unsigned i=0;i<count;i++)memcpy(decoded.data()+(output+i)*4,source+input,4);input+=4;}
  else{const size_t n=size_t(count)*4;if(bytes-input<n)return false;memcpy(decoded.data()+output*4,source+input,n);input+=n;}
  output+=count;
 }
 tail=input;return true;
}
std::vector<uint8_t> EncodeRLE(const uint8_t*header,const std::vector<uint8_t>&pixels,const uint8_t*tail,size_t trailing,unsigned width){
 const size_t count=pixels.size()/4;std::vector<uint8_t>out;out.reserve(18+pixels.size()+count/128+1+trailing);out.insert(out.end(),header,header+18);
 auto same=[&](size_t a,size_t b){return memcmp(pixels.data()+a*4,pixels.data()+b*4,4)==0;};
 size_t start=0;
 while(start<count){
  // TGA readers may consume one scanline at a time. Keep every raw/run packet
  // inside its own scanline, rather than only respecting total image bounds.
  const size_t limit=std::min(size_t(128),size_t(width)-start%width);
  size_t run=1;while(run<limit&&start+run<count&&same(start,start+run))run++;
  if(run>=2){out.push_back(uint8_t(128+run-1));out.insert(out.end(),pixels.data()+start*4,pixels.data()+start*4+4);start+=run;continue;}
  size_t length=1;
  while(length<limit&&start+length<count){if(start+length+1<count&&same(start+length,start+length+1))break;length++;}
  out.push_back(uint8_t(length-1));out.insert(out.end(),pixels.data()+start*4,pixels.data()+(start+length)*4);start+=length;
 }
 out.insert(out.end(),tail,tail+trailing);return out;
}
as6_background::Crop Cover(const ArtSpec&s,double aspect,bool grid){
 const double virtual_width=grid?1662.:s.width;
 const double cx=grid?831.:s.width*.5;
 const double w=std::min(virtual_width,double(s.height)*16./9.),h=w*9./16.;
 const double cw=aspect>=16./9.?w:h*aspect,ch=aspect>=16./9.?w/aspect:h;
 return {cx-cw*.5,(s.height-ch)*.5,cw,ch};
}
uint8_t Sample(const ArtView&v,const ArtSpec&s,double x,double y,unsigned c){
 x=std::max(0.,std::min(double(s.width-1),x-.5));y=std::max(0.,std::min(double(s.height-1),y-.5));
 const unsigned x0=unsigned(x),y0=unsigned(y),x1=std::min(x0+1,s.width-1),y1=std::min(y0+1,s.height-1);const double fx=x-x0,fy=y-y0;
 const double a=v.top_bgra[(size_t(y0)*s.width+x0)*4+c]*(1-fx)+v.top_bgra[(size_t(y0)*s.width+x1)*4+c]*fx;
 const double b=v.top_bgra[(size_t(y1)*s.width+x0)*4+c]*(1-fx)+v.top_bgra[(size_t(y1)*s.width+x1)*4+c]*fx;
 return uint8_t(std::floor(a*(1-fy)+b*fy+.5));
}
}
size_t RequiredArts(Profile profile,ArtKind destination[2]) noexcept {
 const Spec*s=Find(profile);if(!s)return 0;size_t count=0;unsigned previous=~0u;
 for(size_t i=0;i<s->patch_count;i++)if(s->patches[i].kind!=previous){if(destination)destination[count]=static_cast<ArtKind>(s->patches[i].kind);previous=s->patches[i].kind;count++;}
 return count;
}
bool Materialize(Profile profile,const uint8_t*original,size_t original_size,
 const ArtView*arts,size_t art_count,double width,double height,Result&result,std::string&error){
 error.clear();const Spec*s=Find(profile);if(!s){error="unknown UI background profile";return false;}
 if(!std::isfinite(width)||!std::isfinite(height)||width<=0||height<=0){error="invalid Host size";return false;}
 const double aspect=width/height;if(!std::isfinite(aspect)||aspect<1||aspect>4){error="unsupported Host aspect";return false;}
 ArtKind required[2];const size_t needed=RequiredArts(profile,required);
 if(!arts||art_count!=needed||!needed||needed>2){error="missing or extra art input";return false;}
 const ArtView*selected[5]={};
 for(size_t i=0;i<art_count;i++){
  const unsigned kind=static_cast<unsigned>(arts[i].kind);bool permitted=false;for(size_t j=0;j<needed;j++)permitted|=required[j]==arts[i].kind;
  if(kind>=5||!permitted||selected[kind]){error="unknown, duplicate or unrelated art kind";return false;}
  const auto&a=kArtSpecs[kind];const auto*decoded=arts[i].decoded;
  const bool identity=decoded?decoded->matchesLegacy(a.sha,a.width,a.height)&&arts[i].top_bgra==decoded->data()&&arts[i].bytes==decoded->size():as6_background::Sha256(arts[i].top_bgra,arts[i].bytes)==a.sha;
  if(!arts[i].top_bgra||arts[i].bytes!=size_t(a.width)*a.height*4||!identity){error="AI art size or SHA mismatch";return false;}
  selected[kind]=&arts[i];
 }
 if(!original||original_size!=s->file_size||as6_background::Sha256(original,original_size)!=s->sha){error="original size or SHA mismatch";return false;}
 uint8_t h[18];memcpy(h,original,18);for(unsigned i=0;i<4;i++)h[i]=uint8_t(h[i]-i-1);
 if(h[0]||h[1]||h[2]!=s->type||U16(h+12)!=s->width||U16(h+14)!=s->height||h[16]!=32||h[17]!=s->descriptor){error="unexpected original TGA contract";return false;}
 try{
  Result next;next.physical_aspect=aspect;next.original_layout_tga.assign(original,original+original_size);
  std::vector<uint8_t>decoded;size_t rle_tail=0;uint8_t*pixel_bytes=next.original_layout_tga.data()+18;
  if(s->type==10){
   if(!DecodeRLE(original,original_size,size_t(s->width)*s->height,decoded,rle_tail)){error="invalid original RLE";return false;}
   // This exact authenticated original has only the standard26-byte footer,
   // with zero extension/developer offsets. It is position independent.
   if(original_size-rle_tail!=26||memcmp(original+rle_tail,"\0\0\0\0\0\0\0\0TRUEVISION-XFILE.\0",26)){error="unsupported RLE trailing metadata";return false;}
   pixel_bytes=decoded.data();
  }
  for(size_t i=0;i<s->patch_count;i++){
   const Patch&p=s->patches[i];const ArtSpec&a=kArtSpecs[p.kind];const ArtView&v=*selected[p.kind];const auto crop=Cover(a,aspect,p.mirror_grid);if(!i)next.art_crop=crop;
   if(p.x0>=p.x1||p.y0>=p.y1||p.x1>s->width||p.y1>s->height){error="invalid compiled background mask";return false;}
   for(unsigned y=p.y0;y<p.y1;y++)for(unsigned x=p.x0;x<p.x1;x++){
    const double qx=(p.a*(x+.5)+p.c*(y+.5)+p.tx)/p.stage_w,qy=(p.b*(x+.5)+p.d*(y+.5)+p.ty)/p.stage_h;
    const double ax=p.mirror_grid?831.-std::abs(qx-.5)*crop.width:crop.x+qx*crop.width,ay=crop.y+qy*crop.height;
    const unsigned row=(s->descriptor&0x20)?y:s->height-1-y;const size_t offset=(size_t(row)*s->width+x)*4;
    for(unsigned c=0;c<4;c++)pixel_bytes[offset+c]=Sample(v,a,ax,ay,c);
   }
  }
  if(s->type==10)next.original_layout_tga=EncodeRLE(original,decoded,original+rle_tail,original_size-rle_tail,s->width);
  char dimensions[128];std::snprintf(dimensions,sizeof(dimensions),"%u/%.17g/%.17g",s->asset,width,height);
  std::string key=std::string("ui-background-affine-v1:")+s->sha+":"+dimensions;
  for(size_t i=0;i<needed;i++){const auto kind=static_cast<unsigned>(required[i]);const auto&v=*selected[kind];key+=std::string(":")+(v.decoded?v.decoded->cacheIdentity():std::string(kArtSpecs[kind].sha));}
  next.cache_key=as6_background::Sha256(reinterpret_cast<const uint8_t*>(key.data()),key.size());result=std::move(next);return true;
 }catch(const std::bad_alloc&){error="allocation failed";return false;}
}
}
