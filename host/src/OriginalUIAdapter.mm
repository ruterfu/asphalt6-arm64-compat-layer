#import "GuestVM.h"
#include "OriginalUIAdapter.hpp"
#include "OriginalUIBoundary.hpp"
#include "OriginalUIGeometry.hpp"
#include "OriginalUIHostMetrics.hpp"
#include "CareerStarLayout.hpp"
#include "HDArtworkPack.hpp"
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

// Horizontal stretch of the original canvas (HLE_uikit.m); 1 when unknown.
extern "C" double AS6CanvasHorizontalStretch(void);

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
struct MenuControl { Node node;double physicalDX=0;double uniformScale=1;bool readyLogged=false;double physicalDY=0;bool unstretch=false; };
// A node scaled about a fixed point of its own art (local twips).
struct PivotControl { Node node;P pivot{};double sx=1,sy=1; };
struct Mapping {
    H hostToStage,stageToHost;
    bool plane=false;
    Rect stageClip{};
    double roundTripPixels=0;
};
enum class Kind { Unknown, Loading, Menu, Race, TrackPlane, CareerSelection, PauseMenu, RaceHud, Multiplayer, Paint, Tuning };
struct Movie {
    std::uint32_t handler=0,root=0,definition=0,context=0;
    Kind kind=Kind::Unknown;
    Node gameloftLive{"mega_mc.btn_GLIVE"};
    Node careerStars{"star_career"};
    Node carInfo{"mega_mc.car_info_stuff"},carInfoBar{"mega_mc.car_info_stuff.low_bar"},carInfoBackdrop;
    bool careerStarsReadyLogged=false;
    bool gameloftLiveHiddenLogged=false;
    std::vector<Group> groups;
    std::vector<MenuControl> menuControls;
    // Round buttons narrowed back to their authored shape on the stretched canvas.
    std::vector<MenuControl> roundButtons;
    bool roundButtonsDiscovered=false;
    std::vector<PivotControl> pivotControls;
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
    bool stageWidened=false;
    int onMonitor=-1;
    std::array<Node,4> monitorBackdrops{};
    std::array<unsigned,4> backdropTries{};
    std::array<Node,2> offstage{Node{"confirm_buy"},Node{"update_mc"}};
};
struct State {
    std::uint32_t scratch=0;
    // Car selection's career summary (cash, total, stars) as last placed, in
    // stage coordinates normalised to 0..1, so the tuning shop matches it exactly.
    std::array<M,3> summary{};
    bool summaryValid=false;
    // Office monitor movie definitions and the stage right edge they were widened to.
    std::map<std::uint32_t,float> widenedStages;
    std::uint32_t monitorScreen=0;
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
    for(auto &control:m.roundButtons)if(!restore(vm,s,control.node))return false;
    for(auto &control:m.pivotControls)if(!restore(vm,s,control.node))return false;
    if(!restore(vm,s,m.careerStars))return false;
    if(!restore(vm,s,m.carInfoBar))return false;
    if(!restore(vm,s,m.carInfoBackdrop))return false;
    if(!restore(vm,s,m.carInfo))return false;
    return true;
}
bool resolve(GuestVM *vm,State &s,Movie &m,Node &n) {
    if(n.object){std::array<float,6> current{};if(local(vm,n,current))return true;n.object=0;n.shifted=false;n.affineApplied=false;}
    // A node without a path is located by its owner (e.g. unnamed art).
    if(n.path.empty()||m.advances<n.nextResolve)return false;
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
    // The vehicle arrows also move 40 px inwards and 20 px up. Once the career
    // summary loses the stretch, its cash and total lines move left to the
    // stars' left edge.
    const double offsets[]={-27.,-11.,20.,40.,-40.};
    const double scales[]={.9,.9,.9,1.,1.};
    const double rises[]={0.,0.,0.,-20.,-20.};
    // The career summary (first three) also loses the canvas stretch.
    for(unsigned i=0;i<5;++i)m.menuControls.push_back({{paths[i]},offsets[i],scales[i],false,rises[i],i<3});
}
// Back, info and skip buttons are drawn at 80% of their authored size.
constexpr double RoundButtonScale=.8;
// The canvas stretch makes round buttons oval; scaling their x axis by its
// inverse restores the authored shape. 1 when the screen is not wider.
double roundButtonXScale() {
    const double stretch=AS6CanvasHorizontalStretch();
    return std::isfinite(stretch)&&stretch>1.001&&stretch<3?1/stretch:1;
}
void discoverRoundButtons(GuestVM *vm,State &s,Movie &m) {
    if(m.roundButtonsDiscovered||m.advances%120!=1)return;
    m.roundButtonsDiscovered=true;
    for(const char *path:{"mega_mc.btn_i","mega_mc.btn_free_view","mega_mc.btn_color","mega_mc.btn_tunning"})
        if(find(vm,s,m.handler,path))m.roundButtons.push_back({{path},0.,RoundButtonScale});
    // The race button and the garage joystick (centred on its origin) are only
    // made round again.
    for(const char *path:{"mega_mc.btn_race","mega_mc.Joystick"})
        if(find(vm,s,m.handler,path))m.roundButtons.push_back({{path},0.,1.});
}
bool identify(GuestVM *vm,State &s,Movie &m) {
    if(m.kind!=Kind::Unknown)return m.kind==Kind::Loading||m.kind==Kind::CareerSelection||m.kind==Kind::Menu||m.kind==Kind::PauseMenu||m.kind==Kind::RaceHud||m.kind==Kind::Multiplayer||m.kind==Kind::Paint||m.kind==Kind::Tuning;
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
    } else if(find(vm,s,m.handler,"menu_main.resume_btn")) {
        m.kind=Kind::PauseMenu;
        // Wide buttons of the pause and options pages (applyPauseButtons relies on
        // this order: 8 buttons, then the question dialog).
        for(const char *p:{"menu_main.resume_btn","menu_main.request_btn","menu_main.option_btn","menu_main.request2_btn",
                           "menu_main_option.control_btn","menu_main_option.video_btn","menu_main_option.audio_btn",
                           "menu_main_option.help_btn"})single(m,p);
        // The question dialog's content (not its full-screen dimmer).
        for(const char *p:{"menu_question.Question_txt","menu_question.no_btn","menu_question.btn_exception_name"})single(m,p);
        m.groups.push_back({{Node{}}}); // question frame: unnamed, bound in applyPauseButtons
        // Round Back buttons of the options pages: round again, then 80%.
        const double round=RoundButtonScale*roundButtonXScale();
        for(const char *p:{"menu_main_option.back_btn","menu_controls.component_controls.back_btn",
                           "menu_custom_controls.back_custom_controls_btn","menu_help.component_help.back_btn",
                           "menu_sound.component_sound.back_btn","menu_video.component_video.back_btn"})
            m.pivotControls.push_back({{p},{1158,1190},round,RoundButtonScale});
    } else if(find(vm,s,m.handler,"menu_1.btn_back_main")) {
        m.kind=Kind::Multiplayer;
        // Back of every multiplayer page; they share one authored corner.
        for(const char *p:{"menu_1.btn_back_main","menu_2.btn_back_main","menu_3.btn_back","menu_4.btn_back_connectionType",
                           "menu_5.btn_back_host","menu_6.btn_back_host","menu_7.btn_back_join","menu_8.btn_back_join",
                           "menu_9.btn_back_lobby","menu_10.btn_back_loggin","menu_11.btn_back_search","menu_12.btn_back_leaderboard",
                           "menu_13.btn_back_leadSelect","menu_15.btn_back_academy","menu_16.btn_back_invite","menu_17.btn_back_search",
                           "menu_19.btn_back_leaderboard","menu_21.btn_back_loggin"})single(m,p);
    } else if(find(vm,s,m.handler,"color_menu")&&find(vm,s,m.handler,"btn_decals")) {
        // Paint shop: round buttons first, then the colour grids.
        m.kind=Kind::Paint;
        for(const char *p:{"btn_color","btn_custom_color","btn_decals","btn_tunning","color_menu","custom_color_menu"})single(m,p);
    } else if(find(vm,s,m.handler,"menu_tunning_shop")&&find(vm,s,m.handler,"txt_career_cash")) {
        // Tuning shop: the career summary (as on the car selection page), the
        // category tabs and parts grid, then the stats panel and its frame.
        m.kind=Kind::Tuning;
        for(const char *p:{"txt_number_stars","txt_total_career","txt_career_cash",
                           "btn_tunning_category_engine","btn_tunning_category_handling","btn_tunning_category_nitro",
                           "btn_tunning_category_sponsor","menu_tunning_shop"})single(m,p);
        for(const char *p:{"txt_stat_name","stat_num_","stats_bar_"})for(int i=1;i<=6;++i)single(m,(std::string(p)+char('0'+i)).c_str());
        m.groups.push_back({{Node{}}}); // stats panel frame: unnamed, bound in AS6OriginalUIApply
    } else if(find(vm,s,m.handler,"hud.mc_touchToSkip.btn_skip")) {
        m.kind=Kind::RaceHud;
        for(const char *p:{"hud.mc_touchToSkip.btn_skip","menu_Tutorial.btn_next"})single(m,p);
    }
    return m.kind==Kind::Loading||m.kind==Kind::CareerSelection||m.kind==Kind::Menu||m.kind==Kind::PauseMenu||m.kind==Kind::RaceHud||m.kind==Kind::Multiplayer||m.kind==Kind::Paint||m.kind==Kind::Tuning;
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
                          double physicalDX,const char *label,bool &readyLogged,double uniformScale=1,
                          double xScale=1,double physicalDY=0) {
    if(!std::isfinite(uniformScale)||uniformScale<=0||uniformScale>1)return false;
    if(!std::isfinite(xScale)||xScale<=0||xScale>1)return false;
    std::array<float,6>current{},world{};std::uint32_t pointer=0;
    if(!local(vm,n,current)||!call(vm,WorldMatrix,{n.object},&pointer)||!read(vm,pointer,world.data(),24))return false;
    M invLocal,invParent;if(!inverse(matrix(current.data()),invLocal))return false;
    const auto parent=multiply(matrix(world.data()),invLocal);if(!inverse(parent,invParent))return false;
    const double hostDX=physicalDX/host.windowScreenScale;
    const P origin{host.windowBoundsPoints[0]+host.windowBoundsPoints[2]*.5,host.windowBoundsPoints[1]+host.windowBoundsPoints[3]*.5};P a,b;
    const double hostDY=physicalDY/host.windowScreenScale;
    if(!mapping.hostToStage.project(origin,a)||!mapping.hostToStage.project({origin.x+hostDX,origin.y+hostDY},b))return false;
    const P stageDelta{b.x-a.x,b.y-a.y},delta=vector(invParent,stageDelta);
    const auto base=canonicalLocal(n,current);auto next=base;
    // Keep each authored origin. Only the three selection summary branches
    // reduce their text/icon axes; Back and arrows retain exact linear floats.
    if(uniformScale!=1)for(unsigned i:{0u,1u,3u,4u})next[i]=float(double(base[i])*uniformScale);
    // Horizontal-only scale (a, b produce x) undoes the canvas stretch.
    if(xScale!=1)for(unsigned i:{0u,1u})next[i]=float(double(next[i])*xScale);
    next[2]+=float(delta.x);next[5]+=float(delta.y);
    if(!std::isfinite(next[2])||!std::isfinite(next[5]))return false;
    const bool same=current[0]==next[0]&&current[1]==next[1]&&current[3]==next[3]&&current[4]==next[4]&&
        std::abs(double(current[2])-next[2])<.001&&std::abs(double(current[5])-next[5])<.001;
    if(!same&&!set(vm,s,n,next))return false;
    n.base=base;n.applied=same?current:next;n.shifted=n.applied!=n.base;n.affineApplied=n.shifted;n.installedAffine={uniformScale*xScale,0,(1-uniformScale*xScale)*base[2]+delta.x,0,uniformScale,(1-uniformScale)*base[5]+delta.y};
    if(!readyLogged){readyLogged=true;char line[640];std::snprintf(line,sizeof(line),
        "[original-ui-%s] path=%s handler=%#x requested_physical_px=(%.0f,0) window_screen_scale=%.6f Host_delta=(%.6f,0) stage_delta=(%.6f,%.6f) local_delta=(%.6f,%.6f) uniform_scale=%.6f linear_floats_unchanged=%d",
        label,n.path.c_str(),m.handler,physicalDX,host.windowScreenScale,hostDX,stageDelta.x,stageDelta.y,delta.x,delta.y,uniformScale,uniformScale==1);GuestRawLog(line);GuestTrace(vm,@"%s",line);}
    return !GuestHasStopRequest(vm);
}
// Unnamed art is reached through its parent's display list, which is depth
// ordered: the list holding the named neighbours `first` and `second` as
// consecutive entries gives the entry spacing, and the wanted child lies
// `offset` entries from `first`.
std::uint32_t displayListEntry(GuestVM *vm,State &s,Movie &m,const char *parentPath,const char *firstPath,
                               const char *secondPath,int offset) {
    // An empty parent path is the movie's root.
    const auto parent=*parentPath?find(vm,s,m.handler,parentPath):m.root,first=find(vm,s,m.handler,firstPath),
        second=find(vm,s,m.handler,secondPath);
    if(!parent||!first||!second)return 0;
    std::uint32_t words[128]{};if(!read(vm,parent,words,sizeof(words)))return 0;
    for(std::uint32_t list:words){
        if(list<0x1000||list&3)continue;
        std::uint32_t entries[128]{};if(!read(vm,list,entries,sizeof(entries)))continue;
        for(int i=0;i<128;++i)if(entries[i]==first)for(int j=i+1;j<128&&j<=i+8;++j)if(entries[j]==second){
            const int at=i+offset*(j-i);if(at<0||at>=128)break;
            const std::uint32_t child=entries[at];std::uint32_t vt=0,matrixAt=0;float m6[6]{};
            if(child&&word(vm,child,vt)&&vt&&word(vm,child+0x4c,matrixAt)&&read(vm,matrixAt,m6,24))return child;
            break;
        }
    }
    return 0;
}
// Binds an unnamed node (empty path) to `object` once it is found.
void bindUnnamed(GuestVM *vm,Node &n,std::uint32_t object) {
    if(n.object||!object)return;
    n=Node{};n.object=object;
    if(!word(vm,object,n.vtable)||!word(vm,object+0x44,n.name))n.object=0;
}
bool applyNodeStageAffine(GuestVM *vm,State &s,Movie &m,Node &n,const M &stageAffine,unsigned &applied,unsigned &changed,
                          double sx=0,double sy=0,double dx=0,double dy=0);
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
    const double round=roundButtonXScale();
    if(!applyMenuTranslation(vm,s,m,n,host,mapping,20.,"back",m.backReadyLogged,RoundButtonScale,round))return false;
    for(auto &button:m.roundButtons){
        if(!resolve(vm,s,m,button.node)){if(!restore(vm,s,button.node))return false;continue;}
        if(!applyMenuTranslation(vm,s,m,button.node,host,mapping,0.,"round-button",button.readyLogged,button.uniformScale,round))return false;
    }
    // Car selection: the stats panel back to its authored 3:2 shape, about the
    // stage centre; its full-width backdrop and bottom bar keep their width. The
    // backdrop is unnamed: depth 1, six entries before tf4 (then tf3).
    float stage[4]{};
    if(!read(vm,m.definition+0xb4,stage,sizeof(stage)))return false;
    const double cx=(double(stage[0])+stage[1])*.5;unsigned applied=0,changed=0;
    if(std::isfinite(cx)&&(!applyNodeStageAffine(vm,s,m,m.carInfo,M{round,0,(1-round)*cx,0,1,0},applied,changed)||
       !applyNodeStageAffine(vm,s,m,m.carInfoBar,M{1/round,0,(1-1/round)*cx,0,1,0},applied,changed)))return false;
    if(!m.carInfoBackdrop.object)bindUnnamed(vm,m.carInfoBackdrop,
        displayListEntry(vm,s,m,"mega_mc.car_info_stuff","mega_mc.car_info_stuff.tf4","mega_mc.car_info_stuff.tf3",-6));
    if(std::isfinite(cx)&&!applyNodeStageAffine(vm,s,m,m.carInfoBackdrop,M{1/round,0,(1-1/round)*cx,0,1,0},applied,changed))return false;
    for(auto &control:m.menuControls){
        if(!resolve(vm,s,m,control.node)){if(!restore(vm,s,control.node))return false;continue;}
        if(!applyMenuTranslation(vm,s,m,control.node,host,mapping,control.physicalDX,"selection-control",control.readyLogged,control.uniformScale,control.unstretch?round:1,control.physicalDY))return false;
    }
    const double width=double(stage[1])-stage[0],height=double(stage[3])-stage[2];
    if(m.menuControls.size()>=3&&width>0&&height>0){
        const M unit{1/width,0,-stage[0]/width,0,1/height,-stage[2]/height};
        bool valid=true;
        for(size_t i=0;i<3&&valid;++i){
            std::array<float,6> world{};std::uint32_t pointer=0;
            valid=m.menuControls[i].node.object&&call(vm,WorldMatrix,{m.menuControls[i].node.object},&pointer)&&read(vm,pointer,world.data(),24);
            if(valid)s.summary[i]=multiply(unit,matrix(world.data()));
        }
        if(valid)s.summaryValid=true;
    }
    return !GuestHasStopRequest(vm);
}
// Applies an affine given in movie stage coordinates to a node. A translation
// the movie's own script writes later is kept: the known prefix is stripped
// before the affine is applied again.
// With sx/sy instead, each node is scaled about its own stage origin, then
// moved by (dx, dy) on the stage.
bool applyNodeStageAffine(GuestVM *vm,State &s,Movie &m,Node &n,const M &stageAffine,unsigned &applied,unsigned &changed,
                          double sx,double sy,double dx,double dy) {
    {
        if(!resolve(vm,s,m,n))return true;
        std::array<float,6>current{},world{};std::uint32_t pointer=0;
        if(!local(vm,n,current)||!call(vm,WorldMatrix,{n.object},&pointer)||!read(vm,pointer,world.data(),24))return false;
        M inv;if(!inverse(matrix(current.data()),inv))return false;
        const auto parent=multiply(matrix(world.data()),inv);
        const auto base=canonicalLocal(n,current);
        M affine=stageAffine;
        if(sx>0&&sy>0){const P o=apply(parent,{double(base[2]),double(base[5])});affine={sx,0,(1-sx)*o.x+dx,0,sy,(1-sy)*o.y+dy};}
        M desired,prefix;if(!affineLocalInStage(matrix(base.data()),parent,affine,desired,prefix))return false;
        const std::array<float,6>next={float(desired.a),float(desired.b),float(desired.tx),float(desired.c),float(desired.d),float(desired.ty)};
        for(float f:next)if(!std::isfinite(f))return false;
        bool same=true;for(unsigned i=0;i<6;++i)if(std::abs(double(next[i])-current[i])>(i==2||i==5?.001:1e-7))same=false;
        if(!same){if(!set(vm,s,n,next))return false;++changed;}
        n.base=base;n.applied=same?current:next;n.shifted=n.applied!=n.base;n.affineApplied=n.shifted;n.installedAffine=prefix;++applied;
    }
    return true;
}
// The same for a range of the movie's groups (first..last).
bool applyStageAffine(GuestVM *vm,State &s,Movie &m,const M &stageAffine,unsigned &applied,unsigned &changed,
                      double sx=0,double sy=0,size_t first=0,size_t last=SIZE_MAX,double dx=0) {
    for(size_t g=first;g<m.groups.size()&&g<last;++g)for(auto &n:m.groups[g].nodes)
        if(!applyNodeStageAffine(vm,s,m,n,stageAffine,applied,changed,sx,sy,dx))return false;
    return true;
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
    if(!applyStageAffine(vm,s,m,stageAffine,applied,changed))return false;
    if(applied&&!m.selectionReadyLogged){m.selectionReadyLogged=true;char line[640];
        std::snprintf(line,sizeof(line),"[foreground-ui] mode=horizontal5 kind=%u handler=%#x groups=%u changed=%u sx=0.900000 sy=1.000000 movie_stage=(%.3f,%.3f,%.3f,%.3f) side_inset_twips=%.3f stage_tx=%.3f stage_ty=0.000 Host=(%.2f,%.2f); background and Back untouched",
            unsigned(m.kind),m.handler,applied,changed,double(stage[0]),double(stage[1]),double(stage[2]),double(stage[3]),.05*width,stageAffine.tx,host.windowBoundsPoints[2],host.windowBoundsPoints[3]);
        GuestRawLog(line);GuestTrace(vm,@"%s",line);
    }
    return !GuestHasStopRequest(vm);
}
// Pause menu: its buttons and those of the options page are drawn at 70% width
// about the stage centre, and the question dialog in its authored 3:2 shape
// (its dimmer still covers the screen); the round Back buttons are scaled
// about their own art (pivotControls).
constexpr double PauseButtonWidth=.7;
constexpr size_t PauseButtonGroups=8;
bool applyPauseButtons(GuestVM *vm,State &s,Movie &m) {
    float stage[4]{};
    if(!read(vm,m.definition+0xb4,stage,sizeof(stage)))return false;
    for(float f:stage)if(!std::isfinite(f))return false;
    const double cx=(double(stage[0])+stage[1])*.5,qx=roundButtonXScale();
    const M buttons{PauseButtonWidth,0,(1-PauseButtonWidth)*cx,0,1,0},question{qx,0,(1-qx)*cx,0,1,0};
    // The dialog frame: unnamed, just before No (dimmer, frame, No, Yes, text).
    auto &frame=m.groups.back().nodes.front();
    if(!frame.object)bindUnnamed(vm,frame,displayListEntry(vm,s,m,"menu_question","menu_question.no_btn","menu_question.btn_exception_name",-1));
    unsigned applied=0,changed=0;
    if(!applyStageAffine(vm,s,m,buttons,applied,changed,0,0,0,PauseButtonGroups)||
       !applyStageAffine(vm,s,m,question,applied,changed,0,0,PauseButtonGroups))return false;
    for(auto &control:m.pivotControls){
        auto &n=control.node;
        if(!resolve(vm,s,m,n))continue;
        std::array<float,6> current{};if(!local(vm,n,current))continue;
        const auto base=canonicalLocal(n,current);
        const M b=matrix(base.data()),k{control.sx,0,(1-control.sx)*control.pivot.x,0,control.sy,(1-control.sy)*control.pivot.y};
        M inv;if(!inverse(b,inv))return false;
        const M desired=multiply(b,k),prefix=multiply(desired,inv);
        const std::array<float,6>next={float(desired.a),float(desired.b),float(desired.tx),float(desired.c),float(desired.d),float(desired.ty)};
        for(float f:next)if(!std::isfinite(f))return false;
        if(next!=current&&!set(vm,s,n,next))return false;
        n.base=base;n.applied=next;n.shifted=next!=base;n.affineApplied=n.shifted;n.installedAffine=prefix;
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
namespace as6_original_ui { namespace {
// The office monitor (career, multiplayer, quick race) is widened to fill the
// screen. The settled camera's view is about 1.2 times the monitor's width in
// the original 3:2 view, and the wide view adds the screen's horizontal
// stretch; 1.22 leaves a little for the screen sitting slightly off centre.
// Only with the complete HD pack (as found by the startup scan), whose
// backgrounds fill the widened pages; without it the monitor and its pages
// stay original.
double officeMonitorWidening() {
    const double stretch=AS6CanvasHorizontalStretch();
    return AS6HDArtworkAvailable()&&std::isfinite(stretch)&&stretch>1.001&&stretch<3?stretch*1.22:1;
}
// The monitor movie renders the definition's stage rectangle into the whole
// bitmap (exact fit). Widening that rectangle makes Flash draw a wider stage
// at its own ratio. Touch conversion (309080) scales by the stage width but
// ignores its left edge, so the stage keeps its left edge and the root clip
// moves right by the added half width instead.
// Whether this movie renders onto the office monitor screen: SWFManager's
// controller for the handler, its plane node cache slot (as in map3D), and
// the screen node recorded when the room was loaded.
bool onOfficeMonitor(GuestVM *vm,State &s,Movie &m) {
    if(m.onMonitor>=0)return m.onMonitor==1;
    if(!s.monitorScreen)return false;
    if(!m.manager&&(!call(vm,GetSWFManager,{},&m.manager)||!m.manager))return false;
    for(unsigned i=0;i<6;++i){
        std::uint32_t index=0,handler=0,slot=0,node=0;
        if(!word(vm,m.manager+4+4*i,index)||index>=6||!word(vm,m.manager+0x1c+4*index,handler)||handler!=m.handler)continue;
        if(!word(vm,m.manager+0x34+4*i,slot)||slot>=6||!word(vm,m.manager+0x64+4*slot,node)||!node)return false;
        m.onMonitor=node==s.monitorScreen;return m.onMonitor==1;
    }
    return false;
}
// A definition can outlive one movie (or a new one reuse its address), so the
// stage is widened only while it still has a width other than the recorded
// one, and every movie instance moves its own root once.
bool widenMonitorStage(GuestVM *vm,State &s,Movie &m) {
    const double W=officeMonitorWidening();
    // Clips waiting right of the stage, where the widened stage would show
    // them: the store's purchase confirmation (career; the store is disabled)
    // and the game update prompt (multiplayer).
    for(auto &node:m.offstage)if(W>1&&resolve(vm,s,m,node)) {
        std::uint8_t visible=0;
        if(!read(vm,node.object+0x9bu,&visible,1))return false;
        const std::uint8_t hidden=0;
        if(visible&&!GuestWrite(vm,node.object+0x9bu,&hidden,1))return false;
    }
    // Each page's full-stage backdrop (unnamed, depth 1) is widened about the
    // authored stage centre, expressed in its parent clip, by the screen's
    // stretch: that covers the visible part of the stage, and the background
    // art (HD pack) is already baked squeezed to the screen's ratio.
    const double stretch=AS6CanvasHorizontalStretch(),B=std::isfinite(stretch)&&stretch>1.001&&stretch<3?stretch:1;
    struct Backdrop { const char *parent,*first,*second;int offset; };
    static const Backdrop backdrops[4]={
        {"_root","CupList","selection_focus",-3},                                       // career
        {"menu_track_select","menu_track_select.CupList","menu_track_select.my_focus",-1}, // quick race tracks
        {"menu_race_type","menu_race_type.btn_collector","menu_race_type.btn_last_man_standing",-1}, // race types
        {"_root","multiplayer_menu_stack","menu_21",-1}};                               // multiplayer
    for(unsigned i=0;W>1&&m.stageWidened&&i<4;++i) {
        auto &node=m.monitorBackdrops[i];
        if(node.object||m.backdropTries[i]>=300)continue;
        ++m.backdropTries[i];
        const auto &b=backdrops[i];
        bindUnnamed(vm,node,displayListEntry(vm,s,m,b.parent,b.first,b.second,b.offset));
        std::array<float,6> backdrop{};float stage[2]{},parent[6]{1,0,0,0,1,0};std::uint32_t parentMatrix=0;
        const std::uint32_t parentClip=std::strcmp(b.parent,"_root")?find(vm,s,m.handler,b.parent):0;
        if(!node.object||!local(vm,node,backdrop)||!read(vm,m.definition+0xb4,stage,8)||
           (parentClip&&(!word(vm,parentClip+0x4c,parentMatrix)||!read(vm,parentMatrix,parent,24)||parent[0]==0))){node.object=0;continue;}
        const double centre=(stage[0]+.5*(double(stage[1])-stage[0])/W-parent[2])/parent[0];
        backdrop[0]=float(backdrop[0]*B);backdrop[2]=float(centre+(backdrop[2]-centre)*B);
        if(!set(vm,s,node,backdrop))return false;
        char line[200];std::snprintf(line,sizeof(line),"[office-monitor] backdrop %s=%#x centre=%.1f sx=%.4f tx=%.1f",b.parent,node.object,centre,backdrop[0],backdrop[2]);GuestRawLog(line);
    }
    if(m.stageWidened)return true;
    float stage[4]{},local[6]{};std::uint32_t matrixPointer=0;
    if(!read(vm,m.definition+0xb4,stage,sizeof(stage)))return false;
    for(float f:stage)if(!std::isfinite(f))return true;
    const std::uint32_t root=find(vm,s,m.handler,"_root");
    if(W<=1||stage[1]<=stage[0]||!root||!word(vm,root+0x4c,matrixPointer)||!read(vm,matrixPointer,local,24))return true;
    const auto known=s.widenedStages.find(m.definition);
    const bool already=known!=s.widenedStages.end()&&known->second==stage[1];
    const double width=already?(double(stage[1])-stage[0])/W:double(stage[1])-stage[0];
    const float wide[2]={stage[0],float(stage[0]+width*W)};
    if(!already&&!GuestWrite(vm,m.definition+0xb4,wide,sizeof(wide)))return false;
    s.widenedStages[m.definition]=wide[1];m.stageWidened=true;
    local[2]=float(local[2]+.5*width*(W-1));
    if(!writeScratch(vm,s,512,local,24)||!call(vm,SetMatrix,{root,s.scratch+512}))return false;
    char line[256];std::snprintf(line,sizeof(line),"[office-monitor] stage definition=%#x x=(%.1f %.1f) -> (%.1f %.1f)%s root=%#x tx=%.1f",
        m.definition,stage[0],stage[1],wide[0],wide[1],already?" (already)":"",root,local[2]);GuestRawLog(line);
    return !GuestHasStopRequest(vm);
}
}}
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
    if(!s.scratch)s.scratch=GuestAlloc(vm,4096);if(!s.scratch)return false;
    if(onOfficeMonitor(vm,s,*m)&&!widenMonitorStage(vm,s,*m))return false;
    if(!identify(vm,s,*m))return !GuestHasStopRequest(vm);
    float scale=0;std::uint32_t driver=0;
    scaleAndDriver(vm,scale,driver); // Diagnostic only: layout uses native ratios and authored stage.
    if(!m->identifiedLog){m->identifiedLog=true;GuestTrace(vm,@"[original-ui] identified kind=%u handler=%#x root=%#x definition=%#x Host=(%.1f %.1f) safe=(%.4f %.4f %.4f %.4f) view=(%.1f %.1f) scale=%.2f driver=%#x revision=%llu",
        unsigned(m->kind),handler,m->root,m->definition,h.windowBoundsPoints[2],h.windowBoundsPoints[3],h.safeNormalizedRect[0],h.safeNormalizedRect[1],h.safeNormalizedRect[2],h.safeNormalizedRect[3],h.originalViewBoundsPoints[2],h.originalViewBoundsPoints[3],double(scale),driver,(unsigned long long)h.revision);}
    if(m->kind==Kind::Menu){discoverSelectionControls(vm,s,*m);discoverRoundButtons(vm,s,*m);return applyBack20(vm,s,*m,h,metricsReady);}
    if(m->kind==Kind::PauseMenu)return applyPauseButtons(vm,s,*m);
    if(m->kind==Kind::Multiplayer){
        // Back buttons sit over the page titles: move them left by 6.5% of the stage.
        float stage[4]{};
        if(!read(vm,m->definition+0xb4,stage,sizeof(stage)))return false;
        for(float f:stage)if(!std::isfinite(f))return false;
        // A widened stage keeps its left edge; the shift is of the authored width.
        const double width=(double(stage[1])-stage[0])/(m->stageWidened?officeMonitorWidening():1);
        unsigned applied=0,changed=0;
        return applyStageAffine(vm,s,*m,M{1,0,-.065*width,0,1,0},applied,changed)&&!GuestHasStopRequest(vm);
    }
    if(m->kind==Kind::Paint||m->kind==Kind::Tuning){
        float stage[4]{};
        if(!read(vm,m->definition+0xb4,stage,sizeof(stage)))return false;
        for(float f:stage)if(!std::isfinite(f))return false;
        const double cx=(double(stage[0])+stage[1])*.5,round=roundButtonXScale();
        unsigned applied=0,changed=0;
        if(m->kind==Kind::Paint)
            return applyStageAffine(vm,s,*m,M{},applied,changed,RoundButtonScale*round,RoundButtonScale,0,4)&&
                applyStageAffine(vm,s,*m,M{round,0,(1-round)*cx,0,1,0},applied,changed,0,0,4)&&!GuestHasStopRequest(vm);
        const double width=double(stage[1])-stage[0],height=double(stage[3])-stage[2];
        if(m->groups.size()!=27||!(width>0)||!(height>0))return restoreMovie(vm,s,*m);
        // Tabs and parts grid back to their authored shape about their own
        // origin; the stats panel (frame, names, values, bars) about its centre
        // (stage x 931.5 of 1024). Full-width backgrounds keep their width.
        for(size_t g=3;g<8;++g)
            if(!applyNodeStageAffine(vm,s,*m,m->groups[g].nodes.front(),M{},applied,changed,round,1))return false;
        auto &frame=m->groups.back().nodes.front();
        if(!frame.object)bindUnnamed(vm,frame,displayListEntry(vm,s,*m,"","menu_tunning_shop","menu_sponsor",-2));
        const double panel=stage[0]+width*931.5/1024;
        if(!applyStageAffine(vm,s,*m,M{round,0,(1-round)*panel,0,1,0},applied,changed,0,0,8))return false;
        // The career summary takes exactly the car selection's placement (both
        // movies fill the screen), so it does not move between the two pages.
        if(!s.summaryValid){for(size_t g=0;g<3;++g)for(auto &n:m->groups[g].nodes)if(!restore(vm,s,n))return false;return !GuestHasStopRequest(vm);}
        const M fromUnit{width,0,stage[0],0,height,stage[2]};
        const size_t source[3]={2,1,0}; // stars, total, cash <- car selection's cash, total, stars
        for(size_t i=0;i<3;++i)for(auto &n:m->groups[i].nodes){
            if(!resolve(vm,s,*m,n))continue;
            std::array<float,6> current{},world{};std::uint32_t pointer=0;
            if(!local(vm,n,current)||!call(vm,WorldMatrix,{n.object},&pointer)||!read(vm,pointer,world.data(),24))return false;
            M invCurrent,invParent,invBase;if(!inverse(matrix(current.data()),invCurrent))return false;
            const auto parent=multiply(matrix(world.data()),invCurrent);if(!inverse(parent,invParent))return false;
            const auto base=canonicalLocal(n,current);if(!inverse(matrix(base.data()),invBase))return false;
            const M desired=multiply(invParent,multiply(fromUnit,s.summary[source[i]]));
            const std::array<float,6> next={float(desired.a),float(desired.b),float(desired.tx),float(desired.c),float(desired.d),float(desired.ty)};
            for(float f:next)if(!std::isfinite(f))return false;
            if(next!=current&&!set(vm,s,n,next))return false;
            n.base=base;n.applied=next;n.shifted=next!=base;n.affineApplied=n.shifted;n.installedAffine=multiply(desired,invBase);
        }
        return !GuestHasStopRequest(vm);
    }
    if(m->kind==Kind::RaceHud){
        // Skip / next: round again on the stretched canvas, then 80%.
        unsigned applied=0,changed=0;
        return applyStageAffine(vm,s,*m,M{},applied,changed,RoundButtonScale*roundButtonXScale(),RoundButtonScale)&&!GuestHasStopRequest(vm);
    }
    if(m->kind==Kind::Loading)return applyResourceForeground(vm,s,*m,h);
    // Career selection sits on the in-room 3:2 monitor: authored layout.
    if(m->kind==Kind::CareerSelection)return applyCareerStars(vm,s,*m,h,metricsReady);
    return restoreMovie(vm,s,*m);

}
namespace as6_original_ui { namespace {
// Batching reads each node's absolute matrix (+0x10, axes then translation),
// already computed at load, so the subtree's absolute matrices are widened
// too: x and z of every axis by W, and the translation about the centre.
bool widenAbsolute(GuestVM *vm,std::uint32_t node,double W,const double *centre,int depth) {
    float a[16]{};
    if(!read(vm,node+0x10,a,64))return false;
    for(int axis=0;axis<3;++axis){a[axis*4]=float(a[axis*4]*W);a[axis*4+2]=float(a[axis*4+2]*W);}
    a[12]=float(centre[0]+(a[12]-centre[0])*W);a[14]=float(centre[2]+(a[14]-centre[2])*W);
    if(!GuestWrite(vm,node+0x10,a,64))return false;
    const std::uint32_t head=node+0xe0;std::uint32_t link=0;unsigned count=0;
    if(depth>4||!word(vm,head,link))return true;
    while(link&&link!=head&&count++<64){
        if(!widenAbsolute(vm,link-4,W,centre,depth+1))return false;
        if(!word(vm,link,link))break;
    }
    return true;
}
}}
// The menu room as loaded, before MenuScene batches every child without
// "_node" in its name into static geometry: the office monitor's screen,
// bezel (Object113) and housing (Object114) are still separate nodes here.
// Scale them together by W horizontally about the screen centre. The screen
// has no rotation (its quad is authored turned 30 degrees), so its scale is
// (W,1,W); the bezel and housing map local z to world -Y, so theirs gain W
// on x and y. Either way the monitor widens along its own horizontal axis.
extern "C" bool AS6OriginalUIMenuSceneLoaded(GuestVM *vm,std::uint32_t root) {
    using namespace as6_original_ui;
    std::lock_guard<std::recursive_mutex>guard(statesMutex);auto &s=states[vm];
    const double W=officeMonitorWidening();
    if(W<=1||!root)return true;
    struct Part { const char *name;std::array<double,3> gain; };
    static const Part parts[]={{"MenuOfficeDesk_Screen_node",{W,1,W}},{"Object113",{W,W,1}},{"Object114",{W,W,1}}};
    const double centre[3]={-608.896,119.565,1036.58};
    const std::uint32_t head=root+0xe0;std::uint32_t link=0;unsigned count=0,widened=0;
    if(!word(vm,head,link))return true;
    while(link&&link!=head&&count++<1000){
        const std::uint32_t node=link-4;
        if(!word(vm,link,link))break;
        std::uint32_t vt=0,getName=0,namePointer=0,setScale=0,setPosition=0;char name[32]{};
        if(!word(vm,node,vt)||!word(vm,vt+0x24,getName)||!call(vm,getName,{node},&namePointer)||!namePointer||!read(vm,namePointer,name,sizeof(name)-1))continue;
        const Part *part=nullptr;for(const auto &p:parts)if(!std::strcmp(name,p.name))part=&p;
        if(part==parts)s.monitorScreen=node;
        float position[3]{},scale[3]{};
        if(!part||!word(vm,vt+0x94,setScale)||!word(vm,vt+0xa4,setPosition)||!read(vm,node+0x98,position,12)||!read(vm,node+0xb4,scale,12))continue;
        const float before[3]={position[0],position[2],scale[0]};
        if(!widenAbsolute(vm,node,W,centre,0))return false;
        for(int i=0;i<3;++i)scale[i]=float(scale[i]*part->gain[i]);
        position[0]=float(centre[0]+(position[0]-centre[0])*W);position[2]=float(centre[2]+(position[2]-centre[2])*W);
        if(!writeScratch(vm,s,840,scale,12)||!writeScratch(vm,s,860,position,12)||
           !call(vm,setScale,{node,s.scratch+840})||!call(vm,setPosition,{node,s.scratch+860}))return false;
        ++widened;char line[256];std::snprintf(line,sizeof(line),"[office-monitor] %s x=%.2f z=%.2f sx=%.4f -> pos=(%.2f %.2f %.2f) scale=(%.4f %.4f %.4f)",
            name,before[0],before[1],before[2],position[0],position[1],position[2],scale[0],scale[1],scale[2]);GuestRawLog(line);
    }
    char line[128];std::snprintf(line,sizeof(line),"[office-monitor] room=%#x children=%u widened=%u W=%.4f",root,count,widened,W);GuestRawLog(line);
    return !GuestHasStopRequest(vm);
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
