// The real OpenGL ES backend.
//
// The original 2011 renderer talks to a 32-bit ARM OpenGL ES driver.  The
// arm64 iOS simulator still ships one -- EAGLContext hands out real GLES 1.1,
// 2.0 and 3.0 contexts -- so instead of answering the guest with fakes this
// file marshals each AAPCS-VFP argument out of the emulated registers and calls
// the driver's own entry point.  Guest pointers are the only thing that cannot
// travel unchanged: they index emulated memory, so they are copied into a host
// arena first and, for out-parameters, copied back byte-for-byte afterwards.

#import "GLReal.h"

#import "GuestObjC.h"
#import "GuestVM.h"
#import "HLE.h"

#import <dlfcn.h>
#import <cstdlib>
#import <mutex>
#import <sys/mman.h>
#import <string.h>
#import <unordered_map>
#import <vector>
#import <algorithm>
#import <errno.h>
#include <exception>
#include "GLCallPlan.hpp"
#include "RenderIndexMaximum.hpp"
#include "RenderIndexRangeCache.hpp"
#include "RenderWorkTelemetry.hpp"
using GLCall=as6_render_plan::Call;
extern "C" NSDictionary *AS6GLRenderWorkDiagnostics(void) {
    const auto s=as6_render_plan::renderWorkTelemetry.snapshot();
    return @{@"index_scans":@(s.scans),@"index_scan_bytes":@(s.bytes),
        @"parallel_index_scans":@(s.parallel),@"completed_background_tasks":@(s.workerTasks),
        @"maximum_index_scan_bytes":@(s.maximumBytes),@"maximum_background_workers":@(s.maximumWorkers),
        @"large_index_scan_wall_ns":@(s.largeWallNs),
        @"index_cache_lookups":@(s.cacheLookups),@"index_cache_hits":@(s.cacheHits),
        @"index_cache_saved_scan_bytes":@(s.cacheSavedBytes)};
}

// --- GL constants (kept local: the ES1 and ES2 SDK headers conflict) --------
enum {
    GL_FALSE = 0, GL_TRUE = 1,
    GL_BYTE = 0x1400, GL_UNSIGNED_BYTE = 0x1401, GL_SHORT = 0x1402,
    GL_UNSIGNED_SHORT = 0x1403, GL_INT = 0x1404, GL_UNSIGNED_INT = 0x1405,
    GL_FLOAT = 0x1406, GL_HALF_FLOAT_OES = 0x8D61,
    GL_UNSIGNED_SHORT_5_6_5 = 0x8363, GL_UNSIGNED_SHORT_4_4_4_4 = 0x8033,
    GL_UNSIGNED_SHORT_5_5_5_1 = 0x8035,
    GL_ALPHA = 0x1906, GL_RGB = 0x1907, GL_RGBA = 0x1908, GL_LUMINANCE = 0x1909,
    GL_LUMINANCE_ALPHA = 0x190A, GL_INTENSITY = 0x8049,
    GL_DEPTH_COMPONENT = 0x1902, GL_DEPTH_COMPONENT16 = 0x81A5,
    GL_ARRAY_BUFFER = 0x8892, GL_ELEMENT_ARRAY_BUFFER = 0x8893,
    GL_VERTEX_ARRAY = 0x8074, GL_NORMAL_ARRAY = 0x8075, GL_COLOR_ARRAY = 0x8076,
    GL_TEXTURE_COORD_ARRAY = 0x8078,
    GL_TEXTURE0 = 0x84C0, GL_PACK_ALIGNMENT = 0x0D05, GL_UNPACK_ALIGNMENT = 0x0CF5,
    GL_VENDOR = 0x1F00, GL_RENDERER = 0x1F01, GL_VERSION = 0x1F02,
};

// --- driver handles ---------------------------------------------------------
static void *g_glLib;
static std::unordered_map<std::string, void *> g_symCache;

static void *GLSym(const char *plain) {
    if (!plain) return NULL;
    auto it = g_symCache.find(plain);
    if (it != g_symCache.end()) return it->second;
    if (!g_glLib)
        g_glLib = dlopen("System/Library/Frameworks/OpenGLES.framework/OpenGLES",
                         RTLD_NOW | RTLD_GLOBAL);
    void *p = g_glLib ? dlsym(g_glLib, plain) : NULL;
    if (!p) {
        char under[160];
        snprintf(under, sizeof(under), "_%s", plain);
        p = dlsym(RTLD_DEFAULT, under);
    }
    g_symCache[plain] = p;
    return p;
}

// Symbol identity is immutable for this process. The serial gate protects this table.
struct GLPreparedDriver { void *function=nullptr;bool resolved=false;std::uint64_t hits=0; };
static GLPreparedDriver g_preparedDrivers[as6_render_plan::Count];
static void *GLPreparedSymbol(GLCall call) {
    const auto *plan=as6_render_plan::get(call);if(!plan)return nullptr;
    auto &entry=g_preparedDrivers[unsigned(call)];
    if(!entry.resolved){entry.function=GLSym(plan->name);entry.resolved=true;}
    return entry.function;
}

static BOOL g_glTraceAll = NO;
static BOOL g_glSizeTrace = NO;

// --- current dispatch state -------------------------------------------------
static GuestVM *g_vm;
static uint32_t g_ret;
static BOOL g_haveRet;

// A GL call keeps its staged pointers and all bridge trackers exclusive even
// while the native driver is running without the VM. A competing GL caller
// must release its VM before waiting for this gate, avoiding VM/gate inversion.
extern "C" BOOL GuestDiagnosticSnapshotLockHeld(GuestVM *);
static std::recursive_mutex g_glSerialGate;
static thread_local unsigned g_glSerialDepth;

BOOL GLRealBeginSerialCall(GuestVM *vm) {
    const int savedErrno=errno;
    if(!vm||!GuestDiagnosticSnapshotLockHeld(vm)||GuestHasStopRequest(vm)) {
        if(vm)GuestRequestFault(vm);errno=savedErrno;return NO;
    }
    bool acquired=false;
    try {acquired=g_glSerialGate.try_lock();} catch(...) {}
    if(!acquired) {
        struct Wait { bool acquired=false; } wait;
        const int blockingResult=HLEPthreadBlockingCall(vm,[](void *raw)->int {
            auto &wait=*static_cast<Wait *>(raw);
            try {g_glSerialGate.lock();wait.acquired=true;return 0;}
            catch(...) {return -1;}
        },&wait);
        // The wait may acquire the host gate before End rejects a stopped VM
        // or failed CPU restoration. Release that host acquisition before
        // rejecting this serial call; it must not escape as a successful gate.
        if(blockingResult<0&&wait.acquired){g_glSerialGate.unlock();wait.acquired=false;}
        acquired=blockingResult>=0&&wait.acquired;
    }
    if(acquired)++g_glSerialDepth;
    else GuestRequestFault(vm);
    errno=savedErrno;return acquired;
}
void GLRealEndSerialCall(GuestVM *vm) {
    const int savedErrno=errno;
    if(g_glSerialDepth){--g_glSerialDepth;g_glSerialGate.unlock();}
    else if(vm)GuestRequestFault(vm);
    errno=savedErrno;
}
struct GLRealSerialScope {
    GuestVM *__unsafe_unretained vm;
    bool acquired;
    explicit GLRealSerialScope(GuestVM *owner):vm(owner),acquired(GLRealBeginSerialCall(owner)){}
    ~GLRealSerialScope(){if(acquired)GLRealEndSerialCall(vm);}
};
void GLRealHostOperation(void (*operation)(void *),void *context) {
    if(!operation||!g_glSerialDepth)return;
    if(!g_vm||!GuestDiagnosticSnapshotLockHeld(g_vm)) {
        if(g_vm)GuestRequestFault(g_vm);return;
    }
    struct Work {
        void (*operation)(void *);
        void *context;
        std::exception_ptr cpp;
        NSException *__strong objc=nil;
    } work{operation,context,{}};
    const int blockingResult=HLEPthreadBlockingCall(g_vm,[](void *raw)->int {
        auto &work=*static_cast<Work *>(raw);
        // BlockingCall must always regain the VM before an exception escapes.
        try {
            @try {work.operation(work.context);}
            @catch(NSException *exception) {work.objc=exception;}
        } catch(...) {work.cpp=std::current_exception();}
        return 0;
    },&work);
    if(work.objc)@throw work.objc;
    if(work.cpp)std::rethrow_exception(work.cpp);
    if(blockingResult<0)GuestRequestFault(g_vm);
}

static void GLTraceInitOnce(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    const char *e = getenv("AS6_GLTRACE");
    g_glTraceAll = (e && e[0] && e[0] != '0');
    const char *timing = getenv("AS6_PASSIVE_TIMING");
    g_glSizeTrace = timing && !strcmp(timing, "1");
}

void GLSetRetU32(uint32_t v) { if(g_glSerialDepth){g_ret = v; g_haveRet = YES;} }
void GLSetRetPtr(void *p) { (void)p; if(g_glSerialDepth){g_ret = 0; g_haveRet = YES;} }

// --- host scratch for guest pointers ----------------------------------------
static uint8_t *g_arena;
static size_t g_arenaSize, g_arenaOff;
static std::vector<void *> g_extraScratch;

struct Back { uint32_t gva; uint8_t *host; size_t len; };
static std::vector<Back> g_backs;

static void ArenaInit(void) {
    static std::once_flag once;
    std::call_once(once, [] {
        g_arenaSize = 48u << 20;
        g_arena = (uint8_t *)mmap(NULL, g_arenaSize, PROT_READ | PROT_WRITE,
                                  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (g_arena == MAP_FAILED) { g_arena = NULL; g_arenaSize = 0; }
    });
}

static uint8_t *Arena(size_t n) {
    ArenaInit();
    if (n == 0 || n > SIZE_MAX - 15u) return NULL;
    n = (n + 15u) & ~(size_t)15u;
    // A staged pointer must stay valid until this entire GL call finishes.
    // Oversized copies get their full allocation, never a truncated buffer or
    // a wraparound that overwrites an earlier pointer in the same draw.
    if (!g_arena || n > g_arenaSize - g_arenaOff) {
        void *p = malloc(n);
        if (p) g_extraScratch.push_back(p);
        return (uint8_t *)p;
    }
    uint8_t *p = g_arena + g_arenaOff;
    g_arenaOff += n;
    return p;
}

static void ArenaReset(void) {
    for (void *p : g_extraScratch) free(p);
    g_extraScratch.clear();
    g_arenaOff = 0;
}


// Observe only bytes/results already marshalled by the original GL call.
// No extra driver query, guest memory access or rendering state change.
struct GLObservationErrnoScope { int saved=errno; ~GLObservationErrnoScope(){errno=saved;} };
static void ObserveGLCopyFailure(uint32_t gva,size_t requested,size_t copied,const char *reason) {
    const GLObservationErrnoScope saved;
    static unsigned lines=0;if(lines>=32)return;++lines;
    char line[256];snprintf(line,sizeof(line),"[gl-observe-copy] symbol=%s gva=%#x requested=%llu copied=%llu reason=%s",
        HLECurrentSymbol()?:"",gva,(unsigned long long)requested,(unsigned long long)copied,reason);
    GuestRawLog(line);
}
static void ObserveGLSource(uint32_t shader,uint32_t supplied,uint32_t forwarded,uint32_t lenv,
                            const size_t *lengths,uint32_t staged,uint64_t hash,BOOL complete) {
    const GLObservationErrnoScope saved;
    static unsigned lines=0;if(lines>=256)return;++lines;
    char line[1536];int used=snprintf(line,sizeof(line),
        "[gl-observe-source] shader=%u supplied_count=%u forwarded_count=%u length_mode=%s staged=%u complete=%d fnv1a64=%016llx strlen_forwarded=[",
        shader,supplied,forwarded,lenv?"nonnull-values-unobserved":"null-terminated",staged,complete,(unsigned long long)hash);
    for(uint32_t i=0;i<staged&&i<64&&used>0&&size_t(used)<sizeof(line);++i)
        used+=snprintf(line+used,sizeof(line)-size_t(used),"%s%llu",i?",":"",(unsigned long long)lengths[i]);
    if(used>0&&size_t(used)+2<sizeof(line)){line[used++]=']';line[used]='\0';GuestRawLog(line);}
}
static void ObserveExistingGLResult(const char *name,int count,const uint64_t *I,void *const *P) {
    const GLObservationErrnoScope saved;
    static unsigned statusLines=0,failedStatusLines=0,emptyLogLines=0,nonemptyLogLines=0;
    if((!strcmp(name,"glGetShaderiv")||!strcmp(name,"glGetProgramiv"))&&count==3&&P[2]){
        int32_t value;memcpy(&value,P[2],4);
        const BOOL failed=!value&&(I[1]==0x8b81||I[1]==0x8b82||I[1]==0x8b83);
        unsigned &lines=failed?failedStatusLines:statusLines;
        if(lines>=128)return;++lines;
        char line[256];snprintf(line,sizeof(line),"[gl-observe-status] call=%s object=%u pname=%#x observed=%d",
            name,(uint32_t)I[0],(uint32_t)I[1],value);GuestRawLog(line);
    }else if((!strcmp(name,"glGetShaderInfoLog")||!strcmp(name,"glGetProgramInfoLog"))&&count==4&&P[3]){
        const size_t capacity=std::min<uint64_t>(I[1],2048);size_t length=strnlen((const char *)P[3],capacity);
        int32_t reported=-1;if(P[2])memcpy(&reported,P[2],4);
        if(reported>=0)length=std::min(length,size_t(reported));
        unsigned &lines=length?nonemptyLogLines:emptyLogLines;if(lines>=(length?128u:32u))return;++lines;
        char text[2049];for(size_t i=0;i<length;++i){const unsigned char ch=((const unsigned char *)P[3])[i];text[i]=(ch=='\n'||ch=='\r'||ch=='\t')?' ':char(ch);}text[length]='\0';
        char line[2304];snprintf(line,sizeof(line),"[gl-observe-log] call=%s object=%u max_length=%u reported=%d captured=%llu text=%s",
            name,(uint32_t)I[0],(uint32_t)I[1],reported,(unsigned long long)length,text);GuestRawLog(line);
    }
}
static void ObserveGLString(const char *name,uint32_t pname,uint32_t index,const char *text) {
    const GLObservationErrnoScope saved;
    static unsigned lines=0;if(lines>=16)return;++lines;
    const size_t length=text?strnlen(text,2048):0;
    char copy[2049];for(size_t i=0;i<length;++i){const unsigned char ch=text[i];copy[i]=(ch=='\n'||ch=='\r'||ch=='\t')?' ':char(ch);}copy[length]='\0';
    char line[2304];snprintf(line,sizeof(line),"[gl-observe-string] call=%s pname=%#x index=%u returned_null=%d captured=%llu text=%s",
        name,pname,index,!text,(unsigned long long)length,copy);GuestRawLog(line);
}

// Copy guest memory into the arena.  Out-parameters are registered for a
// byte-exact write-back, so a generous length never clobbers anything the
// driver did not actually touch.
static void *GuestToHost(GuestVM *vm, uint32_t gva, size_t len, BOOL writeBack) {
    if (!gva || !len || (uint64_t)gva + len > (UINT64_C(1) << 32)) return NULL;
    uint8_t *p = Arena(len);
    if (!p) { ObserveGLCopyFailure(gva,len,0,"allocation"); return NULL; }
    BOOL ok = GuestRead(vm, gva, p, len);
    if (!ok) {
        // The tail ran past mapped memory; retry a page at a time so at least
        // the head of the buffer arrives intact.
        size_t got = 0;
        while (got < len) {
            size_t chunk = std::min(len - got, (size_t)(4096 - ((gva + got) & 4095)));
            if (!GuestRead(vm, gva + (uint32_t)got, p + got, chunk)) break;
            got += chunk;
        }
        if (got < len) memset(p + got, 0, len - got);
        ObserveGLCopyFailure(gva,len,got,got<len?"read-truncated-zero-filled":"initial-read-retried");
        ok = got > 0;
    }
    if (writeBack && ok && len) g_backs.push_back({gva, p, len});
    return p;
}

static void FlushBack(GuestVM *vm) {
    for (const Back &b : g_backs) GuestWrite(vm, b.gva, b.host, b.len);
    g_backs.clear();
}

// --- AAPCS-VFP argument cursor ----------------------------------------------
// Core registers and VFP registers are counted independently: r0-r3 then the
// stack for integers, s0-s15 for floats.
// The 2011 build is -mfloat-abi=softfp, so there is one argument stream:
// r0-r3 and then the stack, for integers, pointers, floats and doubles alike.
struct Cursor {
    GuestVM *vm;
    int core, spilled;
    uint32_t NextInt(void) {
        if (core < 4) return GuestReg(vm, 0 + core++);
        uint32_t v = 0;
        GuestRead(vm, GuestSP(vm) + 4 * spilled, &v, 4);
        spilled++;
        return v;
    }
    float NextFloat(void) {
        uint32_t w = NextInt();
        float f;
        memcpy(&f, &w, sizeof(f));
        return f;
    }
};

// --- element sizing ---------------------------------------------------------
static size_t TypeSize(uint32_t type) {
    switch (type) {
        case GL_BYTE: case GL_UNSIGNED_BYTE: return 1;
        case GL_SHORT: case GL_UNSIGNED_SHORT: case GL_HALF_FLOAT_OES:
        case GL_UNSIGNED_SHORT_5_6_5: case GL_UNSIGNED_SHORT_4_4_4_4:
        case GL_UNSIGNED_SHORT_5_5_5_1: return 2;
        case GL_INT: case GL_UNSIGNED_INT: case GL_FLOAT: return 4;
        default: return 1;
    }
}

static size_t Channels(uint32_t format) {
    switch (format) {
        case GL_ALPHA: case GL_LUMINANCE: case GL_DEPTH_COMPONENT: return 1;
        case GL_LUMINANCE_ALPHA: return 2;
        case GL_RGB: return 3;
        case GL_RGBA: case GL_INTENSITY: return 4;
        default: return 4;
    }
}

static uint32_t g_packAlignment = 4, g_unpackAlignment = 4;
static size_t PixelBytes(uint32_t w, uint32_t h, uint32_t format, uint32_t type,
                         uint32_t alignment) {
    if ((int32_t)w <= 0 || (int32_t)h <= 0) return 0;
    BOOL packed = type == GL_UNSIGNED_SHORT_5_6_5 ||
                  type == GL_UNSIGNED_SHORT_4_4_4_4 || type == GL_UNSIGNED_SHORT_5_5_5_1;
    uint64_t row = (uint64_t)w * TypeSize(type) * (packed ? 1 : Channels(format));
    uint64_t stride = (row + alignment - 1) & ~(uint64_t)(alignment - 1);
    uint64_t bytes = stride * (h - 1) + row;
    return bytes <= UINT32_MAX ? (size_t)bytes : 0;
}

// --- tracked state the deferred pointers need -------------------------------
struct Arr { int enabled; uint32_t size, type, stride, ptr, buffer; };
static Arr g_arr[4];       // GLES1 client arrays
static Arr g_texArr[32];
static uint32_t g_clientTexture;
struct VArr { int used, enabled; uint32_t size, type, stride, ptr, buffer, normalized; };
static VArr g_varr[32];    // GLES2 generic attributes fed from client memory
static uint32_t g_bound[3];

typedef void (*Fn_v_ui)(uint32_t);
typedef void (*Fn_v_ui_ui)(uint32_t, uint32_t);

static int ArrSlot(uint32_t e) {
    switch (e) {
        case GL_VERTEX_ARRAY: return 0;
        case GL_NORMAL_ARRAY: return 1;
        case GL_COLOR_ARRAY: return 2;
        case GL_TEXTURE_COORD_ARRAY: return 3;
        default: return -1;
    }
}

static int BoundSlot(uint32_t target) {
    switch (target) {
        case GL_ARRAY_BUFFER: return 1;
        case GL_ELEMENT_ARRAY_BUFFER: return 2;
        default: return 0;
    }
}

struct BufInfo { uint32_t size = 0, guestMap = 0; std::vector<uint8_t> data; as6_render_plan::IndexRangeCache indexMaximum; };
static std::unordered_map<uint32_t, BufInfo> g_bufs;
// Candidate only. Observe forwarded arguments, never query the driver or VM.
// A requested state is not proof that a driver accepted an invalid GL call.
#include <array>
#include <chrono>
#include <sys/stat.h>

struct GLStateKnown { bool known=false; uint32_t value=0; };
struct GLStateTexture {
    bool known=false, compressed=false, bytes_known=false,subimage_seen=false;
    bool legacy_generate_known=false,legacy_generate_is_float=false;uint32_t legacy_generate_bits=0;
    uint32_t target=0,level=0,internal=0,width=0,height=0,format=0,type=0;
    uint64_t base_upload_revision=0,upload_event_sequence=0;
    size_t bytes=0,hashed=0,full_hashed=0; uint64_t hash=0;std::string full_sha,full_missing;
};
struct GLStateUniform {
    uint32_t program=0; int32_t location=0; std::string name;
    std::string call; uint32_t count=0,transpose=0;
    std::vector<uint8_t> bytes;
};
struct GLStateProgram { std::vector<uint32_t> attached; std::vector<uint64_t> linked_hashes; std::unordered_map<uint32_t,std::string> attributes; };
struct GLStateTextureParameter { bool is_float=false; uint32_t bits=0; };
struct GLStateClientSpan {const uint8_t *data=nullptr;size_t bytes=0;uint32_t stride=0;bool driver_pointer_forwarded=false;};
struct GLStatePositiveLevel {
    uint32_t level=0,width=0,height=0,internal=0,format=0,type=0;bool compressed=false,base_known=false;
    uint64_t base_upload_revision=0,event_sequence=0;
};
struct GLStateMipmap {
    uint64_t event_sequence=0,source_base_upload_revision=0;uint32_t target=0,unit=0,texture=0;
    bool source_base_known=false,source_sha256_complete=false,source_subimage_seen=false;std::string call,source_base_sha256;
};
struct GLStateClear {
    uint64_t event_sequence=0,clear_sequence=0;uint32_t mask=0;
    GLStateKnown fbo,depth_mask,scissor;bool rect_known=false,color_mask_known=false,clear_depth_known=false;uint32_t clear_depth_bits=0;
    std::array<uint32_t,4> rect{},color_mask{};
};
struct GLStateObservation {
    bool configured=false,enabled=false,disabled=false,triggered=false;
    unsigned draws=0,matched=0,errors=0,total=0,inspected=0;
    uint64_t render_event_sequence=0,clear_sequence=0,base_upload_revision_serial=0;
    unsigned upload_events=0,mipmap_events=0,clear_events=0,missing_mipmap_symbols=0,parameter_events=0,legacy_parameter_events=0,positive_level_events=0;
    bool clear_depth_known=false;uint32_t clear_depth_bits=0;
    bool scissor_rect_known=false;std::array<uint32_t,4> scissor_rect{};
    std::unordered_map<uint32_t,GLStateMipmap> mipmaps;
    std::unordered_map<uint32_t,std::unordered_map<uint32_t,GLStatePositiveLevel>> positive_levels;
    std::unordered_map<uint32_t,GLStateClear> last_fbo_clear;
    std::string request;
    std::chrono::steady_clock::time_point next_check{};
    GLStateKnown active,program,fbo,blend,depth,cull,scissor,src,dst,equation,depth_func,
        depth_mask,cull_mode,front_face,array_bound,element_bound;
    bool color_mask_known=false,depth_range_known=false,polygon_offset_known=false;
    std::array<uint32_t,4> color_mask{};
    std::array<uint32_t,2> depth_range{},polygon_offset{};
    std::array<bool,32> attrib_enabled_seen{};
    bool viewport_known=false;std::array<uint32_t,4> viewport{};
    std::array<bool,32> constant_known{};std::array<std::array<uint32_t,4>,32> constant_bits{};
    std::array<GLStateClientSpan,32> client_spans{};
    std::array<GLStateKnown,32> textures{};
    std::unordered_map<uint32_t,GLStateTexture> uploads;
    std::unordered_map<uint32_t,std::unordered_map<uint32_t,GLStateTextureParameter>> texture_parameters;
    std::unordered_map<uint32_t,uint64_t> shaders;
    std::unordered_map<uint32_t,GLStateProgram> programs;
    std::vector<GLStateUniform> uniforms;
};
static GLStateObservation g_stateObservation;
static uint64_t GLStateHash(const void *data,size_t bytes) {
    uint64_t hash=14695981039346656037ULL;const auto *p=(const uint8_t *)data;
    for(size_t i=0;i<bytes;++i){hash^=p[i];hash*=1099511628211ULL;}return hash;
}
static std::string GLStateHex(const void *data,size_t bytes) {
    static const char hex[]="0123456789abcdef";std::string text; text.reserve(bytes*2);
    const auto *p=(const uint8_t *)data;
    for(size_t i=0;i<bytes;++i){text+=hex[p[i]>>4];text+=hex[p[i]&15];}return text;
}
static NSString *GLStateHashText(uint64_t hash) {char s[17];snprintf(s,sizeof(s),"%016llx",(unsigned long long)hash);return @(s);}
static NSString *GLStateText(const std::string &s) {
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding]?:@"<non-utf8>";
}
static NSDictionary *GLStateValue(const GLStateKnown &s) {return @{ @"known":@(s.known),@"value":@(s.value)};}
static bool GLStateEnabled() {
    auto &s=g_stateObservation;
    if(!s.configured){
        s.configured=true;const char *value=getenv("AS6_GL_STATE_OBSERVE");s.enabled=value&&!strcmp(value,"1");
        if(s.enabled)s.request=std::string([NSTemporaryDirectory() fileSystemRepresentation])+"native-gl-state.request";
    }
    return s.enabled&&!s.disabled;
}
static bool GLStateTriggered() {
    auto &s=g_stateObservation;if(s.triggered)return true;
    const auto now=std::chrono::steady_clock::now();if(now<s.next_check)return false;
    s.next_check=now+std::chrono::milliseconds(250);
    struct stat st{};if(!stat(s.request.c_str(),&st)&&S_ISREG(st.st_mode))s.triggered=true;
    return s.triggered;
}
// Host-only diagnostic storage. No driver/Guest calls and no retained client data.
#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <unistd.h>
static constexpr size_t GLStateSpanLimit=1u<<20,GLStateFileLimit=128u<<20;
struct GLStateBinaryRef {size_t offset=0,length=0;std::string sha;};
struct GLStateBinaryStore {
    int fd=-1,last_error=0;bool attempted=false,created=false,closed=false,io_failed=false;
    size_t written=0,byte_limit=GLStateFileLimit,unique_spans=0,dedup_hits=0;
    std::string basename;
    std::unordered_map<std::string,GLStateBinaryRef> refs;
};
static GLStateBinaryStore g_stateBinary;
static std::string GLStateSHA256(const void *data,size_t bytes) {
    unsigned char result[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data,(CC_LONG)bytes,result);
    return GLStateHex(result,sizeof(result));
}
static bool GLStateSafeBasename(const std::string &name) {
    if(name.size()<20||name.size()>180||name.compare(0,16,"native-gl-spans-")||name.substr(name.size()-4)!=".bin")return false;
    for(size_t i=0;i<name.size()-4;++i){unsigned char c=name[i];if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'))return false;}
    return true;
}
static std::string GLStateUniqueBasename() {
    std::string id;const char *run=getenv("AS6_NATIVE_RUN_ID");
    if(run)for(size_t i=0;run[i]&&id.size()<48;++i){unsigned char c=run[i];if((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_')id+=char(c);}
    if(id.empty())id="process";static unsigned generation=0;
    return "native-gl-spans-"+id+"-"+std::to_string(getpid())+"-"+
        std::to_string(std::chrono::steady_clock::now().time_since_epoch().count())+"-"+std::to_string(++generation)+".bin";
}
static void GLStateBinaryClose() noexcept {
    const GLObservationErrnoScope saved;
    if(g_stateBinary.fd>=0){::close(g_stateBinary.fd);g_stateBinary.fd=-1;}
    g_stateBinary.closed=true;
}
static NSDictionary *GLStateStoreSpan(const void *data,size_t bytes) {
    const GLObservationErrnoScope saved;auto &b=g_stateBinary;
    NSMutableDictionary *r=[@{@"storage":@"binary",@"basename":GLStateText(b.basename),@"offset":@(b.written),@"length":@0,
        @"sha256":@"",@"complete":@NO,@"original_span_bytes":@(bytes),@"deduplicated":@NO} mutableCopy];
    if(!GLStateEnabled()){r[@"missing_reason"]=@"disabled";return r;}
    if(!g_stateObservation.triggered){r[@"missing_reason"]=@"before_marker";return r;}
    if(!bytes){r[@"missing_reason"]=@"empty";return r;}
    if(bytes>GLStateSpanLimit){r[@"missing_reason"]=@"span_limit_1MiB";return r;}
    if(!data){r[@"missing_reason"]=@"no_staged_host_bytes";return r;}
    const std::string sha=GLStateSHA256(data,bytes),key=sha+":"+std::to_string(bytes);r[@"sha256"]=GLStateText(sha);
    auto old=b.refs.find(key);if(old!=b.refs.end()){
        ++b.dedup_hits;r[@"basename"]=GLStateText(b.basename);r[@"offset"]=@(old->second.offset);r[@"length"]=@(old->second.length);
        r[@"complete"]=@YES;r[@"deduplicated"]=@YES;return r;
    }
    if(b.closed||b.io_failed){r[@"missing_reason"]=@"capture_closed_after_error_or_budget";return r;}
    const size_t limit=std::min(b.byte_limit,GLStateFileLimit);
    if(b.written>limit||bytes>limit-b.written){r[@"missing_reason"]=@"file_budget_128MiB";return r;}
    if(!b.attempted){
        b.attempted=true;if(b.basename.empty())b.basename=GLStateUniqueBasename();r[@"basename"]=GLStateText(b.basename);
        const auto slash=g_stateObservation.request.rfind('/');
        if(!GLStateSafeBasename(b.basename)||slash==std::string::npos){b.io_failed=true;b.closed=true;r[@"missing_reason"]=@"unsafe_basename_or_directory";return r;}
        const std::string path=g_stateObservation.request.substr(0,slash+1)+b.basename;
        b.fd=::open(path.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0600);
        if(b.fd<0){b.last_error=errno;b.io_failed=true;b.closed=true;r[@"missing_reason"]=@"open_failed_no_overwrite";r[@"io_errno"]=@(b.last_error);return r;}
        b.created=true;
    }
    r[@"basename"]=GLStateText(b.basename);const size_t offset=b.written;size_t done=0;
    while(done<bytes){
        const ssize_t wrote=::write(b.fd,(const uint8_t *)data+done,bytes-done);
        if(wrote<0&&errno==EINTR)continue;
        if(wrote<=0){b.last_error=wrote<0?errno:EIO;b.io_failed=true;break;}
        done+=(size_t)wrote;b.written+=(size_t)wrote;
    }
    r[@"offset"]=@(offset);r[@"length"]=@(done);
    if(done!=bytes){
        r[@"missing_reason"]=@"write_failed_partial_or_empty";r[@"partial_bytes_written"]=@(done);r[@"io_errno"]=@(b.last_error);
        r[@"requested_sha256"]=GLStateText(sha);r[@"sha256"]=done?GLStateText(GLStateSHA256(data,done)):@"";
        GLStateBinaryClose();return r;
    }
    b.refs.emplace(key,GLStateBinaryRef{offset,bytes,sha});++b.unique_spans;r[@"complete"]=@YES;return r;
}
static NSDictionary *GLStateBinarySummary() {
    const auto &b=g_stateBinary;return @{@"basename":GLStateText(b.basename),@"created":@(b.created),
        @"written_bytes":@(b.written),@"effective_byte_limit":@(std::min(b.byte_limit,GLStateFileLimit)),@"span_limit":@(GLStateSpanLimit),
        @"unique_spans":@(b.unique_spans),@"dedup_hits":@(b.dedup_hits),@"closed":@(b.closed),@"io_failed":@(b.io_failed),@"last_io_errno":@(b.last_error)};
}

template<class F> static void GLStateSafe(F body) noexcept {
    const GLObservationErrnoScope saved;
    @try {try {if(GLStateEnabled())body();}catch(...){g_stateObservation.disabled=true;GLStateBinaryClose();}}
    @catch(NSException *exception) {(void)exception;g_stateObservation.disabled=true;GLStateBinaryClose();}
}
static void GLStateEmit(NSDictionary *record) {
    auto &s=g_stateObservation;if(s.total>=192)return;
    NSError *error=nil;NSData *data=[NSJSONSerialization dataWithJSONObject:record options:0 error:&error];
    if(!data||error||data.length>24576){s.disabled=true;GLStateBinaryClose();return;}
    std::string line="[gl-state] ";line.append((const char *)data.bytes,data.length);++s.total;GuestRawLog(line.c_str());
}
// A separate finite event budget leaves the original 128+32 draw capture intact.
// Everything below consumes already-forwarded scalar arguments/tracked input IDs.
static void GLStateEventEmit(NSDictionary *record) {
    NSError *error=nil;NSData *data=[NSJSONSerialization dataWithJSONObject:record options:0 error:&error];
    if(!data||error||data.length>4096)return;
    std::string line="[gl-state-event] ";line.append((const char *)data.bytes,data.length);GuestRawLog(line.c_str());
}
static void GLStateParameterForwarded(const char *name,uint32_t target,uint32_t texture,uint32_t pname,const GLStateTextureParameter &p) {
    auto &s=g_stateObservation;const uint64_t event=++s.render_event_sequence;
    unsigned &budget=pname==0x8191?s.legacy_parameter_events:s.parameter_events;const unsigned limit=pname==0x8191?32:256;
    if(budget>=limit)return;++budget;
    GLStateEventEmit(@{@"kind":@"texture-parameter-forwarded",@"render_event_sequence":@(event),@"call":@(name),@"target":@(target),
        @"unit":@(s.active.value-GL_TEXTURE0),@"texture":@(texture),@"pname":@(pname),@"is_float":@(p.is_float),@"integer_or_float_bits":@(p.bits),
        @"driver_forwarded":@YES,@"driver_acceptance_unknown":@YES});
}
static NSDictionary *GLStatePositiveLevelValue(const GLStatePositiveLevel &l) {
    return @{@"level":@(l.level),@"width":@(l.width),@"height":@(l.height),@"internal_format":@(l.internal),@"format":@(l.format),@"type":@(l.type),
        @"compressed":@(l.compressed),@"base_upload_known_at_level_call":@(l.base_known),@"observed_base_upload_revision":@(l.base_upload_revision),
        @"render_event_sequence":@(l.event_sequence),@"driver_forwarded":@YES,@"driver_acceptance_unknown":@YES};
}
static void GLStatePositiveLevelUpload(uint32_t target,uint32_t level,uint32_t internal,uint32_t width,uint32_t height,
    uint32_t format,uint32_t type,bool compressed,uint32_t texture) {
    if((int32_t)level<=0)return;auto &s=g_stateObservation;
    if(s.positive_levels.size()>=512&&!s.positive_levels.count(texture))return;
    auto &levels=s.positive_levels[texture];if(levels.size()>=32&&!levels.count(level))return;
    GLStatePositiveLevel l;l.level=level;l.width=width;l.height=height;l.internal=internal;l.format=format;l.type=type;l.compressed=compressed;
    l.event_sequence=++s.render_event_sequence;auto base=s.uploads.find(texture);if(base!=s.uploads.end()){l.base_known=true;l.base_upload_revision=base->second.base_upload_revision;}
    levels[level]=l;
    if(s.positive_level_events<64){++s.positive_level_events;NSMutableDictionary *r=[GLStatePositiveLevelValue(l) mutableCopy];
        r[@"kind"]=@"positive-level-upload-forwarded";r[@"target"]=@(target);r[@"unit"]=@(s.active.value-GL_TEXTURE0);r[@"texture"]=@(texture);GLStateEventEmit(r);}
}
static NSDictionary *GLStatePositiveLevelsValue(uint32_t texture) {
    auto &s=g_stateObservation;uint32_t seen=0,current=0;NSMutableArray *list=[NSMutableArray array];
    auto it=s.positive_levels.find(texture);auto base=s.uploads.find(texture);
    if(it!=s.positive_levels.end())for(const auto &item:it->second){const auto &l=item.second;[list addObject:GLStatePositiveLevelValue(l)];
        if(l.level<32){seen|=uint32_t(1)<<l.level;if(base!=s.uploads.end()&&l.base_known&&l.base_upload_revision==base->second.base_upload_revision)current|=uint32_t(1)<<l.level;}}
    return @{@"last_explicit_uploads":list,@"level_limit":@32,@"ever_observed_level_mask_1_to_31":@(seen),
        @"uploaded_after_latest_observed_base_mask_1_to_31":@(current),@"scope":@"last explicit level definitions observed, not GL completeness; base replacement retains old level records"};
}
static NSDictionary *GLStateMipmapValue(const GLStateMipmap &m) {
    return @{@"known":@YES,@"driver_forwarded":@YES,@"call":GLStateText(m.call),@"target":@(m.target),@"unit":@(m.unit),@"texture":@(m.texture),
        @"render_event_sequence":@(m.event_sequence),@"source_base_known":@(m.source_base_known),@"source_base_upload_revision":@(m.source_base_upload_revision),
        @"source_base_sha256":GLStateText(m.source_base_sha256),@"source_base_sha256_complete":@(m.source_sha256_complete),@"source_subimage_seen":@(m.source_subimage_seen),@"driver_acceptance_unknown":@YES};
}
static void GLStateMipmapForwarded(const char *name,uint32_t target) {
    auto &s=g_stateObservation;GLStateMipmap m;m.call=name;m.target=target;m.event_sequence=++s.render_event_sequence;
    bool bindingKnown=false;
    if(target==0x0de1&&s.active.known&&s.active.value>=GL_TEXTURE0&&s.active.value<GL_TEXTURE0+32){
        m.unit=s.active.value-GL_TEXTURE0;const auto &b=s.textures[m.unit];
        if(b.known){bindingKnown=true;m.texture=b.value;auto u=s.uploads.find(b.value);
            if(u!=s.uploads.end()){m.source_base_known=true;m.source_base_upload_revision=u->second.base_upload_revision;m.source_base_sha256=u->second.full_sha;m.source_sha256_complete=u->second.bytes&&u->second.full_hashed==u->second.bytes;m.source_subimage_seen=u->second.subimage_seen;}
            if(s.mipmaps.size()<512||s.mipmaps.count(b.value))s.mipmaps[b.value]=m;
        }
    }
    if(s.mipmap_events<128){++s.mipmap_events;NSMutableDictionary *r=[GLStateMipmapValue(m) mutableCopy];
        r[@"kind"]=@"generate-mipmap-forwarded";r[@"binding_known"]=@(bindingKnown);GLStateEventEmit(r);}
}
static void GLStateMipmapMissingDriver(const char *name) {
    if(strcmp(name,"glGenerateMipmap")&&strcmp(name,"glGenerateMipmapOES"))return;
    GLStateSafe([&]{auto &s=g_stateObservation;++s.missing_mipmap_symbols;
        if(s.mipmap_events<128){++s.mipmap_events;GLStateEventEmit(@{@"kind":@"generate-mipmap-not-forwarded",@"call":@(name),
            @"render_event_sequence":@(++s.render_event_sequence),@"driver_forwarded":@NO,@"target_known":@NO,
            @"reason":@"original dispatch missing driver or thunk; arguments were not read"});}
    });
}
static NSDictionary *GLStateClearValue(const GLStateClear &c) {
    return @{@"known":@YES,@"render_event_sequence":@(c.event_sequence),@"clear_sequence":@(c.clear_sequence),@"mask":@(c.mask),
        @"fbo_forwarded":GLStateValue(c.fbo),@"depth_mask_forwarded":GLStateValue(c.depth_mask),@"scissor_forwarded":GLStateValue(c.scissor),
        @"scissor_rect_forwarded_known":@(c.rect_known),@"scissor_rect":@[@((int32_t)c.rect[0]),@((int32_t)c.rect[1]),@((int32_t)c.rect[2]),@((int32_t)c.rect[3])],
        @"clear_depth_forwarded_known":@(c.clear_depth_known),@"clear_depth_float_bits":@(c.clear_depth_bits),
        @"color_mask_known":@(c.color_mask_known),@"color_mask":@[@(c.color_mask[0]),@(c.color_mask[1]),@(c.color_mask[2]),@(c.color_mask[3])],
        @"scope":@"original glClear forwarded; not a synthesized frame boundary or acceptance query"};
}
static NSDictionary *GLStateCurrentClear() {
    auto &s=g_stateObservation;if(s.fbo.known){auto c=s.last_fbo_clear.find(s.fbo.value);if(c!=s.last_fbo_clear.end())return GLStateClearValue(c->second);}
    return @{@"known":@NO};
}
static void GLStateClearForwarded(uint32_t mask) {
    auto &s=g_stateObservation;GLStateClear c;c.event_sequence=++s.render_event_sequence;c.clear_sequence=++s.clear_sequence;c.mask=mask;
    c.fbo=s.fbo;c.depth_mask=s.depth_mask;c.scissor=s.scissor;c.rect_known=s.scissor_rect_known;c.rect=s.scissor_rect;
    c.clear_depth_known=s.clear_depth_known;c.clear_depth_bits=s.clear_depth_bits;
    c.color_mask_known=s.color_mask_known;c.color_mask=s.color_mask;
    if(c.fbo.known&&(s.last_fbo_clear.size()<64||s.last_fbo_clear.count(c.fbo.value)))s.last_fbo_clear[c.fbo.value]=c;
    if(s.clear_events<32&&GLStateTriggered()){++s.clear_events;NSMutableDictionary *r=[GLStateClearValue(c) mutableCopy];r[@"kind"]=@"clear-forwarded";GLStateEventEmit(r);}
}

static GLStateUniform *GLStateFindUniform(uint32_t program,int32_t location,bool create) {
    auto &v=g_stateObservation.uniforms;
    for(auto &u:v)if(u.program==program&&u.location==location)return &u;
    if(!create||v.size()>=2048)return nullptr;
    v.push_back({});v.back().program=program;v.back().location=location;return &v.back();
}
static void GLStateShaderSource(uint32_t shader,uint64_t hash,bool complete) {
    GLStateSafe([&]{auto &s=g_stateObservation;if(s.shaders.size()<256||s.shaders.count(shader))
        s.shaders[shader]=complete?hash:0;});
}
static void GLStateUpload(uint32_t target,uint32_t level,uint32_t internal,uint32_t width,uint32_t height,
                          uint32_t format,uint32_t type,const void *data,size_t bytes,bool compressed) {
    GLStateSafe([&]{auto &s=g_stateObservation;
        if(!s.active.known||s.active.value<GL_TEXTURE0||s.active.value>=GL_TEXTURE0+32||target!=0x0de1)return;
        const auto &binding=s.textures[s.active.value-GL_TEXTURE0];if(!binding.known)return;
        if(s.uploads.size()>=512&&!s.uploads.count(binding.value))return;
        if(level){GLStatePositiveLevelUpload(target,level,internal,width,height,format,type,compressed,binding.value);return;} // Metadata only; no new data read/hash.
        GLStateTexture u;u.known=true;u.target=target;u.level=level;u.internal=internal;u.width=width;u.height=height;
        u.format=format;u.type=type;u.compressed=compressed;u.bytes=bytes;u.bytes_known=data;
        u.hashed=data?std::min<size_t>(bytes,1u<<20):0;u.hash=data?GLStateHash(data,u.hashed):0;
        if(data&&bytes&&bytes<=4u*1024u*1024u){u.full_hashed=bytes;u.full_sha=GLStateSHA256(data,bytes);}
        else u.full_missing=!data?"no_host_input":!bytes?"empty":"payload_exceeds_4MiB";
        u.base_upload_revision=++s.base_upload_revision_serial;u.upload_event_sequence=++s.render_event_sequence;
        auto params=s.texture_parameters.find(binding.value);if(params!=s.texture_parameters.end()){
            auto legacy=params->second.find(0x8191);if(legacy!=params->second.end()){u.legacy_generate_known=true;u.legacy_generate_is_float=legacy->second.is_float;u.legacy_generate_bits=legacy->second.bits;}
        }
        s.uploads[binding.value]=u;
        if(s.upload_events<64){++s.upload_events;GLStateEventEmit(@{@"kind":@"base-upload-forwarded",@"render_event_sequence":@(u.upload_event_sequence),
            @"target":@(target),@"unit":@(s.active.value-GL_TEXTURE0),@"texture":@(binding.value),@"base_upload_revision":@(u.base_upload_revision),
            @"source_sha256":GLStateText(u.full_sha),@"source_sha256_complete":@(u.bytes&&u.full_hashed==u.bytes),@"compressed":@(compressed),@"bytes":@(bytes),
            @"legacy_generate_parameter_at_upload":@{@"known":@(u.legacy_generate_known),@"is_float":@(u.legacy_generate_is_float),@"integer_or_float_bits":@(u.legacy_generate_bits)},
            @"driver_forwarded":@YES,@"scope":@"existing staged input and original driver call; acceptance unknown"});}
    });
}
static void GLStateForwarded(const char *name,int count,const uint64_t *I,const float *F,void *const *P) {
    GLStateSafe([&]{auto &s=g_stateObservation;auto value=[](GLStateKnown &v,uint32_t x){v={true,x};};
        if(!strcmp(name,"glActiveTexture"))value(s.active,(uint32_t)I[0]);
        else if(!strcmp(name,"glBindTexture")&&I[0]==0x0de1&&s.active.known&&s.active.value>=GL_TEXTURE0&&s.active.value<GL_TEXTURE0+32)
            value(s.textures[s.active.value-GL_TEXTURE0],(uint32_t)I[1]);
        else if((!strcmp(name,"glTexParameteri")||!strcmp(name,"glTexParameterf"))&&I[0]==0x0de1&&s.active.known&&s.active.value>=GL_TEXTURE0&&s.active.value<GL_TEXTURE0+32){
            const auto &binding=s.textures[s.active.value-GL_TEXTURE0];const uint32_t pname=(uint32_t)I[1];
            if(binding.known&&(s.texture_parameters.size()<512||s.texture_parameters.count(binding.value))&&
               (s.texture_parameters[binding.value].size()<128||s.texture_parameters[binding.value].count(pname))){
                GLStateTextureParameter p;p.is_float=!strcmp(name,"glTexParameterf");
                if(p.is_float)memcpy(&p.bits,&F[2],4);else p.bits=(uint32_t)I[2];s.texture_parameters[binding.value][pname]=p;GLStateParameterForwarded(name,(uint32_t)I[0],binding.value,pname,p);
            }
        }
        else if(!strcmp(name,"glDeleteTextures")&&P[1]){
            if(I[0]>4096){s.uploads.clear();s.texture_parameters.clear();s.mipmaps.clear();s.positive_levels.clear();for(auto &b:s.textures)b.known=false;}
            else for(uint32_t i=0;i<I[0];++i){uint32_t id;memcpy(&id,(const uint8_t *)P[1]+4*i,4);
                s.uploads.erase(id);s.texture_parameters.erase(id);s.mipmaps.erase(id);s.positive_levels.erase(id);for(auto &b:s.textures)if(b.known&&b.value==id)b.known=false;}
        }
        else if(!strcmp(name,"glGenerateMipmap")||!strcmp(name,"glGenerateMipmapOES"))GLStateMipmapForwarded(name,(uint32_t)I[0]);
        else if(!strcmp(name,"glClear"))GLStateClearForwarded((uint32_t)I[0]);
        else if(!strcmp(name,"glClearDepthf")){s.clear_depth_known=true;memcpy(&s.clear_depth_bits,F,4);}
        else if(!strcmp(name,"glScissor")){s.scissor_rect_known=true;for(unsigned i=0;i<4;++i)s.scissor_rect[i]=(uint32_t)I[i];}
        else if(!strcmp(name,"glViewport")){s.viewport_known=true;for(unsigned i=0;i<4;++i)s.viewport[i]=(uint32_t)I[i];}
        else if(!strcmp(name,"glVertexAttrib4f")&&I[0]<32){s.constant_known[I[0]]=true;memcpy(s.constant_bits[I[0]].data(),F+1,16);}
        else if(!strcmp(name,"glUseProgram"))value(s.program,(uint32_t)I[0]);
        else if(!strcmp(name,"glBindFramebuffer")||!strcmp(name,"glBindFramebufferOES"))value(s.fbo,(uint32_t)I[1]);
        else if(!strcmp(name,"glEnable")||!strcmp(name,"glDisable")) {
            const bool enabled=!strcmp(name,"glEnable");GLStateKnown *v=nullptr;
            if(I[0]==0x0be2)v=&s.blend;else if(I[0]==0x0b71)v=&s.depth;else if(I[0]==0x0b44)v=&s.cull;else if(I[0]==0x0c11)v=&s.scissor;
            if(v)value(*v,enabled);
        }else if(!strcmp(name,"glBlendFunc")){value(s.src,(uint32_t)I[0]);value(s.dst,(uint32_t)I[1]);}
        else if(!strcmp(name,"glBlendEquation")||!strcmp(name,"glBlendEquationOES"))value(s.equation,(uint32_t)I[0]);
        else if(!strcmp(name,"glDepthFunc"))value(s.depth_func,(uint32_t)I[0]);
        else if(!strcmp(name,"glDepthMask"))value(s.depth_mask,(uint32_t)I[0]);
        else if(!strcmp(name,"glCullFace"))value(s.cull_mode,(uint32_t)I[0]);
        else if(!strcmp(name,"glFrontFace"))value(s.front_face,(uint32_t)I[0]);
        else if(!strcmp(name,"glColorMask")){s.color_mask_known=true;for(int i=0;i<4;++i)s.color_mask[i]=(uint32_t)I[i];}
        else if(!strcmp(name,"glDepthRangef")){s.depth_range_known=true;memcpy(s.depth_range.data(),F,8);}
        else if(!strcmp(name,"glPolygonOffset")){s.polygon_offset_known=true;memcpy(s.polygon_offset.data(),F,8);}
        else if(!strcmp(name,"glGetAttribLocation")&&(int32_t)g_ret>=0&&g_ret<32&&P[1]&&(s.programs.size()<128||s.programs.count((uint32_t)I[0]))) {
            s.programs[(uint32_t)I[0]].attributes[g_ret].assign((const char *)P[1],strnlen((const char *)P[1],128));
        }else if(!strcmp(name,"glGetUniformLocation")&&(int32_t)g_ret>=0&&P[1]) {
            if(auto *u=GLStateFindUniform((uint32_t)I[0],(int32_t)g_ret,true))u->name.assign((const char *)P[1],strnlen((const char *)P[1],128));
        }else if(!strcmp(name,"glAttachShader")&&(s.programs.size()<128||s.programs.count((uint32_t)I[0]))) {
            auto &v=s.programs[(uint32_t)I[0]].attached;if(v.size()<8)v.push_back((uint32_t)I[1]);
        }else if(!strcmp(name,"glLinkProgram")) {
            auto it=s.programs.find((uint32_t)I[0]);if(it!=s.programs.end()){
                it->second.linked_hashes.clear();for(auto id:it->second.attached){auto sh=s.shaders.find(id);it->second.linked_hashes.push_back(sh==s.shaders.end()?0:sh->second);}
            }
        }else if(s.program.known&&(!strcmp(name,"glUniformMatrix4fv")||!strcmp(name,"glUniform4fv")||!strcmp(name,"glUniform3fv")||!strcmp(name,"glUniform1i"))) {
            if((int32_t)I[0]>=0)if(auto *u=GLStateFindUniform(s.program.value,(int32_t)I[0],true)){
                u->call=name;u->count=!strcmp(name,"glUniform1i")?1:(uint32_t)I[1];u->transpose=!strcmp(name,"glUniformMatrix4fv")?(uint32_t)I[2]:0;
                const void *data=!strcmp(name,"glUniform1i")?(const void *)&I[1]:P[!strcmp(name,"glUniformMatrix4fv")?3:2];
                size_t bytes=!strcmp(name,"glUniform1i")?4:std::min<uint64_t>(256,uint64_t(u->count)*(!strcmp(name,"glUniformMatrix4fv")?64:!strcmp(name,"glUniform4fv")?16:12));
                u->bytes.clear();if(data&&bytes)u->bytes.assign((const uint8_t *)data,(const uint8_t *)data+bytes);
            }
        }
        if(!strcmp(name,"glGetError")&&g_ret&&s.errors<32){++s.errors;
            GLStateEmit(@{@"kind":@"existing-error-return",@"value":@(g_ret),@"source":@"original glGetError only; no extra query"});}
        if(!strcmp(name,"glCompressedTexImage2D")&&count==8)GLStateUpload((uint32_t)I[0],(uint32_t)I[1],(uint32_t)I[2],(uint32_t)I[3],(uint32_t)I[4],0,0,P[7],(uint32_t)I[6],true);
        (void)count;
    });
}
static void GLStateBinding(uint32_t target,uint32_t buffer) {
    GLStateSafe([&]{auto &s=g_stateObservation;if(target==GL_ARRAY_BUFFER)s.array_bound={true,buffer};
        else if(target==GL_ELEMENT_ARRAY_BUFFER)s.element_bound={true,buffer};});
}
static void GLStateAttribEnabled(uint32_t index) {GLStateSafe([&]{if(index<32)g_stateObservation.attrib_enabled_seen[index]=true;});}
static void GLStateDeletedBuffers(const uint32_t *ids,uint32_t count) {GLStateSafe([&]{auto &s=g_stateObservation;
    if(count>4096){s.array_bound.known=false;s.element_bound.known=false;return;}
    for(uint32_t i=0;i<count;++i){if(s.array_bound.known&&s.array_bound.value==ids[i])s.array_bound.known=false;
        if(s.element_bound.known&&s.element_bound.value==ids[i])s.element_bound.known=false;}
});}
static void GLStateSubimage(uint32_t target,uint32_t level) {GLStateSafe([&]{auto &s=g_stateObservation;
    if(level||target!=0x0de1||!s.active.known||s.active.value<GL_TEXTURE0||s.active.value>=GL_TEXTURE0+32)return;
    auto &b=s.textures[s.active.value-GL_TEXTURE0];if(!b.known)return;auto u=s.uploads.find(b.value);
    if(u!=s.uploads.end())u->second.subimage_seen=true;
});}
// These pointers are only the host spans already produced by this draw's staging.
// Reset them before every StageClientArrays; never retain across an ArenaReset.
static void GLStateBeginClientDraw() {GLStateSafe([&]{for(auto &span:g_stateObservation.client_spans)span={};});}
static void GLStateClientStaged(unsigned index,const void *host,size_t bytes,uint32_t stride,bool forwarded) {
    GLStateSafe([&]{if(index<32)g_stateObservation.client_spans[index]={(const uint8_t *)host,bytes,stride,forwarded};});
}
static void GLStateDraw(const char *call,uint32_t mode,uint32_t first,uint32_t count,uint32_t type,
                        uint32_t ptr,const void *indices,size_t indexBytes,uint32_t maxIndex,bool driverFound) {
    GLStateSafe([&]{auto &s=g_stateObservation;const uint64_t eventSequence=++s.render_event_sequence;if(!GLStateTriggered())return;if(s.inspected>=4096){GLStateBinaryClose();return;}++s.inspected;
        const bool match=!strcmp(call,"glDrawElements")&&count==18;
        if(match){if(s.matched>=32)return;++s.matched;}else{if(s.draws>=128)return;++s.draws;}
        NSMutableArray *attrs=[NSMutableArray array];
        for(unsigned i=0;i<32;++i){const auto &a=g_varr[i];if(!a.used&&!a.enabled&&!s.constant_known[i])continue;
            NSMutableDictionary *attr=[@{@"index":@(i),@"enabled_forwarded_seen":@(s.attrib_enabled_seen[i]),@"enabled_tracked":@(a.enabled),
                @"pointer_forwarded_seen":@(a.used),@"size":@(a.size),@"type":@(a.type),@"normalized":@(a.normalized),
                @"stride":@(a.stride),@"guest_pointer_or_vbo_offset":@(a.ptr),@"buffer":@(a.buffer),@"client_memory":@(!a.buffer)} mutableCopy];
            if(match&&a.buffer){auto buffer=g_bufs.find(a.buffer);if(buffer!=g_bufs.end()&&a.ptr<=buffer->second.data.size()){
                const auto &data=buffer->second.data;const uint64_t element=uint64_t(a.size)*TypeSize(a.type);
                const uint64_t wanted=uint64_t(maxIndex)*(a.stride?a.stride:element)+element;
                const size_t bytes=(size_t)std::min<uint64_t>(1024,std::min<uint64_t>(wanted,data.size()-a.ptr));
                attr[@"vbo_existing_cpu_mirror_prefix"]=@{@"bytes":@(bytes),@"required_range_bytes":@(wanted),
                    @"hex":GLStateText(bytes?GLStateHex(data.data()+a.ptr,bytes):std::string()),@"source":@"existing host buffer mirror; no extra GuestRead"};
            }}
            auto programRole=s.programs.find(s.program.value);bool roleKnown=false;
            if(s.program.known&&programRole!=s.programs.end()){
                auto role=programRole->second.attributes.find(i);if(role!=programRole->second.attributes.end()){
                    roleKnown=true;attr[@"role_from_existing_lookup"]=GLStateText(role->second);
                }
            }
            attr[@"role_forwarded_known"]=@(roleKnown);
            attr[@"constant_forwarded_known"]=@(s.constant_known[i]);
            if(s.constant_known[i])attr[@"constant_float_bits_hex"]=GLStateText(GLStateHex(s.constant_bits[i].data(),16));
            const auto &span=s.client_spans[i];
            if(span.data&&span.bytes){
                const size_t prefix=std::min<size_t>(span.bytes,match?1024:64);
                const size_t hashed=std::min<size_t>(span.bytes,1024);
                attr[@"client_already_staged_span"]=@{@"guest_base":@(a.ptr),@"staged_bytes":@(span.bytes),@"stride":@(span.stride),
                    @"driver_pointer_forwarded":@(span.driver_pointer_forwarded),@"prefix_bytes":@(prefix),
                    @"prefix_hex":GLStateText(GLStateHex(span.data,prefix)),@"hashed_bytes":@(hashed),
                    @"fnv1a64":GLStateHashText(GLStateHash(span.data,hashed)),@"extra_GuestRead":@NO,@"full_span":GLStateStoreSpan(span.data,span.bytes)};
            }
            [attrs addObject:attr];
        }
        NSMutableArray *textures=[NSMutableArray array];
        for(unsigned i=0;i<32;++i){auto &b=s.textures[i];if(!b.known)continue;
            NSMutableDictionary *texture=[@{@"unit":@(i),@"binding_forwarded":GLStateValue(b)} mutableCopy];
            auto it=s.uploads.find(b.value);if(it!=s.uploads.end()){
                const auto &u=it->second;texture[@"level0_upload_forwarded"]=@{@"internal_format":@(u.internal),@"compressed":@(u.compressed),
                    @"width":@(u.width),@"height":@(u.height),@"format":@(u.format),@"type":@(u.type),@"bytes":@(u.bytes),
                    @"input_bytes_known":@(u.bytes_known),@"hashed_bytes":@(u.hashed),@"fnv1a64":GLStateHashText(u.hash),
                    @"later_level0_subimage_seen":@(u.subimage_seen),@"base_upload_revision":@(u.base_upload_revision),@"upload_event_sequence":@(u.upload_event_sequence),@"legacy_generate_parameter_at_upload":@{@"known":@(u.legacy_generate_known),@"is_float":@(u.legacy_generate_is_float),@"integer_or_float_bits":@(u.legacy_generate_bits)},@"full_sha256":GLStateText(u.full_sha),@"full_hashed_bytes":@(u.full_hashed),
                    @"full_hash_complete":@(u.bytes&&u.full_hashed==u.bytes),@"full_hash_missing_reason":GLStateText(u.full_missing)};
            }
            NSMutableDictionary *parameters=[NSMutableDictionary dictionary];
            auto params=s.texture_parameters.find(b.value);if(params!=s.texture_parameters.end())for(const auto &p:params->second)
                parameters[[@(p.first) stringValue]]=@{@"observed_forwarded":@YES,@"is_float":@(p.second.is_float),@"integer_or_float_bits":@(p.second.bits)};
            texture[@"parameters_forwarded"]=parameters;texture[@"parameter_pname_limit"]=@128;texture[@"explicit_positive_level_observations"]=GLStatePositiveLevelsValue(b.value);
            auto mip=s.mipmaps.find(b.value);
            if(mip!=s.mipmaps.end()){
                const auto &m=mip->second;texture[@"last_generate_mipmap_forwarded"]=GLStateMipmapValue(m);
                texture[@"generate_matches_latest_observed_base_upload"]=@(it!=s.uploads.end()&&m.source_base_known&&m.source_base_upload_revision==it->second.base_upload_revision);
            }else texture[@"last_generate_mipmap_forwarded"]=@{@"known":@NO};
            [textures addObject:texture];
        }
        NSMutableArray *uniforms=[NSMutableArray array];
        if(s.program.known)for(const auto &u:s.uniforms)if(u.program==s.program.value){
            [uniforms addObject:@{@"location":@(u.location),@"name_from_existing_lookup":GLStateText(u.name),@"last_forwarded_call":GLStateText(u.call),
                @"count":@(u.count),@"transpose":@(u.transpose),@"recorded_host_bytes":@(u.bytes.size()),@"hex":GLStateText(GLStateHex(u.bytes.data(),u.bytes.size())),
                @"fnv1a64":GLStateHashText(GLStateHash(u.bytes.data(),u.bytes.size()))}];
        }
        NSMutableArray *hashes=[NSMutableArray array];auto program=s.programs.find(s.program.value);
        if(s.program.known&&program!=s.programs.end())for(auto hash:program->second.linked_hashes)[hashes addObject:GLStateHashText(hash)];
        NSDictionary *indexSpan=GLStateStoreSpan(indices,indexBytes);
        NSDictionary *record=@{@"kind":@"draw-forwarded",@"draw_since_trigger":@(s.inspected),@"record_sequence":@(s.total+1),
            @"render_event_sequence":@(eventSequence),@"last_clear_for_current_FBO":GLStateCurrentClear(),@"missing_mipmap_driver_symbol_calls":@(s.missing_mipmap_symbols),
            @"host_timestamp_unix_ms":@(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count()),
            @"viewport_forwarded_known":@(s.viewport_known),@"viewport_forwarded":@[@((int32_t)s.viewport[0]),@((int32_t)s.viewport[1]),@((int32_t)s.viewport[2]),@((int32_t)s.viewport[3])],
            @"state_scope":@"last observed forwarded arguments; driver acceptance/defaults unknown",@"call":@(call),
            @"match_shadow_18_indices":@(match),@"mode":@(mode),@"first":@(first),@"count":@(count),@"index_type":@(type),
            @"guest_indices_or_ebo_offset":@(ptr),@"index_full_span":indexSpan,@"binary_store":GLStateBinarySummary(),@"index_host_bytes_known":@(indices!=nullptr),@"max_index_from_existing_scan":@(maxIndex),
            @"index_prefix_bytes":@(indices?std::min<size_t>(indexBytes,256):0),@"index_prefix_hex":GLStateText(indices?GLStateHex(indices,std::min<size_t>(indexBytes,256)):std::string()),
            @"driver_symbol_found":@(driverFound),@"program_forwarded":GLStateValue(s.program),@"linked_source_hashes":hashes,
            @"fbo_forwarded":GLStateValue(s.fbo),@"array_binding_forwarded":GLStateValue(s.array_bound),@"element_binding_forwarded":GLStateValue(s.element_bound),
            @"active_texture_forwarded":GLStateValue(s.active),@"textures2d":textures,@"attrs_existing_tracker":attrs,@"uniforms_already_marshaled":uniforms,
            @"blend_forwarded":GLStateValue(s.blend),@"blend_src_forwarded":GLStateValue(s.src),@"blend_dst_forwarded":GLStateValue(s.dst),@"blend_equation_forwarded":GLStateValue(s.equation),
            @"depth_forwarded":GLStateValue(s.depth),@"depth_func_forwarded":GLStateValue(s.depth_func),@"depth_mask_forwarded":GLStateValue(s.depth_mask),
            @"cull_forwarded":GLStateValue(s.cull),@"cull_mode_forwarded":GLStateValue(s.cull_mode),@"front_face_forwarded":GLStateValue(s.front_face),
            @"scissor_forwarded":GLStateValue(s.scissor),@"color_mask_known":@(s.color_mask_known),@"color_mask":@[@(s.color_mask[0]),@(s.color_mask[1]),@(s.color_mask[2]),@(s.color_mask[3])],
            @"depth_range_known":@(s.depth_range_known),@"depth_range_float_bits":GLStateText(GLStateHex(s.depth_range.data(),8)),
            @"polygon_offset_known":@(s.polygon_offset_known),@"polygon_offset_float_bits":GLStateText(GLStateHex(s.polygon_offset.data(),8))};
        GLStateEmit(record);
        if(s.draws>=128&&s.matched>=32)GLStateBinaryClose();
    });
}


// Re-point every live client array at a host copy of the guest data, then run
// the draw.  `vertices` is how many vertices the driver may touch.
// Narrow workaround (AS6_GL_MVP_PULSE_COMPAT=0 disables) for the independently reproduced original-program reuse issue.
// Exact original 679/554 TEXTURED+LIGHTMAP source only; no query or guest access.
#ifndef AS6_MVP_PULSE_TEST_CONTEXT
#import <OpenGLES/EAGL.h>
#endif
#import <objc/runtime.h>
#include <memory>
#include <atomic>
#include <cmath>

namespace AS6MVPPulse {
struct Shader {uint64_t generation=0;uint32_t name=0,type=0;unsigned exactSource=0;bool compileForwarded=false,compiled=false,deleted=false;};
struct Program {
    uint64_t generation=0,linkEpoch=0;uint32_t name=0;bool deleted=false,attachmentsUnknown=false,linkCandidate=false,driverLinked=false,linked=false;
    std::vector<std::shared_ptr<Shader>> attached;
    int32_t mvpLocation=-1;bool matrixKnown=false;alignas(float) std::array<uint8_t,64> matrix{};
};
struct Context {
    uint64_t serial=0,pulses=0;bool disabled=false;
    std::unordered_map<uint32_t,std::shared_ptr<Shader>> shaders;
    std::unordered_map<uint32_t,std::shared_ptr<Program>> programs;
    std::shared_ptr<Program> current;
    void createdShader(uint32_t id,uint32_t type){if(!id)return;auto s=std::make_shared<Shader>();s->name=id;s->type=type;s->generation=++serial;shaders[id]=s;}
    void createdProgram(uint32_t id){if(!id)return;auto p=std::make_shared<Program>();p->name=id;p->generation=++serial;if(current&&current->name==id)current.reset();programs[id]=p;}
    void source(uint32_t id,unsigned kind){auto s=shaders.find(id);if(s!=shaders.end()){s->second->exactSource=kind;s->second->compiled=false;s->second->compileForwarded=false;}}
    void use(uint32_t id){auto old=current;current.reset();auto p=programs.find(id);if(p!=programs.end()&&!p->second->deleted&&p->second->driverLinked)current=p->second;
        if(old&&old->deleted){auto it=programs.find(old->name);if(it!=programs.end()&&it->second==old)programs.erase(it);}}
    void forward(const char *name,const uint64_t *I,void *const *P,uint32_t result){
        if(!strcmp(name,"glCreateProgram")){createdProgram(result);return;}
        uint32_t id=(uint32_t)I[0];
        if(!strcmp(name,"glCreateShader")){createdShader(result,id);return;}
        if(!strcmp(name,"glUseProgram")){use(id);return;}
        if(!strcmp(name,"glDeleteShader")){auto it=shaders.find(id);if(it!=shaders.end())it->second->deleted=true;return;}
        if(!strcmp(name,"glCompileShader")){auto it=shaders.find(id);if(it!=shaders.end()){it->second->compiled=false;it->second->compileForwarded=true;}return;}
        if(!strcmp(name,"glGetShaderiv")&&I[1]==0x8b81&&P[2]){auto it=shaders.find(id);if(it!=shaders.end()){int32_t ok;memcpy(&ok,P[2],4);it->second->compiled=it->second->compileForwarded&&ok==1;}return;}
        if(!strncmp(name,"glUniform",9)){
            if(!current||!current->linked||current->deleted||(int32_t)I[0]!=current->mvpLocation)return;
            if(!strcmp(name,"glUniformMatrix4fv")&&(int32_t)I[1]==0)return; // Legal no-op does not invalidate the last matrix.
            current->matrixKnown=false;
            if(!strcmp(name,"glUniformMatrix4fv")&&I[1]==1&&I[2]==0&&P[3]){memcpy(current->matrix.data(),P[3],64);current->matrixKnown=true;}
            return;
        }
        auto it=programs.find(id);if(it==programs.end())return;auto &p=*it->second;
        if(!strcmp(name,"glDeleteProgram")){p.deleted=true;p.matrixKnown=false;if(current!=it->second)programs.erase(it);return;}
        if(!strcmp(name,"glAttachShader")){
            auto s=shaders.find((uint32_t)I[1]);if(s==shaders.end()){p.attachmentsUnknown=true;return;}
            if(std::find(p.attached.begin(),p.attached.end(),s->second)==p.attached.end())p.attached.push_back(s->second);return;
        }
        if(!strcmp(name,"glDetachShader")){p.attached.erase(std::remove_if(p.attached.begin(),p.attached.end(),[&](const auto &s){return s->name==(uint32_t)I[1];}),p.attached.end());return;}
        if(!strcmp(name,"glLinkProgram")){
            ++p.linkEpoch;p.linked=false;p.driverLinked=false;p.linkCandidate=false;p.mvpLocation=-1;p.matrixKnown=false;
            if(!p.deleted&&!p.attachmentsUnknown&&p.attached.size()==2){unsigned vs=0,fs=0;for(const auto &s:p.attached){
                vs+=s->compiled&&s->type==0x8b31&&s->exactSource==1;fs+=s->compiled&&s->type==0x8b30&&s->exactSource==2;}
                p.linkCandidate=vs==1&&fs==1;}
            return;
        }
        if(!strcmp(name,"glGetProgramiv")&&I[1]==0x8b82&&P[2]){int32_t ok;memcpy(&ok,P[2],4);p.driverLinked=ok==1&&!p.deleted;p.linked=p.linkCandidate&&p.driverLinked;if(!p.linked)p.matrixKnown=false;return;}
        if(!strcmp(name,"glGetUniformLocation")&&(int32_t)result>=0&&P[1]&&p.linked&&
           !strcmp((const char *)P[1],"WorldViewProjectionMatrix")){
            if(p.mvpLocation!=(int32_t)result)p.matrixKnown=false;p.mvpLocation=(int32_t)result;
        }
    }
    bool matrices(float *original,float *temporary,int32_t &location)const{
        if(disabled||!current||current->deleted||!current->linked||!current->matrixKnown||current->mvpLocation<0)return false;
        memcpy(original,current->matrix.data(),64);memcpy(temporary,original,64);
        for(unsigned i=0;i<16;++i)if(!std::isfinite(original[i]))return false;
        for(unsigned col=0;col<4;++col){temporary[4*col]=original[4*col]+.05f*original[4*col+3];if(!std::isfinite(temporary[4*col]))return false;}
        location=current->mvpLocation;return memcmp(original,temporary,64)!=0;
    }
};
}
@interface AS6MVPPulseOwner:NSObject { @public AS6MVPPulse::Context state; }
@end
@implementation AS6MVPPulseOwner
@end
@interface AS6MVPPulseSharegroupOwner:NSObject { @public __weak id firstContext;BOOL seen,disabled; }
@end
@implementation AS6MVPPulseSharegroupOwner
@end
static char AS6MVPPulseOwnerKey,AS6MVPPulseSharegroupKey;
static std::atomic<bool> AS6MVPPulseDisabled{false};
static bool AS6MVPPulseEnabled(){static const bool enabled=[](){const char *s=getenv("AS6_GL_MVP_PULSE_COMPAT");return !s||strcmp(s,"0");}();return enabled&&!AS6MVPPulseDisabled.load(std::memory_order_relaxed);}
static AS6MVPPulseOwner *AS6MVPPulseCurrent(){
#ifdef AS6_MVP_PULSE_TEST_CONTEXT
    id context=AS6MVPPulseTestCurrentContext(),group=AS6MVPPulseTestSharegroup();bool api2=AS6MVPPulseTestAPI()==2;if(!context||!group)return nil;
#else
    Class contextClass=objc_lookUpClass("EAGLContext");EAGLContext *context=[(id)contextClass currentContext];if(!context)return nil;id group=context.sharegroup;if(!group)return nil;bool api2=context.API==kEAGLRenderingAPIOpenGLES2;
#endif
    AS6MVPPulseSharegroupOwner *guard=objc_getAssociatedObject(group,&AS6MVPPulseSharegroupKey);
    if(!guard){guard=[AS6MVPPulseSharegroupOwner new];objc_setAssociatedObject(group,&AS6MVPPulseSharegroupKey,guard,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
    if(!guard->seen){guard->seen=YES;guard->firstContext=context;}else if(guard->firstContext!=context)guard->disabled=YES;
    if(guard->disabled||!api2)return nil; // Shared program objects could be mutated by another context: stop this entire group.
    AS6MVPPulseOwner *owner=objc_getAssociatedObject(context,&AS6MVPPulseOwnerKey);
    if(!owner){owner=[AS6MVPPulseOwner new];objc_setAssociatedObject(context,&AS6MVPPulseOwnerKey,owner,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}return owner;
}
// Diagnostic-only sidecar. No GL symbol lookup/query or guest access.
#include <map>
#include <tuple>
static bool AS6MVPTraceEnabled()noexcept{static const bool on=[](){const char*s=getenv("AS6_GL_MVP_PULSE_TRACE");return s&&!strcmp(s,"1");}();return on;}
static std::atomic<unsigned> AS6MVPTraceLines{0},AS6MVPTraceLifeLines{0},AS6MVPTraceDrawLines{0},AS6MVPTraceDisableReason{0};
static char AS6MVPTraceIdentityKey;
static uint64_t AS6MVPTraceNextIdentity=0;
static void AS6MVPTraceEmit(const char*line,bool lifecycle)noexcept{
 const GLObservationErrnoScope saved;
 if(!AS6MVPTraceEnabled())return;
 @try{try{
  auto&category=lifecycle?AS6MVPTraceLifeLines:AS6MVPTraceDrawLines;
  if(category.fetch_add(1,std::memory_order_relaxed)>=(lifecycle?32u:96u))return;
  if(AS6MVPTraceLines.fetch_add(1,std::memory_order_relaxed)>=128)return;
  GuestRawLog(line);
 }catch(...){}}@catch(NSException*e){(void)e;}
}
static void AS6MVPTraceMarkDisabled(unsigned reason)noexcept{
 const GLObservationErrnoScope saved;if(!AS6MVPTraceEnabled())return;
 if(AS6MVPTraceDisableReason.exchange(reason,std::memory_order_relaxed)==reason)return;
 char line[160];snprintf(line,sizeof(line),"[gl-mvp-trace] event=disable reason_code=%u context_not_queried=1",reason);AS6MVPTraceEmit(line,true);
}
struct AS6MVPTraceSnapshot {
 id context=nil,group=nil;
 AS6MVPPulseOwner*owner=nil;AS6MVPPulseSharegroupOwner*guard=nil;
 uint64_t contextID=0,groupID=0;int api=-1;bool main=false,queryFailed=false;
};
static uint64_t AS6MVPTraceIdentity(id object){
 if(!object)return 0;
 NSNumber*n=objc_getAssociatedObject(object,&AS6MVPTraceIdentityKey);
 if(!n){n=@(++AS6MVPTraceNextIdentity);objc_setAssociatedObject(object,&AS6MVPTraceIdentityKey,n,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
 return n.unsignedLongLongValue;
}
static AS6MVPTraceSnapshot AS6MVPTraceSnapshotNow()noexcept{
 const GLObservationErrnoScope saved;AS6MVPTraceSnapshot s;
 if(!AS6MVPTraceEnabled())return s;
 @try{try{
  s.main=NSThread.isMainThread;if(!s.main)return s;
#ifdef AS6_MVP_PULSE_TEST_CONTEXT
  s.context=AS6MVPPulseTestCurrentContext();s.group=AS6MVPPulseTestSharegroup();s.api=AS6MVPPulseTestAPI();
#else
  Class cls=objc_lookUpClass("EAGLContext");EAGLContext*c=[(id)cls currentContext];s.context=c;
  if(c){s.group=c.sharegroup;s.api=(int)c.API;}
#endif
  s.contextID=AS6MVPTraceIdentity(s.context);s.groupID=AS6MVPTraceIdentity(s.group);
  if(s.context)s.owner=objc_getAssociatedObject(s.context,&AS6MVPPulseOwnerKey);
  if(s.group)s.guard=objc_getAssociatedObject(s.group,&AS6MVPPulseSharegroupKey);
 }catch(...){s.queryFailed=true;}}@catch(NSException*e){(void)e;s.queryFailed=true;}
 return s;
}
static bool AS6MVPTraceCompatConfigured()noexcept{static const bool configured=[](){const char*s=getenv("AS6_GL_MVP_PULSE_COMPAT");return !s||strcmp(s,"0");}();return configured;}
struct AS6MVPTraceDrawHistory {unsigned draws=0,reasonBits=0;uint64_t pulses=0;};
static std::map<std::tuple<uint64_t,uint64_t,uint64_t,bool>,AS6MVPTraceDrawHistory> AS6MVPTraceDrawHistoryMap;
static std::map<uint64_t,uint32_t> AS6MVPTraceRequestedProgram;
static unsigned AS6MVPTracePreDraws=0,AS6MVPTracePostDraws=0;
static bool AS6MVPTraceDrawPhaseAvailable(bool marker)noexcept{return (marker?AS6MVPTracePostDraws:AS6MVPTracePreDraws)<(marker?32u:64u);}
static bool AS6MVPTraceDrawPhaseBudget(bool marker)noexcept{
 if(!AS6MVPTraceEnabled())return false;
 // Main-thread-only. Reserve a bounded post-marker portion even if many
 // unrelated early scene programs used their own first-draw allowances.
 auto&count=marker?AS6MVPTracePostDraws:AS6MVPTracePreDraws;
 if(count>=(marker?32u:64u))return false;++count;return true;
}
static void AS6MVPTraceUseForwarded(uint32_t program)noexcept{
 const GLObservationErrnoScope saved;if(!AS6MVPTraceEnabled()||AS6MVPTraceDrawLines.load(std::memory_order_relaxed)>=96)return;
 @try{try{auto s=AS6MVPTraceSnapshotNow();if(s.main&&s.context)AS6MVPTraceRequestedProgram[s.contextID]=program;}catch(...){}}@catch(NSException*e){(void)e;}
}
struct AS6MVPTraceEvaluation {const AS6MVPPulse::Context*state=nullptr;const AS6MVPPulse::Program*program=nullptr;int finite=-1,changed=-1,entry=-1;bool eligible=false;};
static thread_local AS6MVPTraceEvaluation AS6MVPTraceLastEvaluation;
static int AS6MVPTraceFiniteBits(const uint8_t*bytes)noexcept{
 uint32_t words[16];memcpy(words,bytes,64);for(uint32_t word:words)if((word&0x7f800000u)==0x7f800000u)return 0;return 1;
}
static void AS6MVPTraceEvaluated(const AS6MVPPulse::Context&state,const float*original,const float*temporary,int32_t location,bool eligible)noexcept{
 if(!AS6MVPTraceEnabled()||AS6MVPTraceDrawLines.load(std::memory_order_relaxed)>=96)return;
 auto&e=AS6MVPTraceLastEvaluation;e.state=&state;e.program=state.current.get();e.eligible=eligible;
 const auto&p=state.current;
 if(p&&p->matrixKnown)e.finite=AS6MVPTraceFiniteBits(p->matrix.data());
 // matrices assigns location only after both owned arrays were copied and
 // every arithmetic/finite check completed. Reuse that result, never repeat FP
 // arithmetic or touch uninitialized arrays merely to diagnose a skipped call.
 if(location>=0)e.changed=memcmp(original,temporary,64)!=0;
}
static void AS6MVPTraceProgramFields(const AS6MVPPulse::Program*p,unsigned&vs,unsigned&fs,unsigned&cv,unsigned&cf){
 vs=fs=cv=cf=0;if(!p)return;
 for(const auto&s:p->attached){vs+=s->exactSource==1;fs+=s->exactSource==2;cv+=s->compiled&&s->exactSource==1;cf+=s->compiled&&s->exactSource==2;}
}
static std::shared_ptr<AS6MVPPulse::Program> AS6MVPTraceProgramBefore(AS6MVPPulse::Context&state,const char*name,const uint64_t*I)noexcept{
 if(!AS6MVPTraceEnabled()||AS6MVPTraceLifeLines.load(std::memory_order_relaxed)>=32)return {};
 if(strcmp(name,"glDeleteProgram"))return {};
 auto it=state.programs.find((uint32_t)I[0]);return it==state.programs.end()?nullptr:it->second;
}
static void AS6MVPTraceLifecycle(AS6MVPPulse::Context&state,const char*name,const uint64_t*I,
 std::shared_ptr<AS6MVPPulse::Program> deleted={})noexcept{
 const GLObservationErrnoScope saved;if(!AS6MVPTraceEnabled()||AS6MVPTraceLifeLines.load(std::memory_order_relaxed)>=32)return;
 @try{try{
  if(strcmp(name,"glLinkProgram")&&strcmp(name,"glGetProgramiv")&&strcmp(name,"glDeleteProgram")&&strcmp(name,"glUseProgram")&&strcmp(name,"glGetUniformLocation"))return;
  if(!strcmp(name,"glGetProgramiv")&&I[1]!=0x8b82)return;
  auto it=state.programs.find((uint32_t)I[0]);auto p=it==state.programs.end()?deleted:it->second;if(!p)return;
  unsigned vs,fs,cv,cf;AS6MVPTraceProgramFields(p.get(),vs,fs,cv,cf);
  if(!p->linkCandidate&&!(vs==1&&fs==1))return;
  auto s=AS6MVPTraceSnapshotNow();if(!s.main)return;
  char line[768];snprintf(line,sizeof(line),"[gl-mvp-trace] event=lifecycle call=%s ctx=%llu api=%d group=%llu program=%u generation=%llu link_epoch=%llu exact_vs_now=%u exact_fs_now=%u compiled_vs_now=%u compiled_fs_now=%u link_candidate=%d driver_linked_observed=%d linked_qualified=%d deleted=%d mvp_loc=%d matrix_known=%d",
   name,(unsigned long long)s.contextID,s.api,(unsigned long long)s.groupID,p->name,(unsigned long long)p->generation,(unsigned long long)p->linkEpoch,vs,fs,cv,cf,p->linkCandidate,p->driverLinked,p->linked,p->deleted,p->mvpLocation,p->matrixKnown);
  AS6MVPTraceEmit(line,true);
 }catch(...){}}@catch(NSException*e){(void)e;}
}
static void AS6MVPTraceAfterDraw(AS6MVPTraceSnapshot s,uint64_t beforePulses)noexcept{
 const GLObservationErrnoScope saved;if(!AS6MVPTraceEnabled())return;
 @try{try{
  if(!s.main){
   static std::atomic<bool> logged{false};
   if(!logged.exchange(true,std::memory_order_relaxed)){
    char line[256];snprintf(line,sizeof(line),"[gl-mvp-trace] event=draw reason=non_main_draw main=0 context_not_queried=1 global_disabled=%d global_reason_code=%u",AS6MVPPulseDisabled.load(std::memory_order_relaxed),AS6MVPTraceDisableReason.load(std::memory_order_relaxed));AS6MVPTraceEmit(line,false);
   }
   return; // All sidecar maps/associated identities remain main-thread-only.
  }
  // Re-read associated diagnostic/model owners only. No context switch,
  // glGet*, driver lookup, memory staging or guest access is performed.
  if(s.context)s.owner=objc_getAssociatedObject(s.context,&AS6MVPPulseOwnerKey);
  if(s.group)s.guard=objc_getAssociatedObject(s.group,&AS6MVPPulseSharegroupKey);
  AS6MVPPulse::Context*state=s.owner?&s.owner->state:nullptr;
  std::shared_ptr<AS6MVPPulse::Program> p=state?state->current:nullptr;
  const auto requestedIt=AS6MVPTraceRequestedProgram.find(s.contextID);
  const bool requestedKnown=requestedIt!=AS6MVPTraceRequestedProgram.end();const uint32_t requested=requestedKnown?requestedIt->second:0;
  if(!p&&state){auto it=state->programs.find(requested);if(it!=state->programs.end())p=it->second;}
  int finite=p&&p->matrixKnown?AS6MVPTraceFiniteBits(p->matrix.data()):-1,changed=-1,entry=-1;
  if(AS6MVPTraceLastEvaluation.state==state&&AS6MVPTraceLastEvaluation.program==p.get()){
   changed=AS6MVPTraceLastEvaluation.changed;entry=AS6MVPTraceLastEvaluation.entry;
  }
  const bool global=AS6MVPPulseDisabled.load(std::memory_order_relaxed),configured=AS6MVPTraceCompatConfigured();
  const bool applied=state&&state->pulses>beforePulses;
  const char*reason="pulse_applied";unsigned reasonCode=0;
  if(!configured){reason="compat_off";reasonCode=1;}
  else if(global){reason="global_disabled";reasonCode=2;}
  else if(!s.main){reason="non_main";reasonCode=3;}
  else if(s.queryFailed){reason="native_context_snapshot_exception";reasonCode=4;}
  else if(!s.context){reason="no_native_context";reasonCode=5;}
  else if(!s.group){reason="no_native_sharegroup";reasonCode=6;}
  else if(s.guard&&s.guard->disabled){reason="sharegroup_disabled";reasonCode=7;}
  else if(s.api!=2){reason="native_api_not2";reasonCode=8;}
  else if(!state){reason="no_model_owner";reasonCode=9;}
  else if(state->disabled){reason="model_budget_disabled";reasonCode=10;}
  else if(!state->current){reason="no_qualified_current_model";reasonCode=11;}
  else if(p->deleted){reason="program_deleted";reasonCode=12;}
  else if(!p->linked){reason="program_not_exact_linked";reasonCode=13;}
  else if(p->mvpLocation<0){reason="mvp_location_unknown";reasonCode=14;}
  else if(!p->matrixKnown){reason="matrix_unknown_or_unsupported_setter";reasonCode=15;}
  else if(!finite){reason="matrix_nonfinite";reasonCode=16;}
  else if(changed==0){reason="temporary_matrix_identical";reasonCode=17;}
  else if(!applied){reason="eligible_without_completed_pulse";reasonCode=18;}
  unsigned vs,fs,cv,cf;AS6MVPTraceProgramFields(p.get(),vs,fs,cv,cf);
  const bool target=p&&(p->linkCandidate||(vs==1&&fs==1));
  const bool contextSkip=reasonCode>=1&&reasonCode<=10;
  const bool trackingActive=configured&&!global&&s.main&&!s.queryFailed&&s.context&&s.group&&s.guard&&!s.guard->disabled&&s.api==2&&state&&!state->disabled;
  const bool marker=g_stateObservation.triggered; // Existing observer flag only; never call its stat-based trigger helper.
  // Preserve the draw budget for exact-pair candidates and context/global
  // failures. Unrelated programs are folded into at most4 diagnostic lines.
  if(!target&&!contextSkip){static unsigned nonTargetLines=0;if(nonTargetLines++>=4)return;}
  if(!AS6MVPTraceDrawPhaseAvailable(marker))return; // Do not fill the history map after this phase's quota.
  auto key=std::make_tuple(s.contextID,p?p->generation:0,p?p->linkEpoch:0,marker);
  if(AS6MVPTraceDrawHistoryMap.size()>=128&&!AS6MVPTraceDrawHistoryMap.count(key))return;
  auto&history=AS6MVPTraceDrawHistoryMap[key];if(applied)++history.pulses;
  const bool record=history.draws++<2||!(history.reasonBits&(1u<<reasonCode));history.reasonBits|=1u<<reasonCode;if(!record)return;
  if(!AS6MVPTraceDrawPhaseBudget(marker))return;
  char line[1200];snprintf(line,sizeof(line),"[gl-mvp-trace] event=draw reason=%s marker_active=%d ctx=%llu context_known=%d api=%d group=%llu guard_known=%d share_disabled=%d main=%d compat=%d global_disabled=%d global_reason_code=%u model_tracking_active=%d forwarded_use_known=%d last_forwarded_use_program=%u last_model_program=%u model_use_matches_forwarded=%d generation=%llu link_epoch=%llu target_candidate=%d link_candidate=%d driver_linked_observed=%d linked_qualified=%d exact_vs_now=%u exact_fs_now=%u compiled_vs_now=%u compiled_fs_now=%u deleted=%d mvp_loc=%d matrix_known=%d finite=%d changed=%d uniform_entry=%d pulse_applied=%d program_observed_pulses=%llu context_pulses=%llu",
   reason,marker,(unsigned long long)s.contextID,s.context!=nil,s.api,(unsigned long long)s.groupID,s.guard!=nil,s.guard?s.guard->disabled:0,s.main,configured,global,AS6MVPTraceDisableReason.load(std::memory_order_relaxed),trackingActive,requestedKnown,requested,p?p->name:0,requestedKnown&&p&&requested==p->name,(unsigned long long)(p?p->generation:0),(unsigned long long)(p?p->linkEpoch:0),target,p?p->linkCandidate:0,p?p->driverLinked:0,p?p->linked:0,vs,fs,cv,cf,p?p->deleted:0,p?p->mvpLocation:-1,p?p->matrixKnown:0,finite,changed,entry,applied,(unsigned long long)history.pulses,(unsigned long long)(state?state->pulses:0));
  AS6MVPTraceEmit(line,false);
 }catch(...){}}@catch(NSException*e){(void)e;}
}

static void AS6MVPPulseThreadGate()noexcept{
    const GLObservationErrnoScope saved;
    @try{if(AS6MVPPulseEnabled()&&![NSThread isMainThread]){AS6MVPPulseDisabled.store(true,std::memory_order_relaxed);AS6MVPTraceMarkDisabled(1);}}
    @catch(NSException *exception){(void)exception;AS6MVPPulseDisabled.store(true,std::memory_order_relaxed);AS6MVPTraceMarkDisabled(4);}
}
template<class F> static void AS6MVPPulseSafe(F body)noexcept{
    const GLObservationErrnoScope saved;
    @try{try{if(AS6MVPPulseEnabled()){if(![NSThread isMainThread]){AS6MVPPulseDisabled.store(true,std::memory_order_relaxed);AS6MVPTraceMarkDisabled(2);return;}AS6MVPPulseOwner *owner=AS6MVPPulseCurrent();if(owner&&!owner->state.disabled){
        if(owner->state.shaders.size()>4096||owner->state.programs.size()>4096)owner->state.disabled=true;else body(owner->state);}}}catch(...){AS6MVPPulseDisabled.store(true,std::memory_order_relaxed);AS6MVPTraceMarkDisabled(3);}}
    @catch(NSException *exception){(void)exception;AS6MVPPulseDisabled.store(true,std::memory_order_relaxed);AS6MVPTraceMarkDisabled(4);}
}
static void AS6MVPPulseSource(uint32_t shader,const char *const *strings,const size_t *lengths,uint32_t count,bool complete){
    AS6MVPPulseSafe([&](AS6MVPPulse::Context &state){
        unsigned kind=0;size_t bytes=0;CC_SHA256_CTX hash;CC_SHA256_Init(&hash);
        if(complete&&strings&&lengths&&count<=64){for(uint32_t i=0;i<count;++i){if(!strings[i]||lengths[i]>65536-bytes){complete=false;break;}bytes+=lengths[i];CC_SHA256_Update(&hash,strings[i],(CC_LONG)lengths[i]);}
            if(complete){unsigned char digest[32];CC_SHA256_Final(digest,&hash);std::string hex=GLStateHex(digest,32);
                if(hex=="80967cee927e0979b4054b2717e0d1cb26f3377373a98252b37b45c3042c8df2")kind=1;
                else if(hex=="f580ad58cc48d1a8d6dea049feb3ac4dc595b45c271b1982af52a287edcd4581")kind=2;}}
        state.source(shader,kind);
    });
}
static void AS6MVPPulseForwarded(const char *name,const uint64_t *I,void *const *P){
    if(strcmp(name,"glCreateShader")&&strcmp(name,"glCreateProgram")&&strcmp(name,"glUseProgram")&&strcmp(name,"glDeleteShader")&&strcmp(name,"glDeleteProgram")&&strcmp(name,"glCompileShader")&&strcmp(name,"glAttachShader")&&strcmp(name,"glDetachShader")&&strcmp(name,"glLinkProgram")&&strcmp(name,"glGetShaderiv")&&strcmp(name,"glGetProgramiv")&&strcmp(name,"glGetUniformLocation")&&strncmp(name,"glUniform",9))return;
    if(!strcmp(name,"glUseProgram"))AS6MVPTraceUseForwarded((uint32_t)I[0]);
    AS6MVPPulseSafe([&](AS6MVPPulse::Context &state){auto traced=AS6MVPTraceProgramBefore(state,name,I);state.forward(name,I,P,g_ret);AS6MVPTraceLifecycle(state,name,I,traced);});
}
static void AS6MVPPulseBeforeDrawOriginal(){
    AS6MVPPulseSafe([&](AS6MVPPulse::Context &state){
        float original[16],temporary[16];int32_t location=-1;const bool eligible=state.matrices(original,temporary,location);AS6MVPTraceEvaluated(state,original,temporary,location,eligible);if(!eligible)return;
        auto fn=(void(*)(int32_t,int32_t,uint8_t,const float *))GLSym("glUniformMatrix4fv");if(AS6MVPTraceEnabled())AS6MVPTraceLastEvaluation.entry=fn!=nullptr;if(!fn)return;
        // No draw/query while temporary values are active. Restore even if a host exception intervenes.
        @try{fn(location,1,0,temporary);}@finally{fn(location,1,0,original);}
        ++state.pulses;static unsigned lines=0;if(lines<16){++lines;char log[192];snprintf(log,sizeof(log),"[gl-mvp-pulse] program=%u generation=%llu link_epoch=%llu location=%d count=%llu",state.current->name,(unsigned long long)state.current->generation,(unsigned long long)state.current->linkEpoch,location,(unsigned long long)state.pulses);GuestRawLog(log);}
    });
}

static void AS6MVPPulseBeforeDraw(){
    if(!AS6MVPTraceEnabled()||AS6MVPTraceDrawLines.load(std::memory_order_relaxed)>=96){AS6MVPPulseBeforeDrawOriginal();return;}
    AS6MVPTraceLastEvaluation={};
    auto snapshot=AS6MVPTraceSnapshotNow();const uint64_t before=snapshot.owner?snapshot.owner->state.pulses:0;
    AS6MVPPulseBeforeDrawOriginal();
    AS6MVPTraceAfterDraw(snapshot,before);
}

// The original ES2 import set never binds a VAO, and this bridge has no VAO
// tracker. Admit only the default-VAO, single-VM/context state proved by the
// forwarded buffer/attribute calls below. Unknown state keeps the old path.
struct GLClientArrayIdentity { void *vm=nullptr,*context=nullptr; bool main=false,api2=false; };
struct GLClientArrayFastState {
    GLClientArrayIdentity owner{};
    bool initialized=false,arrayKnown=true,elementKnown=true;
    std::array<bool,32> attributeKnown{};
};
static GLClientArrayFastState g_clientArrayFast;
static std::atomic<bool> g_clientArrayFastDisabled{false};
static GLClientArrayIdentity GLClientArrayCurrentIdentity() noexcept {
    const GLObservationErrnoScope saved;
    @try {
        static Class cls=objc_lookUpClass("EAGLContext");
        id context=[(id)cls currentContext];
        return {(__bridge void *)g_vm,(__bridge void *)context,bool(NSThread.isMainThread),
                context&&[context API]==kEAGLRenderingAPIOpenGLES2};
    } @catch(NSException *exception) {(void)exception;return {};}
}
static bool GLClientArrayOwnedContext() noexcept {
    if(g_clientArrayFastDisabled.load(std::memory_order_relaxed))return false;
    const auto current=GLClientArrayCurrentIdentity();
    if(!current.main||!current.api2||!current.vm||!current.context){
        g_clientArrayFastDisabled.store(true,std::memory_order_relaxed);return false;
    }
    auto &s=g_clientArrayFast;
    if(!s.initialized){s.initialized=true;s.owner=current;}
    if(current.vm!=s.owner.vm||current.context!=s.owner.context){
        g_clientArrayFastDisabled.store(true,std::memory_order_relaxed);return false;
    }
    return true;
}
static void GLClientArrayNoticeVAO(const char *name) noexcept {
    if(!strncmp(name,"glBindVertexArray",17)||!strncmp(name,"glDeleteVertexArrays",20))
        g_clientArrayFastDisabled.store(true,std::memory_order_relaxed);
}
static void GLClientArrayBinding(uint32_t target,bool forwarded) noexcept {
    if(!GLClientArrayOwnedContext())return;
    if(target==GL_ARRAY_BUFFER)g_clientArrayFast.arrayKnown=forwarded;
    else if(target==GL_ELEMENT_ARRAY_BUFFER)g_clientArrayFast.elementKnown=forwarded;
}
static void GLClientArrayPointer(uint32_t index,const VArr &a,bool forwarded) noexcept {
    if(!GLClientArrayOwnedContext()||index>=32)return;
    // ES2 guarantees at least eight attributes. Larger indices, invalid or
    // unusual pointer formats are not proof that the driver accepted a call.
    const bool type=a.type==GL_BYTE||a.type==GL_UNSIGNED_BYTE||a.type==GL_SHORT||
                    a.type==GL_UNSIGNED_SHORT||a.type==GL_FLOAT;
    g_clientArrayFast.attributeKnown[index]=forwarded&&index<8&&a.buffer&&
        a.size>=1&&a.size<=4&&type&&a.normalized<=1&&a.stride<=255&&
        !(a.ptr%TypeSize(a.type))&&g_clientArrayFast.arrayKnown;
}
static void GLClientArrayDeletedBuffers(const uint32_t *ids,uint32_t count,bool forwarded) noexcept {
    if(!GLClientArrayOwnedContext())return;
    if(!forwarded){g_clientArrayFastDisabled.store(true,std::memory_order_relaxed);return;}
    if(!ids||int32_t(count)<=0)return;
    for(unsigned attr=0;attr<32;++attr)
        for(uint32_t i=0;i<count;++i)
            if(g_varr[attr].buffer==ids[i])g_clientArrayFast.attributeKnown[attr]=false;
}
// Cache only state-derived decisions. Guest vertex bytes are still copied for
// every client-memory draw, and context/VM ownership is rechecked every time.
struct GLPreparedClientPlan {
    bool dirty=true,vboOnly=false;
    std::uint8_t fixed[3]{},textures[32]{},attributes[32]{};
    unsigned fixedCount=0,textureCount=0,attributeCount=0;
};
static GLPreparedClientPlan g_preparedClientPlan;
static void GLClientDrawPlanChanged() noexcept {g_preparedClientPlan.dirty=true;}
static const GLPreparedClientPlan &GLPreparedClientDraw() noexcept {
    auto &p=g_preparedClientPlan;if(!p.dirty)return p;
    p.fixedCount=p.textureCount=p.attributeCount=0;
    bool valid=true,enabledVBO=false;
    for(unsigned i=0;i<3;++i){const auto &a=g_arr[i];
        if(a.enabled)valid=false;
        if(a.enabled&&a.ptr&&!a.buffer)p.fixed[p.fixedCount++]=std::uint8_t(i);
    }
    for(unsigned i=0;i<32;++i){const auto &a=g_texArr[i];
        if(a.enabled)valid=false;
        if(a.enabled&&a.ptr&&!a.buffer)p.textures[p.textureCount++]=std::uint8_t(i);
    }
    for(unsigned i=0;i<32;++i){const auto &a=g_varr[i];
        if(!a.enabled)continue;
        if(!a.used||!a.buffer||!g_clientArrayFast.attributeKnown[i])valid=false;
        else enabledVBO=true;
        if(a.used&&a.ptr&&!a.buffer)p.attributes[p.attributeCount++]=std::uint8_t(i);
    }
    p.vboOnly=valid&&enabledVBO;p.dirty=false;return p;
}

static bool GLClientArrayCanSkipStaging() noexcept {
    // Observer records include the CPU index scan and staged spans. Preserve
    // their exact existing behavior, including before its request is triggered.
    bool observing=false;
    GLStateSafe([&]{observing=true;});
    if(observing||!GLClientArrayOwnedContext()||
       !g_clientArrayFast.arrayKnown||!g_clientArrayFast.elementKnown)return false;
    return GLPreparedClientDraw().vboOnly;
}

static void StageClientArrays(GuestVM *vm, uint32_t vertices) {
    GLStateBeginClientDraw();
    const auto &plan=GLPreparedClientDraw();
    void *vp = GLPreparedSymbol(GLCall::glVertexPointer), *np = GLPreparedSymbol(GLCall::glNormalPointer),
         *cp = GLPreparedSymbol(GLCall::glColorPointer), *tp = GLPreparedSymbol(GLCall::glTexCoordPointer);
    void *bind = GLPreparedSymbol(GLCall::glBindBuffer);
    if (bind) ((Fn_v_ui_ui)bind)(GL_ARRAY_BUFFER, 0);
    for(unsigned at=0;at<plan.fixedCount;++at) {
        const unsigned i=plan.fixed[at];Arr &a=g_arr[i];
        uint32_t elems = a.size ? a.size : 3;
        size_t ts = TypeSize(a.type);
        size_t stride = a.stride ? a.stride : (size_t)elems * ts;
        size_t bytes = vertices ? stride * (vertices - 1) + (size_t)elems * ts : 0;
        void *host = GuestToHost(vm, a.ptr, bytes, NO);
        if (!host) continue;
        switch (i) {
            case 0: if (vp) ((void (*)(uint32_t, uint32_t, uint32_t, void *))vp)(a.size, a.type, (uint32_t)stride, host); break;
            case 1: if (np) ((void (*)(uint32_t, uint32_t, void *))np)(a.type, (uint32_t)stride, host); break;
            case 2: if (cp) ((void (*)(uint32_t, uint32_t, uint32_t, void *))cp)(a.size, a.type, (uint32_t)stride, host); break;
            case 3: if (tp) ((void (*)(uint32_t, uint32_t, uint32_t, void *))tp)(a.size, a.type, (uint32_t)stride, host); break;
        }
    }
    void *active = GLPreparedSymbol(GLCall::glClientActiveTexture);
    BOOL touchedTex = NO;
    for(unsigned at=0;at<plan.textureCount;++at) {
        const uint32_t unit=plan.textures[at];Arr &a=g_texArr[unit];
        size_t ts = TypeSize(a.type), stride = a.stride ? a.stride : (size_t)a.size * ts;
        size_t bytes = vertices ? stride * (vertices - 1) + (size_t)a.size * ts : 0;
        void *host = GuestToHost(vm, a.ptr, bytes, NO);
        if (!host) continue;
        if (active) { ((Fn_v_ui)active)(GL_TEXTURE0 + unit); touchedTex = YES; }
        if (tp) ((void (*)(uint32_t, uint32_t, uint32_t, void *))tp)(a.size, a.type,
                                                                 (uint32_t)stride, host);
    }
    if (active && touchedTex) ((Fn_v_ui)active)(GL_TEXTURE0 + g_clientTexture);
    for(unsigned at=0;at<plan.attributeCount;++at) {
        const unsigned i=plan.attributes[at];VArr &a=g_varr[i];
        uint32_t elems = a.size ? a.size : 4;
        size_t ts = TypeSize(a.type);
        size_t stride = a.stride ? a.stride : (size_t)elems * ts;
        size_t bytes = vertices ? stride * (vertices - 1) + (size_t)elems * ts : 0;
        void *host = GuestToHost(vm, a.ptr, bytes, NO);
        if (!host) continue;
        void *f = GLPreparedSymbol(GLCall::glVertexAttribPointer);
        if (f) ((void (*)(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, void *))f)(
                   (uint32_t)i, a.size, a.type, a.normalized, (uint32_t)stride, host);
        GLStateClientStaged((unsigned)i,host,bytes,(uint32_t)stride,f!=nullptr);
    }
    if (bind) ((Fn_v_ui_ui)bind)(GL_ARRAY_BUFFER, g_bound[1]);
}

// --- the overrides: everything positional marshalling cannot express --------
static BOOL GLStringToGuest(GuestVM *vm, const char *host, uint32_t *out) {
    if (!host) { *out = 0; return YES; }
    static std::unordered_map<std::string, uint32_t> cache;
    auto it = cache.find(host);
    if (it != cache.end()) { *out = it->second; return YES; }
    size_t len = strlen(host) + 1;
    uint32_t gva = GuestAlloc(vm, len);
    if (!gva) return NO;
    GuestWrite(vm, gva, host, len);
    cache[host] = gva;
    *out = gva;
    return YES;
}

static BOOL Override(GuestVM *vm,GLCall operation,const char *name,Cursor *c,void *f) {
    switch(operation) {
    case GLCall::glBindBuffer:
    {
        GLClientDrawPlanChanged();

        uint32_t target = c->NextInt(), buf = c->NextInt();
        g_bound[BoundSlot(target)] = buf;

        if (f) ((Fn_v_ui_ui)f)(target, buf);
        GLClientArrayBinding(target,f!=nullptr);
        if (f) GLStateBinding(target,buf);
        return YES;


    }
    case GLCall::glBufferData:
    {

        uint32_t target = c->NextInt(), size = c->NextInt();
        uint32_t gva = c->NextInt(), usage = c->NextInt();
        void *host = gva ? GuestToHost(vm, gva, size, NO) : NULL;
        if ((int32_t)size >= 0 && g_bound[BoundSlot(target)]) {
            BufInfo &bi = g_bufs[g_bound[BoundSlot(target)]];
            bi.indexMaximum.invalidate();
            bi.size = size;
            bi.guestMap = 0;
            try {
                bi.data.resize(size);
                if (host && size) memcpy(bi.data.data(), host, size);
                else if (size) memset(bi.data.data(), 0, size);
            } catch (...) { bi.data.clear(); GuestRawLog("[gl] buffer mirror allocation failed"); }
        }

        if (f) GLRealHostCall([&]{((void (*)(uint32_t, intptr_t, void *, uint32_t))f)(target, (int32_t)size, host, usage);});
        return YES;


    }
    case GLCall::glBufferSubData:
    {

        uint32_t target = c->NextInt(), offset = c->NextInt(), size = c->NextInt();
        uint32_t gva = c->NextInt();
        void *host = gva ? GuestToHost(vm, gva, size, NO) : NULL;
        BufInfo &bi = g_bufs[g_bound[BoundSlot(target)]];
        if (host && (uint64_t)offset + size <= bi.data.size()) {
            bi.indexMaximum.invalidate();
            memcpy(bi.data.data() + offset, host, size);
        }

        if (f) GLRealHostCall([&]{((void (*)(uint32_t, intptr_t, intptr_t, void *))f)(target, (int32_t)offset,
                                                                 (int32_t)size, host);});
        return YES;


    }
    case GLCall::glDeleteBuffers:
    {
        GLClientDrawPlanChanged();

        uint32_t count = c->NextInt(), gva = c->NextInt();
        uint32_t *buffers = (uint32_t *)GuestToHost(vm, gva, (size_t)count * 4, NO);

        if (f) GLRealHostCall([&]{((void (*)(int32_t, const uint32_t *))f)((int32_t)count, buffers);});
        if (buffers && (int32_t)count > 0) {
            for (uint32_t i = 0; i < count; i++) {
                g_bufs.erase(buffers[i]);
                if (g_bound[1] == buffers[i]) g_bound[1] = 0;
                if (g_bound[2] == buffers[i]) g_bound[2] = 0;
            }
        }
        if (f&&buffers&&(int32_t)count>0)GLStateDeletedBuffers(buffers,count);
        GLClientArrayDeletedBuffers(buffers,count,f!=nullptr);
        return YES;


    }
    case GLCall::glMapBufferOES:
    {

        uint32_t target = c->NextInt();
        c->NextInt();
        BufInfo &bi = g_bufs[g_bound[BoundSlot(target)]];
        uint32_t size = bi.size ? bi.size : 4096;
        uint32_t gva = GuestAlloc(vm, size);
        bi.guestMap = gva;
        GuestSetRet(vm, gva);
        return YES;


    }
    case GLCall::glUnmapBufferOES:
    {

        uint32_t target = c->NextInt();
        BufInfo &bi = g_bufs[g_bound[BoundSlot(target)]];
        if (bi.guestMap && bi.size) {
            void *host = GuestToHost(vm, bi.guestMap, bi.size, NO);
            void *sub = GLSym("glBufferSubData");
            if (host && sub)
                ((void (*)(uint32_t, intptr_t, intptr_t, void *))sub)(target, 0, bi.size, host);
            if (host && bi.data.size() == bi.size) {
                bi.indexMaximum.invalidate();
                memcpy(bi.data.data(), host, bi.size);
            }
            bi.guestMap = 0;
        }
        GuestSetRet(vm, GL_TRUE);
        return YES;

    // ---- GLES1 client arrays -------------------------------------------------

    }
    case GLCall::glClientActiveTexture:
    {
        GLClientDrawPlanChanged();

        GLClientArrayOwnedContext();
        uint32_t unit = c->NextInt();
        if (unit >= GL_TEXTURE0 && unit < GL_TEXTURE0 + 32) g_clientTexture = unit - GL_TEXTURE0;

        if (f) ((Fn_v_ui)f)(unit);
        return YES;


    }
    case GLCall::glEnableClientState:
    case GLCall::glDisableClientState:
    {
        GLClientDrawPlanChanged();

        GLClientArrayOwnedContext();
        uint32_t cap = c->NextInt();
        int slot = ArrSlot(cap);
        if (slot == 3) g_texArr[g_clientTexture].enabled = (name[2] == 'E');
        else if (slot >= 0) g_arr[slot].enabled = (name[2] == 'E');

        if (f) ((Fn_v_ui)f)(cap);
        return YES;


    }
    case GLCall::glVertexPointer:
    {
        GLClientDrawPlanChanged();

        GLClientArrayOwnedContext();
        uint32_t size = c->NextInt(), type = c->NextInt(), stride = c->NextInt(), ptr = c->NextInt();
        g_arr[0] = {g_arr[0].enabled, size, type, stride, ptr, g_bound[1]};

        if (f && g_bound[1])
            ((void (*)(uint32_t, uint32_t, uint32_t, void *))f)(size, type, stride, (void *)(uintptr_t)ptr);
        return YES;   // the host pointer is staged at draw time


    }
    case GLCall::glNormalPointer:
    {
        GLClientDrawPlanChanged();

        GLClientArrayOwnedContext();
        uint32_t type = c->NextInt(), stride = c->NextInt(), ptr = c->NextInt();
        g_arr[1] = {g_arr[1].enabled, 3, type, stride, ptr, g_bound[1]};

        if (f && g_bound[1])
            ((void (*)(uint32_t, uint32_t, void *))f)(type, stride, (void *)(uintptr_t)ptr);
        return YES;


    }
    case GLCall::glColorPointer:
    {
        GLClientDrawPlanChanged();

        GLClientArrayOwnedContext();
        uint32_t size = c->NextInt(), type = c->NextInt(), stride = c->NextInt(), ptr = c->NextInt();
        g_arr[2] = {g_arr[2].enabled, size, type, stride, ptr, g_bound[1]};

        if (f && g_bound[1])
            ((void (*)(uint32_t, uint32_t, uint32_t, void *))f)(size, type, stride, (void *)(uintptr_t)ptr);
        return YES;


    }
    case GLCall::glTexCoordPointer:
    {
        GLClientDrawPlanChanged();

        GLClientArrayOwnedContext();
        uint32_t size = c->NextInt(), type = c->NextInt(), stride = c->NextInt(), ptr = c->NextInt();
        Arr &a = g_texArr[g_clientTexture];
        a = {a.enabled, size, type, stride, ptr, g_bound[1]};

        if (f && g_bound[1])
            ((void (*)(uint32_t, uint32_t, uint32_t, void *))f)(size, type, stride, (void *)(uintptr_t)ptr);
        return YES;


    }
    case GLCall::glEnableVertexAttribArray:
    case GLCall::glDisableVertexAttribArray:
    {
        GLClientDrawPlanChanged();

        GLClientArrayOwnedContext();
        uint32_t index = c->NextInt();
        if (index < 32) g_varr[index].enabled = (name[2] == 'E');
        GLStateAttribEnabled(index);

        if (f) ((Fn_v_ui)f)(index);
        return YES;


    }
    case GLCall::glVertexAttribPointer:
    {
        GLClientDrawPlanChanged();

        uint32_t index = c->NextInt(), size = c->NextInt(), type = c->NextInt();
        uint32_t norm = c->NextInt(), stride = c->NextInt(), ptr = c->NextInt();
        if (index < 32)
            g_varr[index] = {1, g_varr[index].enabled, size, type, stride, ptr, g_bound[1], norm};
        if (g_bound[1] == 0) {
            if(index<32)GLClientArrayPointer(index,g_varr[index],false);
            return YES;
        }
   // a real VBO is bound: ptr is a byte offset
        if (f) ((void (*)(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, void *))f)(
                   index, size, type, norm, stride, (void *)(uintptr_t)ptr);
        if(index<32)GLClientArrayPointer(index,g_varr[index],f!=nullptr);
        return YES;


    }
    case GLCall::glDrawArrays:
    {

        uint32_t mode = c->NextInt(), first = c->NextInt(), count = c->NextInt();
        if(!GLClientArrayCanSkipStaging())StageClientArrays(vm, first + count);

        if (f) { if(count) AS6MVPPulseBeforeDraw(); GLRealHostCall([&]{((void (*)(uint32_t, uint32_t, uint32_t))f)(mode, first, count);}); }
        GLStateDraw(name,mode,first,count,0,0,nullptr,0,first+count,f!=nullptr);
        return YES;


    }
    case GLCall::glDrawElements:
    {

        uint32_t mode = c->NextInt(), count = c->NextInt(), type = c->NextInt(), gva = c->NextInt();
        size_t idxBytes = (size_t)count * TypeSize(type);
        void *idx = NULL;
        const uint8_t *scan = NULL;
        BufInfo *indexMirror=nullptr;
        if (g_bound[2]) {
            // With an element buffer bound, the argument is a byte OFFSET,
            // including zero; it must never be dereferenced as guest memory.
            idx = (void *)(uintptr_t)gva;
            BufInfo &bi = g_bufs[g_bound[2]];
            if ((uint64_t)gva + idxBytes <= bi.data.size()) {
                scan = bi.data.data() + gva;indexMirror=&bi;
            }
        } else {
            idx = gva ? GuestToHost(vm, gva, idxBytes, NO) : NULL;
            scan = (const uint8_t *)idx;
        }
        uint32_t maxIdx = 0;
        const bool skipStaging=GLClientArrayCanSkipStaging();
        if(scan&&!skipStaging) {
            const unsigned width=type==GL_UNSIGNED_BYTE?1:type==GL_UNSIGNED_SHORT?2:type==GL_UNSIGNED_INT?4:0;
            // Only reuse an exact reduction of the owned EBO mirror. Client
            // memory is recopied/reduced every draw; observer scans stay exact.
            bool observing=false;
            if(indexMirror&&width&&count>=as6_render_plan::IndexRangeCache::MinimumIndices)
                GLStateSafe([&]{observing=true;});
            const bool cacheEligible=indexMirror&&width&&
                count>=as6_render_plan::IndexRangeCache::MinimumIndices&&!observing;
            const bool cacheHit=cacheEligible&&indexMirror->indexMaximum.find(indexMirror->data.size(),gva,count,width,maxIdx);
            if(cacheEligible)as6_render_plan::renderWorkTelemetry.recordIndexCacheQuery(idxBytes,cacheHit);
            if(!cacheHit) {
                static as6_render_plan::IndexMaximum indexJobs;
                const auto scanStart=idxBytes>=(4u<<20)?std::chrono::steady_clock::now():std::chrono::steady_clock::time_point{};
                const auto reduced=width?indexJobs.maximum(scan,idxBytes,count,width):as6_render_plan::IndexMaximum::Result{};
                if(reduced.valid) {
                    const auto elapsed=scanStart.time_since_epoch().count()?std::uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now()-scanStart).count()):0;
                    as6_render_plan::renderWorkTelemetry.record(idxBytes,reduced.workers,elapsed);
                    maxIdx=reduced.maximum;
                    if(cacheEligible)indexMirror->indexMaximum.remember(indexMirror->data.size(),gva,count,width,maxIdx);
                }
                else {
                    const uint8_t *b = scan;
                    for (uint32_t i = 0; i < count; i++) {
                        uint32_t v = 0;
                        if (type == GL_UNSIGNED_BYTE) v = b[i];
                        else if (type == GL_UNSIGNED_SHORT) v = ((const uint16_t *)b)[i];
                        else v = ((const uint32_t *)b)[i];
                        if (v > maxIdx) maxIdx = v;
                    }
                }
            }
        }
        if(!skipStaging)StageClientArrays(vm, maxIdx + 1);

        if (f) { if(count) AS6MVPPulseBeforeDraw(); GLRealHostCall([&]{((void (*)(uint32_t, uint32_t, uint32_t, void *))f)(mode, count, type, idx);}); }
        GLStateDraw(name,mode,0,count,type,gva,scan,idxBytes,maxIdx,f!=nullptr);
        return YES;

    // ---- pixel data ----------------------------------------------------------

    }
    case GLCall::glPixelStorei:
    {

        uint32_t pname = c->NextInt(), value = c->NextInt();
        if (value == 1 || value == 2 || value == 4 || value == 8) {
            if (pname == GL_PACK_ALIGNMENT) g_packAlignment = value;
            if (pname == GL_UNPACK_ALIGNMENT) g_unpackAlignment = value;
        }

        if (f) ((Fn_v_ui_ui)f)(pname, value);
        return YES;


    }
    case GLCall::glTexImage2D:
    {

        uint32_t target = c->NextInt(), level = c->NextInt(), internal = c->NextInt();
        uint32_t w = c->NextInt(), h = c->NextInt(), border = c->NextInt();
        uint32_t format = c->NextInt(), type = c->NextInt(), gva = c->NextInt();
        size_t bytes = PixelBytes(w, h, format, type, g_unpackAlignment);
        void *px = (gva && bytes) ? GuestToHost(vm, gva, bytes, NO) : NULL;

        if (f) GLRealHostCall([&]{((void (*)(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                          uint32_t, uint32_t, void *))f)(target, level, internal, w, h, border,
                                                        format, type, px);});
        if (f) GLStateUpload(target,level,internal,w,h,format,type,px,bytes,false);
        return YES;


    }
    case GLCall::glTexSubImage2D:
    {

        uint32_t target = c->NextInt(), level = c->NextInt(), x = c->NextInt(), y = c->NextInt();
        uint32_t w = c->NextInt(), h = c->NextInt(), format = c->NextInt(), type = c->NextInt();
        uint32_t gva = c->NextInt();
        size_t bytes = PixelBytes(w, h, format, type, g_unpackAlignment);
        void *px = (gva && bytes) ? GuestToHost(vm, gva, bytes, NO) : NULL;

        if (f) GLRealHostCall([&]{((void (*)(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                          uint32_t, uint32_t, void *))f)(target, level, x, y, w, h,
                                                        format, type, px);});
        if (f) GLStateSubimage(target,level);
        return YES;


    }
    case GLCall::glReadPixels:
    {

        uint32_t x = c->NextInt(), y = c->NextInt(), w = c->NextInt(), h = c->NextInt();
        uint32_t format = c->NextInt(), type = c->NextInt(), gva = c->NextInt();
        size_t bytes = PixelBytes(w, h, format, type, g_packAlignment);
        void *px = (gva && bytes) ? GuestToHost(vm, gva, bytes, YES) : NULL;

        if (f) GLRealHostCall([&]{((void (*)(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                          void *))f)(x, y, w, h, format, type, px);});
        return YES;

    // ---- shader sources ------------------------------------------------------

    }
    case GLCall::glShaderSource:
    {

        uint32_t shader = c->NextInt(), count = c->NextInt();
        uint32_t strv = c->NextInt(), lenv = c->NextInt();
        const uint32_t suppliedCount=count;
        if (count > 64) count = 64;
        size_t observedLengths[64]{};uint32_t staged=0;uint64_t sourceHash=14695981039346656037ULL;BOOL complete=YES;
        const char **strings = (const char **)Arena(sizeof(char *) * (count + 1));
        int32_t *lens = lenv ? (int32_t *)Arena(sizeof(int32_t) * (count + 1)) : NULL;
        if (strings && strv) {
            for (uint32_t i = 0; i < count; i++) {
                uint32_t sp = GuestReadU32(vm, strv + 4 * i);
                size_t len = sp ? GuestStrLen(vm, sp, 1u << 20) : 0;
                char *dst = (char *)Arena(len + 1);
                if (!dst) { complete=NO; break; }
                BOOL copied=YES;if (sp && len) copied=GuestRead(vm, sp, dst, len);
                observedLengths[i]=len;++staged;complete=complete&&copied;
                if(copied)for(size_t k=0;k<len;++k){sourceHash^=(unsigned char)dst[k];sourceHash*=1099511628211ULL;}
                dst[len] = '\0';
                strings[i] = dst;
                if (lens) lens[i] = (int32_t)len;
            }
        }
        complete=complete&&(staged==count);
        ObserveGLSource(shader,suppliedCount,count,lenv,observedLengths,staged,sourceHash,complete);
        GLStateShaderSource(shader,sourceHash,complete);

        if (f) GLRealHostCall([&]{((void (*)(uint32_t, uint32_t, const char **, const int32_t *))f)(
                   shader, count, strings, lens);});
        if (f) AS6MVPPulseSource(shader,strings,observedLengths,staged,complete&&staged==count&&suppliedCount==count&&!lenv);
        return YES;

    // ---- strings the guest keeps --------------------------------------------

    }
    case GLCall::glGetString:
    case GLCall::glGetStringi:
    {

        uint32_t a = c->NextInt(), b = c->NextInt();
        void *sf = f;
        const char *host = NULL;
        if (sf) host = (const char *)((name[11] == 'i')
                                          ? ((const char *(*)(uint32_t, uint32_t))sf)(a, b)
                                          : ((const char *(*)(uint32_t))sf)(a));
        uint32_t gva = 0;
        GLStringToGuest(vm, host ? host : "", &gva);
        ObserveGLString(name,a,b,host);
        GuestSetRet(vm, gva);
        return YES;


    }
    default:return NO;
    }
}

// Observe only arguments/results of existing calls. No extra GL query, readback,
// viewport change or framebuffer substitution. Bounded and default-off.
static void TraceExistingSurfaceCall(const char *name, int count,
                                     const uint64_t *integers, void *const *pointers) {
    if (!g_glSizeTrace) return;
    const int savedErrno = errno;
    char line[192];
    static unsigned viewportLines, renderbufferLines;
    if (!strcmp(name, "glViewport") && count == 4 && viewportLines < 8) {
        ++viewportLines;
        snprintf(line, sizeof(line), "[gl-size] viewport x=%d y=%d width=%d height=%d",
                 (int32_t)integers[0], (int32_t)integers[1],
                 (int32_t)integers[2], (int32_t)integers[3]);
        GuestRawLog(line);
    } else if ((!strcmp(name, "glGetRenderbufferParameterivOES") ||
                !strcmp(name, "glGetRenderbufferParameteriv")) &&
               count == 3 && pointers[2] && renderbufferLines < 16 &&
               (integers[1] == 0x8d42 || integers[1] == 0x8d43)) {
        ++renderbufferLines;
        int32_t value;
        memcpy(&value, pointers[2], sizeof(value));
        snprintf(line, sizeof(line), "[gl-size] %s target=%#x pname=%#x returned=%d",
                 name, (uint32_t)integers[0], (uint32_t)integers[1], value);
        GuestRawLog(line);
    }
    errno = savedErrno;
}

// --- dispatch ---------------------------------------------------------------
const GLRThunkRec *ThunkFor(const char *plain) {
    // Index zero is the generated sentinel; the last live entry is glViewport.
    for (unsigned i = 1; i <= kGLThunkCount; i++)
        if (!strcmp(kGLThunks[i].name, plain)) return &kGLThunks[i];
    return NULL;
}

void GLRealDispatch(GuestVM *vm,const char *symbol) {
    if(!symbol)return;
    const char *plain=symbol[0]=='_'?symbol+1:symbol;
    GLRealDispatchPrepared(vm,unsigned(as6_render_plan::find(plain)));
}

void GLRealDispatchPrepared(GuestVM *vm,std::uint32_t callID) {
    if(!callID||callID>=as6_render_plan::Count){GuestSetRet(vm,0);return;}
    const auto call=GLCall(callID);
    const auto *plan=as6_render_plan::get(call);
    if(!plan){GuestSetRet(vm,0);return;}
    GLRealSerialScope serial(vm);
    if(!serial.acquired)return;
    // Validate the generated table once under the existing serial gate.
    static const bool tableValid=[](){
        if(kGLThunkCount+1!=as6_render_plan::Count)return false;
        for(unsigned i=1;i<as6_render_plan::Count;++i)
            if(strcmp(kGLThunks[i].name,as6_render_plan::Plans[i].name)||
               strcmp(kGLThunks[i].sig,as6_render_plan::Plans[i].signature))return false;
        return true;
    }();
    if(!tableValid){GuestRequestFault(vm);return;}
    const auto *t=&kGLThunks[callID];
    const char *plain=plan->name;
    AS6MVPPulseThreadGate();
    GLClientArrayNoticeVAO(plain);
    void *fn=GLPreparedSymbol(call);
    GLTraceInitOnce();
    ArenaReset();
    g_vm = vm; g_ret = 0; g_haveRet = NO;
    Cursor c{vm, 0, 0};

    // Record overrides too: draw, texture uploads and buffer copies all use
    // hand-written marshalling and used to disappear from the renderer trace.
    auto &hits=g_preparedDrivers[callID].hits;
    if (hits < 3) {
        char line[192];
        snprintf(line, sizeof(line), "[gl] %s", plain);
        GuestRawLog(line);
    }
    hits++;
    if (g_glTraceAll && (strstr(plain, "Shader") || strstr(plain, "Program"))) {
        char line[192];
        snprintf(line, sizeof(line), "[gl] %-24s #%llu", plain, (unsigned long long)hits);
        GuestRawLog(line);
    }

    if (plan->custom && Override(vm,call,plain,&c,fn)) { FlushBack(vm); return; }
    if (!fn || !t->fn) { GLStateMipmapMissingDriver(plain); GuestSetRet(vm, 0); return; }

    const char retKind=plan->result;
    uint64_t I[12]{};float F[12]{};void *P[12]{};
    const int n=plan->count;
    for(int index=0;index<n;++index) {
        const auto &argument=plan->arguments[index];const char k=argument.kind;
        if(k=='f'){F[index]=c.NextFloat();}
        else if(k=='p'||k=='M'||k=='z') {
            const uint32_t gva=c.NextInt();size_t bytes=0;
            if(k=='z') {
                const size_t len=gva?GuestStrLen(vm,gva,4096):0;bytes=len+1;
                void *h=Arena(bytes);
                if(h){if(gva&&len)GuestRead(vm,gva,h,len);((char *)h)[len]='\0';}
                P[index]=h;
            } else {
                if(k=='p')bytes=argument.multiplier;
                else bytes=size_t(argument.source>=0&&argument.source<index?I[argument.source]:0)*argument.multiplier;
                P[index]=GuestToHost(vm,gva,bytes,YES);
            }
        } else {I[index]=c.NextInt();}
    }

    ((GLRThunkFn)(void *)t->fn)((GLRFn)fn, I, F, P);
    if(plan->mvp)AS6MVPPulseForwarded(plain,I,P);
    GLStateForwarded(plain,n,I,F,P);
    if(plan->observeResult)ObserveExistingGLResult(plain,n,I,P);
    FlushBack(vm);
    if(plan->traceSurface)TraceExistingSurfaceCall(plain,n,I,P);
    if (retKind == 's' || retKind == 'p') GuestSetRet(vm, 0);
    else GuestSetRet(vm, g_haveRet ? g_ret : 0);
}

// --- surface state exposed to the app host ----------------------------------
void *GLRealCurrentContext(void) { return NULL; }
BOOL GLRealHasSurface(void) { return NO; }
