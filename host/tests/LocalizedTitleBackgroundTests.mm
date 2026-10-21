#import <Foundation/Foundation.h>
#include "ResourcePaths.h"
#include "BackgroundAspect.hpp"
#include "DecodedArtwork.hpp"
#include <map>
#include <cmath>
#include "RetinaBackgroundAspect.hpp"
#include "art_pins.hpp"
#include <cassert>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <set>
#include <sys/stat.h>
#include <unistd.h>

// Exercise the actual resource adapter with an isolated, ordinary-file root.
// The original source directory is read only; every cache write is temporary.
static NSString *resourceRoot, *cacheRoot;
static double canvasWidth=1920, canvasHeight=1080;
NSString *AS6ResourceRootPath(void) { return resourceRoot; }
extern "C" bool GuestBackgroundPhysicalSize(double *w,double *h) {
    *w=canvasWidth; *h=canvasHeight; return true;
}
static NSArray<NSString *> *TestCachePaths(NSSearchPathDirectory,NSSearchPathDomainMask,BOOL) {
    return @[cacheRoot];
}
#define NSSearchPathForDirectoriesInDomains TestCachePaths
#include "BackgroundResources.mm"
#undef NSSearchPathForDirectoriesInDomains

static unsigned checks=0;
static void Check(bool ok,int line) {
    ++checks;
    if(!ok) { fprintf(stderr,"LocalizedTitleBackgroundTests failed near line %d\n",line); abort(); }
}
#define T(...) Check((__VA_ARGS__),__LINE__)
static bool Render(unsigned asset,NSData *source,const as6_background::DecodedArtwork &art,as6_background::Result &out) {
    std::string error;
    if(asset==494||asset==719)
        return as6_retina_background::MaterializeDecoded(static_cast<as6_retina_background::Profile>(asset),
            (const uint8_t*)source.bytes,source.length,art,
            {512,512},canvasWidth,canvasHeight,out,error);
    const auto profile=asset==786?as6_background::Profile::Title786ChinesePhone45:
        as6_background::Profile::Title269Phone45;
    return as6_background::MaterializeDecoded(profile,(const uint8_t*)source.bytes,source.length,
        art,canvasWidth,canvasHeight,false,out,error);
}
static void PreserveOutside(NSData *original,const as6_background::Result &out,unsigned scale) {
    const unsigned width=512*scale,height=512*scale,mw=480*scale,mh=320*scale;
    const auto *before=(const uint8_t*)original.bytes;
    const auto *after=out.original_layout_tga.data();
    T(out.original_layout_tga.size()==original.length);
    T(!memcmp(before,after,18));
    T(!memcmp(before+18+size_t(width)*height*4,after+18+size_t(width)*height*4,
        original.length-18-size_t(width)*height*4));
    size_t changed=0;
    for(unsigned y=0;y<height;++y) {
        const size_t row=18+size_t(height-1-y)*width*4;
        for(unsigned x=0;x<width;++x) {
            const size_t offset=row+size_t(x)*4;
            if(x>=mw||y>=mh) T(!memcmp(before+offset,after+offset,4));
            else changed+=memcmp(before+offset,after+offset,4)!=0;
        }
    }
    T(changed>size_t(mw)*mh/2);
}
static void SeparateArtwork(const as6_background::Result &english,const as6_background::Result &chinese,unsigned scale) {
    const unsigned width=512*scale,height=512*scale,mw=480*scale,mh=320*scale;
    size_t different=0;
    for(unsigned y=0;y<mh;++y) {
        const size_t row=18+size_t(height-1-y)*width*4;
        different+=memcmp(english.original_layout_tga.data()+row,chinese.original_layout_tga.data()+row,size_t(mw)*4)!=0;
    }
    T(different>0);
    T(english.cache_key!=chinese.cache_key);
}
int main(int argc,char **argv) { @autoreleasepool {
    T(argc==4);
    NSString *sourceDirectory=[NSString stringWithUTF8String:argv[1]];
    NSString *artDirectory=[NSString stringWithUTF8String:argv[2]];
    NSString *referenceDirectory=[NSString stringWithUTF8String:argv[3]];
    NSString *temporary=[NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"AS6LocalizedTitleTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    resourceRoot=[temporary stringByAppendingPathComponent:@"Asphalt6Data"];
    cacheRoot=[temporary stringByAppendingPathComponent:@"cache"];
    NSFileManager *fm=NSFileManager.defaultManager;
    @try {
        T([fm createDirectoryAtPath:[resourceRoot stringByAppendingPathComponent:@"data"] withIntermediateDirectories:YES attributes:nil error:nil]);
        T([fm createDirectoryAtPath:[resourceRoot stringByAppendingPathComponent:@"NativeArtwork"] withIntermediateDirectories:YES attributes:nil error:nil]);
        NSMutableDictionary<NSString*,NSData*> *arts=[NSMutableDictionary new];
        std::map<std::string,as6_background::DecodedArtwork> decodedArts;
        double maxMean=0,largestError=0; unsigned decoderChecks=0;
        for(NSString *artName in [fm contentsOfDirectoryAtPath:artDirectory error:nil]) {
            if(![artName.pathExtension isEqualToString:@"jpg"])continue;
            NSData *art=[NSData dataWithContentsOfFile:[artDirectory stringByAppendingPathComponent:artName]];
            T(art.length>0); arts[artName]=art;
            auto &decoded=decodedArts[artName.UTF8String];std::string error;
            T(as6_background::DecodeArtworkJpeg(artName.UTF8String,(const uint8_t*)art.bytes,art.length,decoded,error));
            T(decoded.matchesLegacy(decoded.legacyIdentity().c_str(),decoded.width(),decoded.height()));
            T(decoded.cacheIdentity().find(as6_background::Sha256((const uint8_t*)art.bytes,art.length))!=std::string::npos);
            T(decoded.cacheIdentity().find(std::to_string(decoded.width())+"/"+std::to_string(decoded.height()))!=std::string::npos);
            NSString *referenceName=[[artName stringByDeletingPathExtension] stringByAppendingPathExtension:@"bgra"];
            NSData *reference=[NSData dataWithContentsOfFile:[referenceDirectory stringByAppendingPathComponent:referenceName]];
            T(reference.length==decoded.size());const auto *ref=(const uint8_t*)reference.bytes;
            double sum=0,flipped=0,swapped=0;unsigned maximum=0;
            for(unsigned y=0;y<decoded.height();++y)for(unsigned x=0;x<decoded.width();++x) {
                const size_t i=(size_t(y)*decoded.width()+x)*4,j=(size_t(decoded.height()-1-y)*decoded.width()+x)*4;
                T(decoded.data()[i+3]==255);
                for(unsigned c=0;c<3;++c){const unsigned delta=unsigned(std::abs(int(decoded.data()[i+c])-ref[i+c]));sum+=delta;maximum=std::max(maximum,delta);flipped+=std::abs(int(decoded.data()[i+c])-ref[j+c]);swapped+=std::abs(int(decoded.data()[i+c])-ref[i+2-c]);}
            }
            const double mean=sum/(decoded.width()*double(decoded.height())*3);
            T(mean<2.0); T(maximum<=24);T(sum<flipped);T(sum<swapped);
            maxMean=std::max(maxMean,mean);largestError=std::max(largestError,double(maximum));++decoderChecks;
            // Same-length corruption, truncation, and an unknown basename may
            // not replace an already-owned authenticated decode.
            NSMutableData *broken=[art mutableCopy];((uint8_t*)broken.mutableBytes)[art.length/2]^=1;
            const auto identity=decoded.cacheIdentity();
            T(!as6_background::DecodeArtworkJpeg(artName.UTF8String,(const uint8_t*)broken.bytes,broken.length,decoded,error));
            T(decoded.cacheIdentity()==identity);
            T(!as6_background::DecodeArtworkJpeg(artName.UTF8String,(const uint8_t*)art.bytes,art.length-1,decoded,error));
            T(!as6_background::DecodeArtworkJpeg("unlisted.jpg",(const uint8_t*)art.bytes,art.length,decoded,error));
            T(decoded.cacheIdentity()==identity);
            T([art writeToFile:[[resourceRoot stringByAppendingPathComponent:@"NativeArtwork"] stringByAppendingPathComponent:artName] atomically:YES]);
        }
        T(decoderChecks==20);T(decodedArts.size()==20);
        NSMutableDictionary<NSNumber*,NSData*> *sources=[NSMutableDictionary new];
        for(unsigned asset:{269u,786u,719u,494u}) {
            NSString *name=[NSString stringWithFormat:@"file%06u.dat",asset];
            NSData *original=[NSData dataWithContentsOfFile:[sourceDirectory stringByAppendingPathComponent:name]];
            T(original.length==(asset==269||asset==786?1048620u:4194348u));
            sources[@(asset)]=original;
            T([original writeToFile:[[resourceRoot stringByAppendingPathComponent:@"data"] stringByAppendingPathComponent:name] atomically:YES]);
        }
        std::set<std::string> keys;
        for(const auto dimensions:{std::pair<double,double>{1920,1080},{2736,1260},{320,320}}) {
            canvasWidth=dimensions.first; canvasHeight=dimensions.second;
            as6_background::Result outputs[4]; unsigned index=0;
            for(unsigned asset:{269u,786u,719u,494u}) {
                NSData *original=sources[@(asset)]; auto &output=outputs[index++];
                const bool chinese=asset==786||asset==494;
                const auto &art=decodedArts.at(chinese?"title-cover-zh-cn-16x9-v1.jpg":"title-cover-16x9-v1.jpg");
                T(Render(asset,original,art,output));
                PreserveOutside(original,output,asset==269||asset==786?1:2);
                T(keys.insert(output.cache_key).second);
                NSString *path=[[resourceRoot stringByAppendingPathComponent:@"data"] stringByAppendingPathComponent:[NSString stringWithFormat:@"file%06u.dat",asset]];
                setenv("AS6_AI_BACKGROUNDS","0",1); T(AS6BackgroundFopenPath(path,@"rb")==path);
                setenv("AS6_AI_BACKGROUNDS","1",1); errno=EDOM;
                NSString *routed=AS6BackgroundFopenPath(path,@"rb");
                T(![routed isEqualToString:path]&&errno==EDOM);
                NSData *actual=[NSData dataWithContentsOfFile:routed];
                T(actual.length==output.original_layout_tga.size());
                T(!memcmp(actual.bytes,output.original_layout_tga.data(),actual.length));
                T([AS6BackgroundOpenPath(path,O_RDONLY) isEqualToString:routed]);
                FILE *file=fopen(routed.fileSystemRepresentation,"rb"); T(file!=nullptr);
                struct stat st{}; T(!fstat(fileno(file),&st)&&st.st_size==(off_t)original.length); T(!fclose(file));
                T([[NSData dataWithContentsOfFile:path] isEqualToData:original]);
                T(AS6BackgroundFopenPath(path,@"r+")==path);
                // Wrong locale identities and damaged sources fail closed, even
                // when dimensions and byte lengths match an admitted texture.
                as6_background::Result rejected; rejected.cache_key="unchanged";
                const unsigned other=asset==269?786:asset==786?269:asset==719?494:719;
                T(!Render(asset,sources[@(other)],art,rejected)); T(rejected.cache_key=="unchanged");
                NSMutableData *damaged=[original mutableCopy]; ((uint8_t*)damaged.mutableBytes)[19]^=1;
                T(!Render(asset,damaged,art,rejected)); T(rejected.cache_key=="unchanged");
                const auto &wrongArt=decodedArts.at(chinese?"title-cover-16x9-v1.jpg":"title-cover-zh-cn-16x9-v1.jpg");
                T(!Render(asset,original,wrongArt,rejected)); T(rejected.cache_key=="unchanged");
            }
            SeparateArtwork(outputs[0],outputs[1],1); SeparateArtwork(outputs[2],outputs[3],2);
        }
        canvasWidth=2736;canvasHeight=1260;unsigned fullRoutes=0;
        const auto installSource=[&](const char *name){NSString *n=[NSString stringWithUTF8String:name];NSData *original=[NSData dataWithContentsOfFile:[sourceDirectory stringByAppendingPathComponent:n]];T(original.length>0);T([original writeToFile:[[resourceRoot stringByAppendingPathComponent:@"data"] stringByAppendingPathComponent:n] atomically:YES]);return original;};
        const auto compareRoute=[&](const char *name,NSData *original,const as6_background::Result &expected){NSString *path=[[resourceRoot stringByAppendingPathComponent:@"data"] stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];NSString *routed=AS6BackgroundFopenPath(path,@"rb");T(![routed isEqualToString:path]);NSData *actual=[NSData dataWithContentsOfFile:routed];T(actual.length==expected.original_layout_tga.size());T(!memcmp(actual.bytes,expected.original_layout_tga.data(),actual.length));T([[NSData dataWithContentsOfFile:path] isEqualToData:original]);++fullRoutes;};
        for(const auto &spec:kBackgrounds) {
            NSData *original=installSource(spec.source);const auto &art=decodedArts.at(spec.art);as6_background::Result out;std::string error;bool ok=false;
            if(spec.retina)ok=as6_retina_background::MaterializeDecoded(static_cast<as6_retina_background::Profile>(spec.retina),(const uint8_t*)original.bytes,original.length,art,{spec.nominal_w,spec.nominal_h},canvasWidth,canvasHeight,out,error);
            else if(spec.loading)ok=as6_loading_background::MaterializeDecoded(static_cast<as6_loading_background::Profile>(spec.loading),(const uint8_t*)original.bytes,original.length,art,canvasWidth,canvasHeight,out,error);
            else ok=as6_background::MaterializeDecoded(spec.blue?as6_background::Profile::Blue670Phone659Experimental:spec.profile,(const uint8_t*)original.bytes,original.length,art,canvasWidth,canvasHeight,spec.blue,out,error);
            T(ok);compareRoute(spec.source,original,out);
            const auto &wrong=decodedArts.at(!std::strcmp(spec.art,"title-cover-16x9-v1.jpg")?"blue-menu-16x9-v1.jpg":"title-cover-16x9-v1.jpg");
            as6_background::Result rejected;rejected.cache_key="unchanged";
            if(spec.retina)ok=as6_retina_background::MaterializeDecoded(static_cast<as6_retina_background::Profile>(spec.retina),(const uint8_t*)original.bytes,original.length,wrong,{spec.nominal_w,spec.nominal_h},canvasWidth,canvasHeight,rejected,error);
            else if(spec.loading)ok=as6_loading_background::MaterializeDecoded(static_cast<as6_loading_background::Profile>(spec.loading),(const uint8_t*)original.bytes,original.length,wrong,canvasWidth,canvasHeight,rejected,error);
            else ok=as6_background::MaterializeDecoded(spec.blue?as6_background::Profile::Blue670Phone659Experimental:spec.profile,(const uint8_t*)original.bytes,original.length,wrong,canvasWidth,canvasHeight,spec.blue,rejected,error);
            T(!ok);T(rejected.cache_key=="unchanged");
        }
        for(const auto &spec:kUIBackgrounds) {
            NSData *original=installSource(spec.source);as6_ui_background::ArtKind kinds[2];const auto count=as6_ui_background::RequiredArts(spec.profile,kinds);as6_ui_background::ArtView views[2];
            for(size_t i=0;i<count;++i){const auto &art=decodedArts.at(UIArtName(kinds[i]));views[i]={kinds[i],art.data(),art.size(),&art};}
            as6_background::Result out;std::string error;T(as6_ui_background::Materialize(spec.profile,(const uint8_t*)original.bytes,original.length,views,count,canvasWidth,canvasHeight,out,error));compareRoute(spec.source,original,out);
            const auto &wrong=decodedArts.at("title-cover-16x9-v1.jpg");views[0]={kinds[0],wrong.data(),wrong.size(),&wrong};
            as6_background::Result rejected;rejected.cache_key="unchanged";
            T(!as6_ui_background::Materialize(spec.profile,(const uint8_t*)original.bytes,original.length,views,count,canvasWidth,canvasHeight,rejected,error));T(rejected.cache_key=="unchanged");
        }
        T(fullRoutes==46);
        as6_background::Result rawRejected;rawRejected.cache_key="unchanged";std::string rawError;
        const auto &englishDecoded=decodedArts.at("title-cover-16x9-v1.jpg");NSData *englishSource=sources[@269];
        T(!as6_background::Materialize(as6_background::Profile::Title269Phone45,(const uint8_t*)englishSource.bytes,englishSource.length,englishDecoded.data(),englishDecoded.size(),canvasWidth,canvasHeight,false,rawRejected,rawError));T(rawRejected.cache_key=="unchanged");
        // A corrupted JPEG must retain the original route even if a previously
        // generated cache entry exists; the private BGRA reference is ignored.
        NSString *zhPath=[[resourceRoot stringByAppendingPathComponent:@"data"] stringByAppendingPathComponent:@"file000786.dat"];
        NSData *zh=arts[@"title-cover-zh-cn-16x9-v1.jpg"];NSMutableData *damagedJpeg=[zh mutableCopy];((uint8_t*)damagedJpeg.mutableBytes)[damagedJpeg.length/2]^=1;
        T([damagedJpeg writeToFile:[[resourceRoot stringByAppendingPathComponent:@"NativeArtwork"] stringByAppendingPathComponent:@"title-cover-zh-cn-16x9-v1.jpg"] atomically:YES]);
        T([AS6BackgroundFopenPath(zhPath,@"rb") isEqualToString:zhPath]);
        // iPad/other regional atlases retain the existing original-resource route.
        for(unsigned asset:{27u,131u,185u,268u,704u,770u}) {
            NSString *path=[[resourceRoot stringByAppendingPathComponent:@"data"] stringByAppendingPathComponent:[NSString stringWithFormat:@"file%06u.dat",asset]];
            T(AS6BackgroundFopenPath(path,@"rb")==path);
        }
        printf("{\"passed\":true,\"jpeg_decodes\":%u,\"all_jpeg_routes\":%u,\"decode_max_mean_error\":%.6f,\"decode_max_channel_error\":%.0f,\"checks\":%u,\"source_routes\":4,\"aspects\":3,\"whole_file_comparisons\":12,\"outside_background_differences\":0,\"original_files_modified\":false,\"game_started\":false}\n",decoderChecks,fullRoutes,maxMean,largestError,checks);
    } @finally { [fm removeItemAtPath:temporary error:nil]; }
    return 0;
} }
