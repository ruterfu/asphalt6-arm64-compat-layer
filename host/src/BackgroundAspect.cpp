#include "BackgroundAspect.hpp"
#include "DecodedArtwork.hpp"
#include "art_pins.hpp"
#include <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <new>

namespace as6_background {
namespace {
constexpr unsigned kArtW=1672, kArtH=941;
struct Spec {
 const char *name, *original_sha, *art_sha;
 unsigned width, height, descriptor, mask_x, mask_y, mask_w, mask_h;
 size_t file_size;
 double a,d,tx,ty;
 bool bottom_anchor;
 unsigned art_width=kArtW,art_height=kArtH;
};
constexpr Spec title = {"title269-phone45-v1",
 "e081a84dc0b3ed110498858721b5a78d47a3ad9a3b77edf018463ef7e70a6ba7", kTitleArtBgraSha,
 512,512,0x08,0,0,480,320,1048620,
 48.115020751953125,48.218353271484375,-35,-55,true};
// SwfTextureLoader selects this localized source for the same Loading02
// bitmap and phone45 fill. Retain its separate source identity and atlas tail.
constexpr Spec chinese_title = {"title786-chinese-phone45-v1",
 "30943b2046e955e7fe96e967441f150ff4ffe44e79e9c2dc1a74a9e236596915", kChineseTitleArtBgraSha,
 512,512,0x08,0,0,480,320,1048620,
 48.115020751953125,48.218353271484375,-35,-55,true,kChineseTitleArtWidth,kChineseTitleArtHeight};
constexpr Spec blue = {"blue670-phone659-experimental-v1",
 "5ff779131e985d4ce47bf8978bd227fe7f46e9d68b0fc9803ddab2bb719c13f7", kBlueArtBgraSha,
 1024,512,0x28,0,192,480,320,2097170,
 48.1668701171875,48.3111572265625,-11,-9325,false};
constexpr double kStageW=23040, kStageH=15360;
unsigned U16(const uint8_t* p) { return unsigned(p[0]) | unsigned(p[1])<<8; }
uint8_t Bilinear(const uint8_t* p, unsigned art_w, unsigned art_h, double x, double y, unsigned ch) {
 x=std::max(0.0,std::min(double(art_w-1),x-.5));
 y=std::max(0.0,std::min(double(art_h-1),y-.5));
 const unsigned x0=unsigned(x),y0=unsigned(y),x1=std::min(x0+1,art_w-1),y1=std::min(y0+1,art_h-1);
 const double fx=x-x0,fy=y-y0;
 const double top=p[(size_t(y0)*art_w+x0)*4+ch]*(1-fx)+p[(size_t(y0)*art_w+x1)*4+ch]*fx;
 const double bot=p[(size_t(y1)*art_w+x0)*4+ch]*(1-fx)+p[(size_t(y1)*art_w+x1)*4+ch]*fx;
 return uint8_t(std::floor(top*(1-fy)+bot*fy+.5));
}
}
std::string Sha256(const uint8_t* data, size_t size) {
 if ((!data && size) || size>std::numeric_limits<CC_LONG>::max()) return {};
 unsigned char digest[CC_SHA256_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
 CC_SHA256(data,CC_LONG(size),digest);
#pragma clang diagnostic pop
 char hex[CC_SHA256_DIGEST_LENGTH*2+1];
 for(unsigned i=0;i<CC_SHA256_DIGEST_LENGTH;i++) std::snprintf(hex+2*i,3,"%02x",digest[i]);
 return hex;
}
static bool MaterializeImpl(Profile profile,const uint8_t* original,size_t original_size,
 const uint8_t* art,size_t art_size,double width,double height,
 bool allow_blue,Result& result,std::string& error,const DecodedArtwork* decoded) {
 error.clear();
 const Spec* spec=nullptr;
 switch(profile) {
 case Profile::Title269Phone45: spec=&title; break;
 case Profile::Title786ChinesePhone45: spec=&chinese_title; break;
 case Profile::Blue670Phone659Experimental:
   if(!allow_blue) {error="blue asset identity is not yet proven";return false;}
   spec=&blue;break;
 default:error="unknown profile";return false;
 }
 const Spec& s=*spec;
 if(!std::isfinite(width)||!std::isfinite(height)||width<=0||height<=0) {error="invalid Host size";return false;}
 const double aspect=width/height;
 // Only explicit landscape phone profiles are qualified. Reject a transient
 // portrait/zero layout; the caller retains the original resource on failure.
 if(!std::isfinite(aspect)||aspect<1.0||aspect>4.0) {error="unsupported Host aspect";return false;}
 if(!original||original_size!=s.file_size||!art||!s.art_width||!s.art_height||art_size!=size_t(s.art_width)*s.art_height*4) {error="size mismatch";return false;}
 const bool decoded_ok=decoded&&decoded->matchesLegacy(s.art_sha,s.art_width,s.art_height)&&art==decoded->data()&&art_size==decoded->size();
 if(Sha256(original,original_size)!=s.original_sha||(decoded?!decoded_ok:Sha256(art,art_size)!=s.art_sha)) {error="source SHA mismatch";return false;}
 uint8_t h[18]; std::copy(original,original+18,h);
 for(unsigned i=0;i<4;i++)h[i]=uint8_t(h[i]-i-1);
 if(h[0]!=0||h[1]!=0||h[2]!=2||U16(h+12)!=s.width||U16(h+14)!=s.height||h[16]!=32||h[17]!=s.descriptor) {error="unexpected TGA contract";return false;}
 if(s.mask_x+s.mask_w>s.width||s.mask_y+s.mask_h>s.height||18+size_t(s.width)*s.height*4>original_size) {error="invalid mask";return false;}
 // First define the AI composition's exact 16:9 logical rectangle, then cover
 // the real Host canvas uniformly. No original artwork is stretched.
 const double logical_w=decoded?std::min(double(s.art_width),double(s.art_height)*16.0/9.0):double(s.art_width);
 Crop crop{(s.art_width-logical_w)*.5,0,logical_w,logical_w*9.0/16.0};
 crop.y=s.bottom_anchor?s.art_height-crop.height:(s.art_height-crop.height)*.5;
 if(aspect>=16.0/9.0) {
   const double new_h=crop.width/aspect;
   crop.y+=s.bottom_anchor?crop.height-new_h:(crop.height-new_h)*.5;
   crop.height=new_h;
 } else {
   const double new_w=crop.height*aspect;
   crop.x+=(crop.width-new_w)*.5;crop.width=new_w;
 }
 try {
  Result next;next.art_crop=crop;next.physical_aspect=aspect;
  next.original_layout_tga.assign(original,original+original_size);
  for(unsigned y=s.mask_y;y<s.mask_y+s.mask_h;y++) {
   const unsigned stored_y=(s.descriptor&0x20)?y:s.height-1-y;
   for(unsigned x=s.mask_x;x<s.mask_x+s.mask_w;x++) {
    // Original fill -> visible stage -> final Host screen. The visible-stage
    // intersection, rather than overscan shape bounds, defines the affine.
    const double qx=(s.a*(x+.5)+s.tx)/kStageW;
    const double qy=(s.d*(y+.5)+s.ty)/kStageH;
    const double ax=crop.x+qx*crop.width,ay=crop.y+qy*crop.height;
    const size_t offset=18+(size_t(stored_y)*s.width+x)*4;
    for(unsigned ch=0;ch<4;ch++)next.original_layout_tga[offset+ch]=Bilinear(art,s.art_width,s.art_height,ax,ay,ch);
   }
  }
  // Exact dimensions and IEEE aspect bits distinguish cache entries. Including
  // the profile/version prevents reuse after a geometry or algorithm change.
  char aspect_key[128];std::snprintf(aspect_key,sizeof(aspect_key),"%.17g/%.17g",width,height);
  const std::string key=std::string(s.name)+":"+s.original_sha+":"+(decoded?decoded->cacheIdentity():std::string(s.art_sha))+":"+aspect_key;
  next.cache_key=Sha256(reinterpret_cast<const uint8_t*>(key.data()),key.size());
  result=std::move(next);return true;
 } catch(const std::bad_alloc&) {error="allocation failed";return false;}
}
bool Materialize(Profile p,const uint8_t* original,size_t original_size,const uint8_t* art,size_t art_size,
 double width,double height,bool allow_blue,Result& result,std::string& error) {
 return MaterializeImpl(p,original,original_size,art,art_size,width,height,allow_blue,result,error,nullptr);
}
bool MaterializeDecoded(Profile p,const uint8_t* original,size_t original_size,const DecodedArtwork& art,
 double width,double height,bool allow_blue,Result& result,std::string& error) {
 return MaterializeImpl(p,original,original_size,art.data(),art.size(),width,height,allow_blue,result,error,&art);
}

}
