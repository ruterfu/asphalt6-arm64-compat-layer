#include "HDArtworkPack.hpp"
#include "LoadingBackgroundAspect.hpp"
#include "DecodedArtwork.hpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <new>
// Deterministic atlas bytes across native builds and the independent reference:
// contracting adjacent double operations can move an exact .5 tie by1ULP.
#pragma clang fp contract(off)
namespace as6_loading_background {
namespace {
struct Spec {unsigned asset;const char *original_sha,*art_sha;unsigned art_w,art_h;};
struct Span {unsigned y,x0,x1;};
#include "loading_pins.hpp"
#include "loading_mask.hpp"
constexpr size_t kOriginalBytes=1048620,kAtlasPixels=512*512;
unsigned U16(const uint8_t*p){return unsigned(p[0])|unsigned(p[1])<<8;}
uint8_t Sample(const uint8_t*p,unsigned w,unsigned h,double x,double y,unsigned c){
 x=std::max(0.0,std::min(double(w-1),x-.5));y=std::max(0.0,std::min(double(h-1),y-.5));
 const unsigned x0=unsigned(x),y0=unsigned(y),x1=std::min(x0+1,w-1),y1=std::min(y0+1,h-1);const double fx=x-x0,fy=y-y0;
 const double t=p[(size_t(y0)*w+x0)*4+c]*(1-fx)+p[(size_t(y0)*w+x1)*4+c]*fx;
 const double b=p[(size_t(y1)*w+x0)*4+c]*(1-fx)+p[(size_t(y1)*w+x1)*4+c]*fx;
 return uint8_t(std::floor(t*(1-fy)+b*fy+.5));
}
}
static bool MaterializeImpl(Profile profile,const uint8_t* original,size_t original_size,
 const uint8_t* art,size_t art_size,double width,double height,Result& result,std::string&error,const as6_background::DecodedArtwork* decoded){
 error.clear();const Spec *s=nullptr;for(const auto&candidate:kSpecs)if(candidate.asset==static_cast<unsigned>(profile)){s=&candidate;break;}
 if(!s){error="unknown loading asset";return false;}
 if(!std::isfinite(width)||!std::isfinite(height)||width<=0||height<=0){error="invalid Host size";return false;}
 const double aspect=width/height;if(!std::isfinite(aspect)||aspect<1||aspect>4){error="unsupported Host aspect";return false;}
 if(!original||original_size!=kOriginalBytes||!art||art_size!=size_t(s->art_w)*s->art_h*4){error="size mismatch";return false;}
 const bool decoded_ok=decoded&&decoded->matchesLegacy(s->art_sha,s->art_w,s->art_h)&&art==decoded->data()&&art_size==decoded->size();
 if(as6_background::Sha256(original,original_size)!=s->original_sha||(decoded?!decoded_ok:as6_background::Sha256(art,art_size)!=s->art_sha)){error="source SHA mismatch";return false;}
 uint8_t h[18];memcpy(h,original,18);for(unsigned i=0;i<4;i++)h[i]=uint8_t(h[i]-i-1);
 if(h[0]||h[1]||h[2]!=2||U16(h+12)!=512||U16(h+14)!=512||h[16]!=32||h[17]!=8){error="unexpected TGA contract";return false;}
 // Original phone736 photo x0..480/y0..250 is rendered by a=d=47.99987793
 // on stage23040x15360. Thus its true physical AR is HostAR*1.28, while
 // the retained information bar occupies the rest of the unchanged stage.
 const double photo_aspect=aspect*1.28;
 const double logical_w=std::min(double(s->art_w),double(s->art_h)*16.0/9.0),logical_h=logical_w*9.0/16.0;
 const double crop_w=photo_aspect>=16.0/9.0?logical_w:logical_h*photo_aspect;
 const double crop_h=photo_aspect>=16.0/9.0?logical_w/photo_aspect:logical_h;
 const as6_background::Crop crop{(s->art_w-crop_w)*.5,s->art_h-crop_h,crop_w,crop_h};
 try{
  const uint8_t *header=as6_hd_artwork::LoadingHeader();
  if(!header){error="HD artwork header unavailable";return false;}
  Result next;next.art_crop=crop;next.physical_aspect=aspect;next.original_layout_tga.assign(original,original+original_size);
  for(const auto&span:kReplaceSpans){
   if(span.y>=250||span.x0>=span.x1||span.x1>480){error="invalid compiled photo mask";return false;}
   for(unsigned x=span.x0;x<span.x1;x++){
    const double ax=crop.x+(x+.5)/480*crop.width,ay=crop.y+(span.y+.5)/250*crop.height;
    const size_t offset=18+(size_t(511-span.y)*512+x)*4;
    uint8_t photo[4];for(unsigned c=0;c<4;c++)photo[c]=Sample(art,s->art_w,s->art_h,ax,ay,c);
    // The original top ribbon was inseparably blended into each old photo.
    // Use only the independently generated transparent decoration, with
    // premultiplied filtering and the same final-physical inverse affine.
    const double hx=(x+.5-70)/220*256;
    const double hy=(span.y+.5-60)*256*1.5/(220*aspect)+590*256.0/2056;
    uint8_t overlay[4]={0,0,0,0};
    if(hx>=0&&hx<256&&hy>=0&&hy<96)for(unsigned c=0;c<4;c++)overlay[c]=Sample(header,256,96,hx,hy,c);
    for(unsigned c=0;c<3;c++)next.original_layout_tga[offset+c]=uint8_t(std::min(255u,unsigned(overlay[c])+(unsigned(photo[c])*(255-overlay[3])+127)/255));
    next.original_layout_tga[offset+3]=photo[3];
   }
  }
  char dimensions[128];std::snprintf(dimensions,sizeof(dimensions),"%u/%.17g/%.17g",s->asset,width,height);
  const std::string key=std::string("loading-photo-phone736-v2-ai-alpha-header:")+s->original_sha+":"+(decoded?decoded->cacheIdentity():std::string(s->art_sha))+":"+as6_hd_artwork::kLoadingHeaderSha256+":"+dimensions;
  next.cache_key=as6_background::Sha256(reinterpret_cast<const uint8_t*>(key.data()),key.size());result=std::move(next);return true;
 }catch(const std::bad_alloc&){error="allocation failed";return false;}
}
bool Materialize(Profile p,const uint8_t* original,size_t original_size,const uint8_t* art,size_t art_size,
 double width,double height,Result& result,std::string& error) {
 return MaterializeImpl(p,original,original_size,art,art_size,width,height,result,error,nullptr);
}
bool MaterializeDecoded(Profile p,const uint8_t* original,size_t original_size,const as6_background::DecodedArtwork& art,
 double width,double height,Result& result,std::string& error) {
 return MaterializeImpl(p,original,original_size,art.data(),art.size(),width,height,result,error,&art);
}

}
