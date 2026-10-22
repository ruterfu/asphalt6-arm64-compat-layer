#include "HDArtworkPack.hpp"
#include "RetinaBackgroundAspect.hpp"
#include "DecodedArtwork.hpp"
#include "ArtVariants.hpp"
#include "art_pins.hpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <new>
#pragma clang fp contract(off)
namespace as6_retina_background {
namespace {
struct Spec {
 unsigned asset,low_asset,mode;
 const char *original_sha,*art_sha;
 size_t original_bytes;
 unsigned width,height,descriptor,nominal_w,nominal_h,art_w,art_h;
 unsigned mask_x,mask_y,mask_w,mask_h;
 double a,d,tx,ty;
};
struct Span {unsigned y,x0,x1;};
#include "retina_pins.hpp"
#include "loading_mask.hpp"
unsigned U16(const uint8_t*p){return unsigned(p[0])|unsigned(p[1])<<8;}
uint8_t Sample(const uint8_t*p,unsigned w,unsigned h,double x,double y,unsigned c){
 x=std::max(0.0,std::min(double(w-1),x-.5));y=std::max(0.0,std::min(double(h-1),y-.5));
 const unsigned x0=unsigned(x),y0=unsigned(y),x1=std::min(x0+1,w-1),y1=std::min(y0+1,h-1);
 const double fx=x-x0,fy=y-y0;
 const double t=p[(size_t(y0)*w+x0)*4+c]*(1-fx)+p[(size_t(y0)*w+x1)*4+c]*fx;
 const double b=p[(size_t(y1)*w+x0)*4+c]*(1-fx)+p[(size_t(y1)*w+x1)*4+c]*fx;
 return uint8_t(std::floor(t*(1-fy)+b*fy+.5));
}
}
static bool MaterializeImpl(Profile profile,const uint8_t*original,size_t original_size,
 const uint8_t*art,size_t art_size,NominalBitmap nominal,double width,double height,
 Result&result,std::string&error,const as6_background::DecodedArtwork* decoded){
 error.clear();const Spec*s=nullptr;
 for(const auto&v:kSpecs)if(v.asset==static_cast<unsigned>(profile)){s=&v;break;}
 if(!s){error="unknown HD profile";return false;}
 // A 2.2:1 version of the pinned art stands in with its own size/identity.
 Spec wide_spec=*s;const char*wide_sha=nullptr;
 const bool wide_art=as6_art_variant::WideOf(decoded,s->art_sha,wide_spec.art_w,wide_spec.art_h,wide_sha);
 if(wide_art){wide_spec.art_sha=wide_sha;s=&wide_spec;}
 if(nominal.width!=s->nominal_w||nominal.height!=s->nominal_h||
    s->width!=2*nominal.width||s->height!=2*nominal.height){error="nominal phone bitmap contract mismatch";return false;}
 if(!std::isfinite(width)||!std::isfinite(height)||width<=0||height<=0){error="invalid Host size";return false;}
 const double aspect=width/height;
 if(!std::isfinite(aspect)||aspect<1||aspect>4){error="unsupported Host aspect";return false;}
 if(!original||original_size!=s->original_bytes||!art||art_size!=size_t(s->art_w)*s->art_h*4){error="size mismatch";return false;}
 const bool decoded_ok=decoded&&decoded->matchesLegacy(s->art_sha,s->art_w,s->art_h)&&art==decoded->data()&&art_size==decoded->size();
 if(as6_background::Sha256(original,original_size)!=s->original_sha||(decoded?!decoded_ok:as6_background::Sha256(art,art_size)!=s->art_sha)){error="source SHA mismatch";return false;}
 uint8_t h[18];memcpy(h,original,18);for(unsigned i=0;i<4;i++)h[i]=uint8_t(h[i]-i-1);
 if(h[0]||h[1]||h[2]!=2||U16(h+12)!=s->width||U16(h+14)!=s->height||h[16]!=32||h[17]!=s->descriptor){error="unexpected HD TGA contract";return false;}
 if(s->mask_x+s->mask_w>s->width||s->mask_y+s->mask_h>s->height||18+size_t(s->width)*s->height*4>original_size){error="invalid HD mask";return false;}
 as6_background::Crop crop{};
 if(s->mode==2){
  const double photo_aspect=aspect*1.28;
  // The logical picture is the 16:9 composition, or the whole 2.2:1 version.
  const double logical_w=wide_art?double(s->art_w):std::min(double(s->art_w),double(s->art_h)*16.0/9.0);
  const double logical_h=wide_art?double(s->art_h):logical_w*9.0/16.0;
  const double cw=photo_aspect>=logical_w/logical_h?logical_w:logical_h*photo_aspect;
  const double ch=photo_aspect>=logical_w/logical_h?logical_w/photo_aspect:logical_h;
  crop={(s->art_w-cw)*.5,s->art_h-ch,cw,ch};
 }else{
  const double logical_w=wide_art?double(s->art_w):decoded?std::min(double(s->art_w),double(s->art_h)*16.0/9.0):double(s->art_w);
  const double logical_h=wide_art?double(s->art_h):logical_w*9.0/16.0;
  crop={(s->art_w-logical_w)*.5,0,logical_w,logical_h};
  const bool bottom=s->mode==0;
  crop.y=bottom?s->art_h-crop.height:(s->art_h-crop.height)*.5;
  if(aspect>=logical_w/logical_h){const double ch=crop.width/aspect;crop.y+=bottom?crop.height-ch:(crop.height-ch)*.5;crop.height=ch;}
  else{const double cw=crop.height*aspect;crop.x+=(crop.width-cw)*.5;crop.width=cw;}
 }
 try{
  const uint8_t *header=as6_hd_artwork::LoadingHeader();
  if(!header){error="HD artwork header unavailable";return false;}
  Result next;next.art_crop=crop;next.physical_aspect=aspect;next.original_layout_tga.assign(original,original+original_size);
  auto pixel=[&](unsigned x,unsigned y){
   const unsigned stored_y=(s->descriptor&0x20)?y:s->height-1-y;
   const size_t off=18+(size_t(stored_y)*s->width+x)*4;
   if(s->mode!=2){
    // HD centers remain fractional in nominal space. M_HD=M_low/2;
    // translation, root placement and23040x15360 stage are unchanged.
    const double qx=(s->a*(x+.5)+s->tx)/23040.0,qy=(s->d*(y+.5)+s->ty)/15360.0;
    for(unsigned c=0;c<4;c++)next.original_layout_tga[off+c]=Sample(art,s->art_w,s->art_h,crop.x+qx*crop.width,crop.y+qy*crop.height,c);
   }else{
    const double lx=(x+.5)/2.0,ly=(y+.5)/2.0;
    uint8_t photo[4];for(unsigned c=0;c<4;c++)photo[c]=Sample(art,s->art_w,s->art_h,crop.x+lx/480.0*crop.width,crop.y+ly/250.0*crop.height,c);
    const double hx=(lx-70)/220*256,hy=(ly-60)*256*1.5/(220*aspect)+590*256.0/2056;
    uint8_t overlay[4]={};
    if(hx>=0&&hx<256&&hy>=0&&hy<96)for(unsigned c=0;c<4;c++)overlay[c]=Sample(header,256,96,hx,hy,c);
    for(unsigned c=0;c<3;c++)next.original_layout_tga[off+c]=uint8_t(std::min(255u,unsigned(overlay[c])+(unsigned(photo[c])*(255-overlay[3])+127)/255));
    next.original_layout_tga[off+3]=photo[3];
   }
  };
  if(s->mode==2){
   for(const auto&span:kReplaceSpans){
    if(span.y>=250||span.x0>=span.x1||span.x1>480){error="invalid compiled loading mask";return false;}
    for(unsigned dy=0;dy<2;dy++)for(unsigned x=span.x0*2;x<span.x1*2;x++)pixel(x,span.y*2+dy);
   }
  }else for(unsigned y=s->mask_y;y<s->mask_y+s->mask_h;y++)for(unsigned x=s->mask_x;x<s->mask_x+s->mask_w;x++)pixel(x,y);
  char dimensions[128];std::snprintf(dimensions,sizeof(dimensions),"%u/%u/%u/%.17g/%.17g",s->asset,nominal.width,nominal.height,width,height);
  const std::string key=std::string("core14-retina-phone-v1:")+s->original_sha+":"+(decoded?decoded->cacheIdentity():std::string(s->art_sha))+":"+as6_hd_artwork::kLoadingHeaderSha256+":"+dimensions;
  next.cache_key=as6_background::Sha256(reinterpret_cast<const uint8_t*>(key.data()),key.size());result=std::move(next);return true;
 }catch(const std::bad_alloc&){error="allocation failed";return false;}
}
bool Materialize(Profile p,const uint8_t* original,size_t original_size,const uint8_t* art,size_t art_size,
 NominalBitmap nominal,double width,double height,Result& result,std::string& error) {
 return MaterializeImpl(p,original,original_size,art,art_size,nominal,width,height,result,error,nullptr);
}
bool MaterializeDecoded(Profile p,const uint8_t* original,size_t original_size,const as6_background::DecodedArtwork& art,
 NominalBitmap nominal,double width,double height,Result& result,std::string& error) {
 return MaterializeImpl(p,original,original_size,art.data(),art.size(),nominal,width,height,result,error,&art);
}

}
