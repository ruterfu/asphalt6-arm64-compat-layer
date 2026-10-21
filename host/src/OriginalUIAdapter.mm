#import "GuestVM.h"
#include "OriginalUIAdapter.hpp"
#include "OriginalUIBoundary.hpp"
#include "OriginalUIGeometry.hpp"
#include "OriginalUIHostMetrics.hpp"
#include "CareerStarLayout.hpp"
#include <array>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

extern "C" gva_t GuestGLView(void);
extern "C" BOOL GuestDiagnosticSnapshotLockHeld(GuestVM *);

namespace as6_original_ui {
namespace {
constexpr std::uint32_t Lookup = 0x322b3c, SetMatrix = 0x3259a4;
constexpr std::uint32_t WorldMatrix = 0x2e8844, ScreenToStage = 0x309080;
constexpr std::uint32_t InputOrientation = 0x51c040;
constexpr std::uint32_t GetSWFManager = 0x16538, GetRayManager = 0x14af8;
constexpr std::uint32_t MakeRay = 0x17d65c, PlaneCorners = 0xacd30;
constexpr std::uint32_t FlashRayPosition = 0x17d384;
struct Node {
    std::string path;
    std::uint32_t object=0, name=0, vtable=0;
    std::array<float,6> base{}, applied{};
    bool shifted=false;
    bool affineApplied=false;
    M installedAffine{};
    unsigned nextResolve=0;
};
struct Group { std::vector<Node> nodes; };
struct MenuControl { Node node;double physicalDX=0;double uniformScale=1;bool readyLogged=false; };
struct Mapping {
    H hostToStage,stageToHost;
    bool plane=false;
    Rect stageClip{};
    double roundTripPixels=0;
};
enum class Kind { Unknown, Loading, Menu, Race, TrackPlane, CareerSelection };
struct Movie {
    std::uint32_t handler=0,root=0,definition=0,context=0;
    Kind kind=Kind::Unknown;
    Node gameloftLive{"mega_mc.btn_GLIVE"};
    Node careerStars{"star_career"};
    bool careerStarsReadyLogged=false;
    bool gameloftLiveHiddenLogged=false;
    std::vector<Group> groups;
    std::vector<MenuControl> menuControls;
    unsigned advances=0;
    bool discoveryDone=false,hasAdvanced=false;
    std::uint32_t manager=0,rayManager=0;
    int controller=-1;
    std::array<std::uint64_t,32> mappingKey{};
    bool mappingValid=false;
    Mapping mapping{};
    bool identifiedLog=false;
    unsigned mappingRejectLogs=0;
    unsigned mappingIdentityRejectLogs=0;
    bool mappingIdentityReadyLogged=false;
    const char *mappingReason="uninitialized";
    bool selectionReadyLogged=false;
    unsigned selectionRejectLogs=0;
    unsigned backRejectLogs=0;
    bool backReadyLogged=false;
};
struct State {
    std::uint32_t scratch=0;
    std::map<std::uint32_t,Movie> movies;
    unsigned logs=0;
    unsigned metricsRejectLogs=0;
};
std::recursive_mutex statesMutex;
std::map<GuestVM *,State> states;
bool read(GuestVM *vm,std::uint32_t at,void *dst,std::size_t n) {
    return at && GuestRead(vm,at,dst,n);
}
bool word(GuestVM *vm,std::uint32_t at,std::uint32_t &out) { return read(vm,at,&out,4); }
bool call(GuestVM *vm,std::uint32_t pc,std::initializer_list<std::uint32_t> args,std::uint32_t *value=nullptr) {
    const auto result=GuestCall(vm,pc,args.begin(),int(args.size()),2000000);
    if(GuestLastExecutionResult(vm)!=GuestExecutionSuccess)return false;
    if(value)*value=result;return true;
}
bool writeScratch(GuestVM *vm,State &s,unsigned offset,const void *p,std::size_t n) {
    if(!s.scratch)s.scratch=GuestAlloc(vm,4096);
    return s.scratch && offset+n<=4096 && GuestWrite(vm,s.scratch+offset,p,n);
}
std::uint32_t find(GuestVM *vm,State &s,std::uint32_t handler,const std::string &path) {
    if(path.size()>255||!writeScratch(vm,s,0,path.c_str(),path.size()+1))return 0;
    std::uint32_t object=0;
    return call(vm,Lookup,{handler,s.scratch},&object)?object:0;
}
bool local(GuestVM *vm,const Node &n,std::array<float,6> &m) {
    std::uint32_t pointer=0,name=0,vt=0;
    if(!word(vm,n.object,vt)||!word(vm,n.object+0x44,name)||vt!=n.vtable||name!=n.name||
       !word(vm,n.object+0x4c,pointer)||!read(vm,pointer,m.data(),24))return false;
    for(float f:m)if(!std::isfinite(f))return false;
    return true;
}
bool set(GuestVM *vm,State &s,Node &n,const std::array<float,6> &m) {
    return writeScratch(vm,s,512,m.data(),24)&&call(vm,SetMatrix,{n.object,s.scratch+512});
}
std::array<float,6> canonicalLocal(const Node &n,const std::array<float,6> &current) {
    if(!n.shifted)return current;
    if(current==n.applied)return n.base;
    M stripped;
    // Touch AS2 may write only _x/_y while leaving our installed linears intact.
    // Remove the known horizontal affine in this node's original parent domain.
    // A new authored linear transform wins and is never divided by our scale.
    if(n.affineApplied&&stripKnownAffineLocal(matrix(n.base.data()),matrix(n.applied.data()),matrix(current.data()),n.installedAffine,stripped)){
        auto out=n.base;out[2]=float(stripped.tx);out[5]=float(stripped.ty);return out;
    }
    return current;
}
bool restore(GuestVM *vm,State &s,Node &n) {
    if(!n.shifted)return true;
    std::array<float,6> current{};
    if(!local(vm,n,current)){n.object=0;n.shifted=false;n.affineApplied=false;return true;}
    // An authored new linear transform wins. For the selected uniform-scale
    // branches, translation-only AS2 changes have the known affine removed.
    const auto canonical=canonicalLocal(n,current);
    if(current!=canonical&&!set(vm,s,n,canonical))return false;
    n.shifted=false;n.affineApplied=false;n.installedAffine={};return true;
}
bool restoreMovie(GuestVM *vm,State &s,Movie &m) {
    for(auto &g:m.groups)for(auto &n:g.nodes)if(!restore(vm,s,n))return false;
    for(auto &control:m.menuControls)if(!restore(vm,s,control.node))return false;
    if(!restore(vm,s,m.careerStars))return false;
    return true;
}
bool resolve(GuestVM *vm,State &s,Movie &m,Node &n) {
    if(n.object){std::array<float,6> current{};if(local(vm,n,current))return true;n.object=0;n.shifted=false;n.affineApplied=false;}
    if(m.advances<n.nextResolve)return false;
    n.object=find(vm,s,m.handler,n.path);
    if(!n.object){n.nextResolve=m.advances+120;return false;}
    if(!word(vm,n.object,n.vtable)||!word(vm,n.object+0x44,n.name)){n.object=0;return false;}
    return true;
}
bool hideGameloftLive(GuestVM *vm,State &s,Movie &m) {
    // Original SWFLoad (58a6c/58b48) sets the file enum at +228 before
    // loading the timeline; GetFxByByFlashFile (56120) reads the same field.
    // File 9 is hud.swf, which has no main-menu GLIVE instance. Read on each
    // boundary so handler reuse never leaves a stale negative cache. Unknown
    // or unreadable identities retain the original late-creation hide path.
    std::uint32_t file=0;
    if(m.handler<=UINT32_MAX-0x228u&&word(vm,m.handler+0x228u,file)&&file==9u)
        return !GuestHasStopRequest(vm);
    auto &node=m.gameloftLive;
    if(!resolve(vm,s,m,node)){
        // The AS2 timeline may create this instance after the first lookup.
        // Recheck at the next boundary so it never waits the normal 120 ticks.
        node.nextResolve=m.advances+1;
        return !GuestHasStopRequest(vm);
    }
    std::array<float,6> current{};
    if(!local(vm,node,current)){node.object=0;return !GuestHasStopRequest(vm);}
    // Original gameswf _visible setter (2e8e54 / 3094a8) writes this exact
    // boolean. Both movieclip rendering (30f340) and hit testing (30f6b0)
    // return immediately when it is zero. Preserve transforms and resources.
    if(node.object>UINT32_MAX-0x9bu)return false;
    std::uint8_t visible=0;
    if(!read(vm,node.object+0x9bu,&visible,1))return false;
    if(visible){
        const std::uint8_t hidden=0;
        if(!GuestWrite(vm,node.object+0x9bu,&hidden,1))return false;
    }
    if(!m.gameloftLiveHiddenLogged){
        m.gameloftLiveHiddenLogged=true;char line[256];
        std::snprintf(line,sizeof(line),"[gameloft-live] hidden=1 hit_test_disabled=1 path=%s character=%#x visibility_offset=0x9b",node.path.c_str(),node.object);
        GuestRawLog(line);GuestTrace(vm,@"%s",line);
    }
    return !GuestHasStopRequest(vm);
}
void single(Movie &m,const char *path) { m.groups.push_back({{{path}}}); }
void discoverSelectionControls(GuestVM *vm,State &s,Movie &m) {
    if(!m.menuControls.empty()||m.advances%120!=1)return;
    // Selection-only summary nodes. Flipper parents keep both animated text
    // layers and the star artwork together. Other main-page totals are separate.
    const char *paths[]={"mega_mc.number_flipper_career_cash",
                         "mega_mc.txt_total_career","mega_mc.number_stars",
                         "mega_mc.btn_previous_vehicle","mega_mc.btn_next_vehicle"};
    if(!find(vm,s,m.handler,"mega_mc.car_name_txt"))return;
    for(const char *path:paths)if(!find(vm,s,m.handler,path))return;
    const double offsets[]={20.,20.,20.,20.,-20.};
    const double scales[]={.9,.9,.9,1.,1.};
    for(unsigned i=0;i<5;++i)m.menuControls.push_back({{paths[i]},offsets[i],scales[i]});
}
bool identify(GuestVM *vm,State &s,Movie &m) {
    if(m.kind!=Kind::Unknown)return m.kind==Kind::Loading||m.kind==Kind::CareerSelection||m.kind==Kind::Menu;
    if(m.discoveryDone)return false;
    m.discoveryDone=true;
    // Preserve the current Career/Loading scope. The one additional menu
    // target is the original Back character, with translation only.
    if(find(vm,s,m.handler,"extra_bonus")) {
        m.kind=Kind::Loading;
        // Authored reward text and the separate local panel containing both stars.
        // The full-window background is a different root and stays unchanged.
        single(m,"extra_bonus");single(m,"bg_extra");
    } else if(find(vm,s,m.handler,"CupList")&&find(vm,s,m.handler,"Title")) {
        m.kind=Kind::CareerSelection;
        const char *paths[]={"CupList","Title","btn_flip_next","btn_flip_prev","event_1","event_2","event_3","event_4","event_5","selection_focus"};
        for(const char *p:paths)single(m,p);
    } else if(find(vm,s,m.handler,"mega_mc.btn_back")) {
        m.kind=Kind::Menu;single(m,"mega_mc.btn_back");
    }
    return m.kind==Kind::Loading||m.kind==Kind::CareerSelection||m.kind==Kind::Menu;
}

Movie *movie(GuestVM *vm,State &s,std::uint32_t handler) {
    std::uint32_t root=0,def=0,context=0;
    if(!word(vm,handler+0x3c,root)||!root||!word(vm,root+0xc,def)||!def||!word(vm,handler+0x38,context))return nullptr;
    auto &m=s.movies[handler];
    if(m.root!=root||m.definition!=def||m.context!=context){m={};m.handler=handler;m.root=root;m.definition=def;m.context=context;}
    return &m;
}
Rect safe(const AS6OriginalUIHostMetrics &h) {
    const auto *w=h.windowBoundsPoints,*s=h.safeNormalizedRect;
    return {w[0]+s[0]*w[2],w[1]+s[1]*w[3],w[0]+(s[0]+s[2])*w[2],w[1]+(s[1]+s[3])*w[3]};
}
P hostToView(const AS6OriginalUIHostMetrics &h,P p) {
    const auto *a=h.windowToOriginalView;return {a[0]*p.x+a[2]*p.y+a[4],a[1]*p.x+a[3]*p.y+a[5]};
}
bool pixelPoint(const AS6OriginalUIHostMetrics &h,P host,float scale,std::int32_t (&p)[2]) {
    const auto v=hostToView(h,host);
    if(!finite(v)||!std::isfinite(scale)||scale<=0||scale>16||std::abs(v.x*scale)>1e7||std::abs(v.y*scale)>1e7)return false;
    p[0]=std::int32_t(v.x*scale);p[1]=std::int32_t(v.y*scale);return true;
}
bool scaleAndDriver(GuestVM *vm,float &scale,std::uint32_t &driver) {
    const auto view=GuestGLView();std::uint32_t game=0,device=0;
    return view&&read(vm,view+0x54,&scale,4)&&word(vm,0x70b230,game)&&word(vm,game+0x164,device)&&word(vm,device+0x10,driver)&&driver;
}
bool stagePoint(GuestVM *vm,State &s,const Movie &m,float x,float y,P &out) {
    const float p[]={x,y};float q[2]{};
    if(!writeScratch(vm,s,600,p,8)||!call(vm,ScreenToStage,{m.root,s.scratch+600})||!read(vm,s.scratch+600,q,8))return false;
    out={double(q[0])*20.,double(q[1])*20.};return finite(out);
}
bool hostToStage2D(GuestVM *vm,State &s,const Movie &m,const AS6OriginalUIHostMetrics &h,P host,float scale,std::uint32_t driver,P &out) {
    std::int32_t p[2]{};
    if(!pixelPoint(h,host,scale,p)||!writeScratch(vm,s,576,p,8)||
       !call(vm,InputOrientation,{driver,s.scratch+576,s.scratch+580})||!read(vm,s.scratch+576,p,8))return false;
    return stagePoint(vm,s,m,float(p[0]),float(p[1]),out);
}
bool map2D(GuestVM *vm,State &s,Movie &m,const AS6OriginalUIHostMetrics &h,float scale,std::uint32_t driver,Mapping &map) {
    std::array<std::uint64_t,32> key{};key[0]=h.revision;key[1]=driver;
    std::uint32_t scaleBits=0,orientation=0,viewportPointer=0,viewport=0;
    std::memcpy(&scaleBits,&scale,4);key[2]=scaleBits;
    std::uint32_t rootViewport[4]{},stageRect[4]{},driverViewport[13]{};
    m.mappingReason="root viewport/stage rectangle read";
    if(!read(vm,m.root+0x24,rootViewport,16)||!read(vm,m.definition+0xb4,stageRect,16))return false;
    m.mappingReason="driver orientation/viewport pointer read";
    if(!word(vm,driver+0x11c,orientation)||!word(vm,driver+0xa4,viewportPointer)||!word(vm,viewportPointer,viewport))return false;
    // Original51c040 loads driver+a4 -> pointer[0] and accesses through +30;
    // 13 words cover the exact complete prefix that original code can read.
    m.mappingReason="driver viewport prefix read";
    if(!read(vm,viewport,driverViewport,sizeof(driverViewport)))return false;
    key[3]=orientation;key[4]=viewport;
    for(unsigned i=0;i<4;++i){key[5+i]=rootViewport[i];key[9+i]=stageRect[i];}
    for(unsigned i=0;i<13;++i)key[13+i]=driverViewport[i];
    if(m.mappingValid&&key==m.mappingKey){map=m.mapping;return true;}
    const auto *w=h.windowBoundsPoints;const auto a=corners({w[0],w[1],w[0]+w[2],w[1]+w[3]});std::array<P,4>b{};
    m.mappingReason="original Host->view->orientation->stage call";
    for(unsigned i=0;i<4;++i)if(!hostToStage2D(vm,s,m,h,a[i],scale,driver,b[i]))return false;
    m.mappingReason="2D homography singular/nonfinite";
    if(!homography(a,b,map.hostToStage)||!homography(b,a,map.stageToHost))return false;
    m.mappingKey=key;m.mapping=map;m.mappingValid=true;return true;
}
bool ray(GuestVM *vm,State &s,std::uint32_t manager,const AS6OriginalUIHostMetrics &h,float scale,P host,std::array<float,6>&r) {
    std::int32_t p[2]{};
    return pixelPoint(h,host,scale,p)&&call(vm,MakeRay,{s.scratch+768,manager,std::uint32_t(p[0]),std::uint32_t(p[1])})&&read(vm,s.scratch+768,r.data(),24);
}
V vec(const float *p){return {p[0],p[1],p[2]};}
bool planeToStage(GuestVM *vm,State &s,const Movie &m,P uv,int width,int height,P &stage) {
    return stagePoint(vm,s,m,float(uv.x*(width-1)),float(uv.y*(height-1)),stage);
}
bool map3D(GuestVM *vm,State &s,Movie &m,const AS6OriginalUIHostMetrics &h,float scale,Mapping &map) {
    m.mappingReason="original manager access";
    if(!m.manager&&(!call(vm,GetSWFManager,{},&m.manager)||!m.manager))return false;
    if(!m.rayManager&&(!call(vm,GetRayManager,{},&m.rayManager)||!m.rayManager))return false;
    const auto manager=m.manager,rayManager=m.rayManager;
    int controller=-1;
    std::uint32_t poolIndex=0xffffffffu;
    std::array<std::uint32_t,6> indices{},handlers{};
    indices.fill(0xffffffffu);
    for(unsigned i=0;i<6;++i){
        if(word(vm,manager+4+4*i,indices[i])&&indices[i]<6&&
           word(vm,manager+0x1c+4*indices[i],handlers[i])&&handlers[i]==m.handler){controller=int(i);poolIndex=indices[i];}
    }
    const auto identityLog=[&](const char *reason,std::uint32_t cache_slot,std::uint32_t node,bool ready){
        if(ready){if(m.mappingIdentityReadyLogged)return;m.mappingIdentityReadyLogged=true;}
        else if(m.mappingIdentityRejectLogs++>=3)return;
        char line[768];std::snprintf(line,sizeof(line),
            "[foreground-ui-map] %s manager=%#x handler=%#x controller=%d pool_index=%#x cache_slot=%#x node=%#x indices={%#x,%#x,%#x,%#x,%#x,%#x} handlers={%#x,%#x,%#x,%#x,%#x,%#x}",
            reason,manager,m.handler,controller,poolIndex,cache_slot,node,
            indices[0],indices[1],indices[2],indices[3],indices[4],indices[5],handlers[0],handlers[1],handlers[2],handlers[3],handlers[4],handlers[5]);
        GuestRawLog(line);GuestTrace(vm,@"%s",line);
    };
    m.mappingReason="active controller identity";
    if(controller<0){identityLog("controller pending",0xffffffffu,0,false);return false;}
    std::uint32_t cache_slot=0xffffffffu,node=0;
    m.mappingReason="SWFManager plane node cache slot";
    // Original5bbb4..5bce4 deduplicates scene nodes into six runtime slots.
    // This slot is distinct from sFlashConfig's semantic planeID2.
    if(!word(vm,manager+0x34+4*controller,cache_slot)||cache_slot>=6||
       !word(vm,manager+0x64+4*cache_slot,node)||!node){identityLog("node slot pending",cache_slot,node,false);return false;}
    identityLog("node slot ready",cache_slot,node,true);
    std::uint32_t vt=0,getW=0,getH=0,widthWord=0,heightWord=0;
    m.mappingReason="original RTT width/height";
    if(!word(vm,m.handler,vt)||!word(vm,vt+0x48,getW)||!word(vm,vt+0x4c,getH)||
       !call(vm,getW,{m.handler},&widthWord)||!call(vm,getH,{m.handler},&heightWord)||
       widthWord<2||heightWord<2||widthWord>16384||heightWord>16384)return false;
    float a[3]{},b[3]{},c[3]{};
    m.mappingReason="original live plane corners";
    if(!call(vm,PlaneCorners,{node,s.scratch+832,s.scratch+844,s.scratch+856})||
       !read(vm,s.scratch+832,a,12)||!read(vm,s.scratch+844,b,12)||!read(vm,s.scratch+856,c,12))return false;
    const auto *w=h.windowBoundsPoints;const auto host=corners({w[0],w[1],w[0]+w[2],w[1]+w[3]});std::array<P,4>stage{};
    m.mappingReason="original ray/plane projection";
    for(unsigned i=0;i<4;++i){std::array<float,6>r{};P uv;
        if(!ray(vm,s,rayManager,h,scale,host[i],r)||!rayToUV(vec(r.data()),vec(r.data()+3),vec(a),vec(b),vec(c),uv)||
           !planeToStage(vm,s,m,uv,int(widthWord),int(heightWord),stage[i]))return false;}
    m.mappingReason="3D homography singular/nonfinite";
    if(!homography(host,stage,map.hostToStage)||!homography(stage,host,map.stageToHost))return false;
    std::array<P,4>clipCorners{};
    const auto uvCorners=corners({0,0,1,1});
    for(unsigned i=0;i<4;++i)if(!planeToStage(vm,s,m,uvCorners[i],int(widthWord),int(heightWord),clipCorners[i]))return false;
    if(!bounds(clipCorners,map.stageClip))return false;
    // Non-center controls detect axis swaps/flips as well as projection error.
    // All use the real finite-plane collision implementation and current camera.
    m.mappingReason="original finite plane non-center round-trip";
    for(const P uv:{P{.25,.35},P{.7,.3},P{.4,.75}}) {
        P expectedStage,expectedHost;
        if(!planeToStage(vm,s,m,uv,int(widthWord),int(heightWord),expectedStage)||!map.stageToHost.project(expectedStage,expectedHost))return false;
        std::array<float,6>r{};float actual[2]{};
        if(!ray(vm,s,rayManager,h,scale,expectedHost,r)||!writeScratch(vm,s,768,r.data(),24)||
           !call(vm,FlashRayPosition,{s.scratch+896,rayManager,std::uint32_t(controller),s.scratch+768,node,3})||!read(vm,s.scratch+896,actual,8))return false;
        P originalStage,originalHost;
        if(!stagePoint(vm,s,m,actual[0],actual[1],originalStage)||!map.stageToHost.project(originalStage,originalHost))return false;
        const double error=std::hypot(originalHost.x-expectedHost.x,originalHost.y-expectedHost.y);
        if(!std::isfinite(error)||error>1.5)return false;map.roundTripPixels=std::max(map.roundTripPixels,error);
    }
    map.plane=true;return true;
}
struct Geometry { Node *node=nullptr;M parent{};std::array<P,4> stage{};std::array<float,6> base{},current{},desired{}; };
bool nodeGeometry(GuestVM *vm,State &s,Node &n,Geometry &geo) {
    std::array<float,6>l{},world{};std::uint32_t pointer=0,boundsFunction=0;
    if(!local(vm,n,l)||!word(vm,n.vtable+0x12c,boundsFunction)||!boundsFunction)return false;
    const float empty[]={0,0,0,0};float r[4]{};
    // Virtual+12c computes the original character bounds in parent twips;
    // it includes the original local matrix and current animated child bounds.
    if(!writeScratch(vm,s,640,empty,16)||!call(vm,boundsFunction,{n.object,s.scratch+640})||!read(vm,s.scratch+640,r,16)||
       !call(vm,WorldMatrix,{n.object},&pointer)||!read(vm,pointer,world.data(),24))return false;
    for(float x:r)if(!std::isfinite(x))return false;
    if(r[1]<=r[0]||r[3]<=r[2]||r[1]-r[0]>1e7||r[3]-r[2]>1e7)return false;
    M inv; if(!inverse(matrix(l.data()),inv))return false;
    geo.node=&n;geo.parent=multiply(matrix(world.data()),inv);geo.current=l;
    geo.base=n.shifted&&l==n.applied?n.base:l;
    const double dx=double(l[2])-geo.base[2],dy=double(l[5])-geo.base[5];
    // Bounds include the installed local translation. Recover the canonical
    // parent-space box mathematically, without a restore/set pair at every
    // touch/display boundary. The real character matrix remains hit-visible.
    auto p=corners({r[0]-dx,r[2]-dy,r[1]-dx,r[3]-dy});for(unsigned i=0;i<4;++i)geo.stage[i]=apply(geo.parent,p[i]);return true;
}
bool projectGroup(const std::vector<Geometry>&g,const Mapping&map,P stageShift,Rect &out) {
    bool first=true;
    for(const auto &geo:g){std::array<P,4>p{};
        for(unsigned i=0;i<4;++i)if(!map.stageToHost.project({geo.stage[i].x+stageShift.x,geo.stage[i].y+stageShift.y},p[i]))return false;
        Rect b;if(!bounds(p,b))return false;
        if(first){out=b;first=false;}else{out.x0=std::min(out.x0,b.x0);out.y0=std::min(out.y0,b.y0);out.x1=std::max(out.x1,b.x1);out.y1=std::max(out.y1,b.y1);}}
    return !first;
}
bool applyGroup(GuestVM *vm,State &s,Movie &m,Group &group,const Mapping &map,Rect safeRect) {
    const auto canonical=[&](){for(auto &n:group.nodes)if(!restore(vm,s,n))return false;return true;};
    std::vector<Geometry>geometries;bool complete=true;
    for(auto &n:group.nodes){if(!resolve(vm,s,m,n)){complete=false;continue;}
        Geometry g;
        if(nodeGeometry(vm,s,n,g))geometries.push_back(g);else complete=false;}
    if(!complete||geometries.empty())return canonical();
    // Do not pull a clipped/off-plane flipper card into visibility. Labels must
    // belong to the current finite RTT surface before and after translation.
    const auto inside=[&](P p){return !map.plane||(p.x>=map.stageClip.x0-.5&&p.x<=map.stageClip.x1+.5&&p.y>=map.stageClip.y0-.5&&p.y<=map.stageClip.y1+.5);};
    for(const auto &g:geometries)for(P p:g.stage)if(!inside(p))return canonical();
    P shift{};Rect before{},after{};
    if(!projectGroup(geometries,map,shift,before))return canonical();
    after=before;
    for(unsigned i=0;i<6;++i){P d;if(!correction(after,safeRect,d))return canonical();
        if(std::abs(d.x)<.05&&std::abs(d.y)<.05)break;
        const P c={(after.x0+after.x1)*.5,(after.y0+after.y1)*.5};P x,y;
        if(!map.hostToStage.project(c,x)||!map.hostToStage.project({c.x+d.x,c.y+d.y},y))return canonical();
        shift.x+=y.x-x.x;shift.y+=y.y-x.y;
        if(!projectGroup(geometries,map,shift,after))return canonical();}
    P residual;if(!correction(after,safeRect,residual)||std::abs(residual.x)>.25||std::abs(residual.y)>.25)return canonical();
    for(const auto &g:geometries)for(P p:g.stage)if(!inside({p.x+shift.x,p.y+shift.y}))return canonical();
    double minEdgeRatio=1,maxEdgeRatio=1;
    for(const auto &g:geometries)for(unsigned i=0;i<4;++i){P a,b,c,d;const auto p=g.stage[i],q=g.stage[(i+1)%4];
        if(!map.stageToHost.project(p,a)||!map.stageToHost.project(q,b)||!map.stageToHost.project({p.x+shift.x,p.y+shift.y},c)||!map.stageToHost.project({q.x+shift.x,q.y+shift.y},d))return canonical();
        const double beforeLength=std::hypot(b.x-a.x,b.y-a.y),afterLength=std::hypot(d.x-c.x,d.y-c.y);
        if(beforeLength>1e-8){minEdgeRatio=std::min(minEdgeRatio,afterLength/beforeLength);maxEdgeRatio=std::max(maxEdgeRatio,afterLength/beforeLength);}}
    // Stage delta is converted through each real parent inverse. Four local
    // linear components and all text/font/style objects remain byte-exact.
    for(auto &g:geometries){auto &n=*g.node;M inv;
        if(!inverse(g.parent,inv))return canonical();
        const auto delta=vector(inv,shift);g.desired=g.base;
        g.desired[2]+=float(delta.x);g.desired[5]+=float(delta.y);
        if(!std::isfinite(g.desired[2])||!std::isfinite(g.desired[5]))return canonical();}
    bool changed=false;
    for(auto &g:geometries){auto &n=*g.node;n.base=g.base;n.applied=g.desired;
        const bool same=g.current[0]==n.applied[0]&&g.current[1]==n.applied[1]&&g.current[3]==n.applied[3]&&g.current[4]==n.applied[4]&&
            std::abs(double(g.current[2])-n.applied[2])<.001&&std::abs(double(g.current[5])-n.applied[5])<.001;
        if(same)n.applied=g.current;else{if(!set(vm,s,n,n.applied))return false;changed=true;}n.shifted=n.applied!=n.base;}
    if(changed&&s.logs<64){++s.logs;GuestTrace(vm,@"[original-ui] %s handler=%#x plane=%d bbox=(%.2f %.2f %.2f %.2f)->(%.2f %.2f %.2f %.2f) stage_delta=(%.3f %.3f) ray_roundtrip=%.3f projected_edge_ratio=(%.5f %.5f)",
        group.nodes.front().path.c_str(),m.handler,map.plane,before.x0,before.y0,before.x1,before.y1,after.x0,after.y0,after.x1,after.y1,shift.x,shift.y,map.roundTripPixels,minEdgeRatio,maxEdgeRatio);}
    return true;
}
bool applyMenuTranslation(GuestVM *vm,State &s,Movie &m,Node &n,
                          const AS6OriginalUIHostMetrics &host,const Mapping &mapping,
                          double physicalDX,const char *label,bool &readyLogged,double uniformScale=1) {
    if(!std::isfinite(uniformScale)||uniformScale<=0||uniformScale>1)return false;
    std::array<float,6>current{},world{};std::uint32_t pointer=0;
    if(!local(vm,n,current)||!call(vm,WorldMatrix,{n.object},&pointer)||!read(vm,pointer,world.data(),24))return false;
    M invLocal,invParent;if(!inverse(matrix(current.data()),invLocal))return false;
    const auto parent=multiply(matrix(world.data()),invLocal);if(!inverse(parent,invParent))return false;
    const double hostDX=physicalDX/host.windowScreenScale;
    const P origin{host.windowBoundsPoints[0]+host.windowBoundsPoints[2]*.5,host.windowBoundsPoints[1]+host.windowBoundsPoints[3]*.5};P a,b;
    if(!mapping.hostToStage.project(origin,a)||!mapping.hostToStage.project({origin.x+hostDX,origin.y},b))return false;
    const P stageDelta{b.x-a.x,b.y-a.y},delta=vector(invParent,stageDelta);
    const auto base=canonicalLocal(n,current);auto next=base;
    // Keep each authored origin. Only the three selection summary branches
    // reduce their text/icon axes; Back and arrows retain exact linear floats.
    if(uniformScale!=1)for(unsigned i:{0u,1u,3u,4u})next[i]=float(double(base[i])*uniformScale);
    next[2]+=float(delta.x);next[5]+=float(delta.y);
    if(!std::isfinite(next[2])||!std::isfinite(next[5]))return false;
    const bool same=current[0]==next[0]&&current[1]==next[1]&&current[3]==next[3]&&current[4]==next[4]&&
        std::abs(double(current[2])-next[2])<.001&&std::abs(double(current[5])-next[5])<.001;
    if(!same&&!set(vm,s,n,next))return false;
    n.base=base;n.applied=same?current:next;n.shifted=n.applied!=n.base;n.affineApplied=n.shifted;n.installedAffine={uniformScale,0,(1-uniformScale)*base[2]+delta.x,0,uniformScale,(1-uniformScale)*base[5]+delta.y};
    if(!readyLogged){readyLogged=true;char line[640];std::snprintf(line,sizeof(line),
        "[original-ui-%s] path=%s handler=%#x requested_physical_px=(%.0f,0) window_screen_scale=%.6f Host_delta=(%.6f,0) stage_delta=(%.6f,%.6f) local_delta=(%.6f,%.6f) uniform_scale=%.6f linear_floats_unchanged=%d",
        label,n.path.c_str(),m.handler,physicalDX,host.windowScreenScale,hostDX,stageDelta.x,stageDelta.y,delta.x,delta.y,uniformScale,uniformScale==1);GuestRawLog(line);GuestTrace(vm,@"%s",line);}
    return !GuestHasStopRequest(vm);
}
bool applyBack20(GuestVM *vm,State &s,Movie &m,const AS6OriginalUIHostMetrics &host,bool metricsReady) {
    const auto pending=[&](const char *reason){
        if(m.backRejectLogs++<3){char line[256];std::snprintf(line,sizeof(line),"[original-ui-back] pending handler=%#x reason=%s; original Back retained",m.handler,reason);GuestRawLog(line);}
        return restoreMovie(vm,s,m);
    };
    if(!metricsReady||!std::isfinite(host.windowScreenScale)||host.windowScreenScale<=0)return pending("native screen metrics");
    float scale=0;std::uint32_t driver=0;Mapping mapping;
    if(!scaleAndDriver(vm,scale,driver))return pending("original input mapping");
    if(!map2D(vm,s,m,host,scale,driver,mapping))return pending(m.mappingReason);
    if(m.groups.size()!=1||m.groups[0].nodes.size()!=1)return false;
    auto &n=m.groups[0].nodes[0];if(!resolve(vm,s,m,n))return pending("Back instance");
    if(!applyMenuTranslation(vm,s,m,n,host,mapping,20.,"back",m.backReadyLogged))return false;
    for(auto &control:m.menuControls){
        if(!resolve(vm,s,m,control.node)){if(!restore(vm,s,control.node))return false;continue;}
        if(!applyMenuTranslation(vm,s,m,control.node,host,mapping,control.physicalDX,"selection-control",control.readyLogged,control.uniformScale))return false;
    }
    return !GuestHasStopRequest(vm);
}
bool applyResourceForeground(GuestVM *vm,State &s,Movie &m,const AS6OriginalUIHostMetrics &host) {
    float stage[4]{};
    // Fixed user layout: horizontal90%, 5% on each authored stage side.
    // Y is exactly unchanged. No Host safe-area ratio, ray fit or bounds fit.
    if(!read(vm,m.definition+0xb4,stage,sizeof(stage)))return false;
    for(float f:stage)if(!std::isfinite(f))return false;
    const double width=double(stage[1])-stage[0],height=double(stage[3])-stage[2];
    if(width<=0||height<=0)return false;
    const M stageAffine{.9,0,.1*stage[0]+.05*width,0,1,0};
    unsigned applied=0,changed=0;
    for(auto &group:m.groups)for(auto &n:group.nodes){
        if(!resolve(vm,s,m,n))continue;
        std::array<float,6>current{},world{};std::uint32_t pointer=0;
        if(!local(vm,n,current)||!call(vm,WorldMatrix,{n.object},&pointer)||!read(vm,pointer,world.data(),24))return false;
        M inv;if(!inverse(matrix(current.data()),inv))return false;
        const auto parent=multiply(matrix(world.data()),inv);
        const auto base=canonicalLocal(n,current);
        M desired,prefix;if(!affineLocalInStage(matrix(base.data()),parent,stageAffine,desired,prefix))return false;
        const std::array<float,6>next={float(desired.a),float(desired.b),float(desired.tx),float(desired.c),float(desired.d),float(desired.ty)};
        for(float f:next)if(!std::isfinite(f))return false;
        bool same=true;for(unsigned i=0;i<6;++i)if(std::abs(double(next[i])-current[i])>(i==2||i==5?.001:1e-7))same=false;
        if(!same){if(!set(vm,s,n,next))return false;++changed;}
        n.base=base;n.applied=same?current:next;n.shifted=n.applied!=n.base;n.affineApplied=n.shifted;n.installedAffine=prefix;++applied;
    }
    if(applied&&!m.selectionReadyLogged){m.selectionReadyLogged=true;char line[640];
        std::snprintf(line,sizeof(line),"[foreground-ui] mode=horizontal5 kind=%u handler=%#x groups=%u changed=%u sx=0.900000 sy=1.000000 movie_stage=(%.3f,%.3f,%.3f,%.3f) side_inset_twips=%.3f stage_tx=%.3f stage_ty=0.000 Host=(%.2f,%.2f); background and Back untouched",
            unsigned(m.kind),m.handler,applied,changed,double(stage[0]),double(stage[1]),double(stage[2]),double(stage[3]),.05*width,stageAffine.tx,host.windowBoundsPoints[2],host.windowBoundsPoints[3]);
        GuestRawLog(line);GuestTrace(vm,@"%s",line);
    }
    return !GuestHasStopRequest(vm);
}
bool applyCareerStars(GuestVM *vm,State &s,Movie &m,const AS6OriginalUIHostMetrics &,bool) {
    auto &node=m.careerStars;
    if(!resolve(vm,s,m,node))return !GuestHasStopRequest(vm);
    // Restore the authored matrix before each calculation. The original AS2
    // position is the anchor: never relocate this branch using projected bounds.
    if(!restore(vm,s,node))return false;
    std::array<float,6> current{},next{};
    if(!local(vm,node,current))return !GuestHasStopRequest(vm);
    if(!careerStarLocal(current,next))return !GuestHasStopRequest(vm);
    if(!set(vm,s,node,next))return false;
    node.base=current;node.applied=next;node.shifted=next!=current;
    node.affineApplied=node.shifted;
    constexpr double factor=CareerStarScale;
    node.installedAffine={factor,0,(1-factor)*current[2],0,factor,(1-factor)*current[5]};
    if(!m.careerStarsReadyLogged){m.careerStarsReadyLogged=true;char line[384];
        std::snprintf(line,sizeof(line),"[career-stars] mode=authored-anchor path=star_career scale=0.820000 icon_and_tf_same_parent=1 translation_unchanged=1 local_anchor=(%.3f %.3f)",double(current[2]),double(current[5]));
        GuestRawLog(line);GuestTrace(vm,@"%s",line);
    }
    return !GuestHasStopRequest(vm);
}
}
}

extern "C" bool AS6OriginalUIBeforeAdvance(GuestVM *vm,std::uint32_t handler) {
    using namespace as6_original_ui;
    if(!vm||!GuestDiagnosticSnapshotLockHeld(vm))return false;
    std::lock_guard<std::recursive_mutex>guard(statesMutex);auto &s=states[vm];auto *m=movie(vm,s,handler);
    if(m&&!m->hasAdvanced){m->hasAdvanced=true;if(m->kind==Kind::Unknown)m->discoveryDone=false;}
    return !m||restoreMovie(vm,s,*m);
}
extern "C" bool AS6OriginalUIApply(GuestVM *vm,std::uint32_t handler) {
    using namespace as6_original_ui;
    if(!vm||!GuestDiagnosticSnapshotLockHeld(vm))return false;
    AS6OriginalUIHostMetrics h{};const bool metricsReady=GuestCopyOriginalUIHostMetrics(&h);if(!metricsReady) {
        std::lock_guard<std::recursive_mutex>guard(statesMutex);auto &s=states[vm];
        if(s.metricsRejectLogs++<2)GuestTrace(vm,@"[original-ui] Host metrics unavailable at pc=%#x; fixed5%% layout uses authored movie stage",GuestPC(vm));
    }
    std::lock_guard<std::recursive_mutex>guard(statesMutex);auto &s=states[vm];auto *m=movie(vm,s,handler);
    if(!m)return true;
    ++m->advances;
    // Reassert at Advance/Display/Touch boundaries, including after an AS2
    // timeline restores visibility. A hidden button cannot take input.
    if(!hideGameloftLive(vm,s,*m))return false;
    if(!identify(vm,s,*m))return !GuestHasStopRequest(vm);
    if(!s.scratch)s.scratch=GuestAlloc(vm,4096);if(!s.scratch)return false;
    float scale=0;std::uint32_t driver=0;
    scaleAndDriver(vm,scale,driver); // Diagnostic only: layout uses native ratios and authored stage.
    if(!m->identifiedLog){m->identifiedLog=true;GuestTrace(vm,@"[original-ui] identified kind=%u handler=%#x root=%#x definition=%#x Host=(%.1f %.1f) safe=(%.4f %.4f %.4f %.4f) view=(%.1f %.1f) scale=%.2f driver=%#x revision=%llu",
        unsigned(m->kind),handler,m->root,m->definition,h.windowBoundsPoints[2],h.windowBoundsPoints[3],h.safeNormalizedRect[0],h.safeNormalizedRect[1],h.safeNormalizedRect[2],h.safeNormalizedRect[3],h.originalViewBoundsPoints[2],h.originalViewBoundsPoints[3],double(scale),driver,(unsigned long long)h.revision);}
    if(m->kind==Kind::Menu){discoverSelectionControls(vm,s,*m);return applyBack20(vm,s,*m,h,metricsReady);}
    if(m->kind==Kind::Loading||m->kind==Kind::CareerSelection){
        if(!applyResourceForeground(vm,s,*m,h))return false;
        return m->kind!=Kind::CareerSelection||applyCareerStars(vm,s,*m,h,metricsReady);
    }
    return restoreMovie(vm,s,*m);

}
extern "C" bool AS6OriginalUIBeforeUnload(GuestVM *vm) {
    using namespace as6_original_ui;
    std::lock_guard<std::recursive_mutex>guard(statesMutex);const auto it=states.find(vm);
    if(it==states.end())return true;for(auto &m:it->second.movies)if(!restoreMovie(vm,it->second,m.second))return false;
    it->second.movies.clear();return true;
}
extern "C" void AS6OriginalUIForgetVM(GuestVM *vm) {
    std::lock_guard<std::recursive_mutex>guard(as6_original_ui::statesMutex);as6_original_ui::states.erase(vm);
}
