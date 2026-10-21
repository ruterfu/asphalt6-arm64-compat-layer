// Generated prototypes from port/gen/gen_gl.py. Keep the Flash raster boundary
// below when regenerating: it maps only final viewport/scissor coordinates.
//
// Real OpenGL ES entry points for the original armv7 renderer.  Each thunk is
// generated from the prototype in the OpenGLES SDK headers, so the argument
// types the 2011 binary used are the argument types the arm64 driver receives.

#import "GLReal.h"
#include "GLCallPlan.hpp"
#import "HLE.h"
#import "GuestVM.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include "FlashRasterMapping.hpp"
#include <cerrno>
#include <cstdio>
#include <cstring>

namespace {
using as6_flash_raster::Rect;
using RasterFn = void (*)(int32_t, int32_t, int32_t, int32_t);
struct RasterRectState {
    RasterFn fn = nullptr;
    Rect actual{};
    bool known = false, mapped = false;
};
struct RasterState {
    GuestVM *__unsafe_unretained vm = nil;
    void *context = nullptr;
    uint32_t driver = 0, framebuffer = 0;
    bool needsSync = false, framebufferKnown = false;
    RasterRectState viewport{}, scissor{};
    as6_flash_raster::LogicalDomains domains{};
};
static thread_local RasterState g_flashRaster;
static thread_local GuestVM *__unsafe_unretained g_flashDispatchVM;

static void *FlashRasterCurrentContext(void) {
    // GLRealCurrentContext is a legacy NULL stub. Read EAGL's real thread-local
    // context identity without a GL state query or a context/binding change.
    static Class eagl = objc_lookUpClass("EAGLContext");
    static SEL selector = sel_registerName("currentContext");
    return eagl ? (__bridge void *)((id (*)(id, SEL))(void *)objc_msgSend)(eagl, selector) : nullptr;
}
static void FlashRasterContext(GuestVM *vm) {
    void *context = FlashRasterCurrentContext();
    if (g_flashRaster.vm != vm || g_flashRaster.context != context) {
        g_flashRaster = {};
        g_flashRaster.vm = vm;
        g_flashRaster.context = context;
    }
}
static bool FlashRasterTarget(as6_flash_raster::Target &target) {
    const bool valid = g_flashRaster.vm && g_flashRaster.context && g_flashRaster.driver &&
        as6_flash_raster::target([](uint32_t address, void *out, size_t size) {
            return bool(GuestRead(g_flashRaster.vm, address, out, size));
        }, g_flashRaster.driver, target);
    // Original offscreen bind routines 4f7800/4f78b0 and 504adc/504b8c
    // read target+24. Resource construction can temporarily bind a different
    // FBO while the guest RT stack still names the menu: exclude that domain.
    if (valid && target.menu && (!target.framebuffer || !g_flashRaster.framebufferKnown ||
                                target.framebuffer != g_flashRaster.framebuffer)) {
        target.menu = false;
        target.logicalViewport = false;
    }
    if (valid && target.menu) g_flashRaster.domains.resolve(target);
    return valid;
}
static void FlashRasterObserve(bool scissor, const as6_flash_raster::Target &target,
                               Rect source, Rect actual, const char *reason) {
    struct Seen { void *vm, *context; uint32_t target, texture, framebuffer, width, height; unsigned mask; };
    static thread_local Seen seen[32]{};
    static thread_local unsigned count = 0;
    unsigned index = 0;
    for (; index < count; ++index)
        if (seen[index].vm == (__bridge void *)g_flashRaster.vm && seen[index].context == g_flashRaster.context &&
            seen[index].target == target.current && seen[index].texture == target.texture &&
            seen[index].framebuffer == target.framebuffer && seen[index].width == target.logicalWidth &&
            seen[index].height == target.logicalHeight) break;
    if (index == count) {
        if (count == 32) return;
        seen[count++] = {(__bridge void *)g_flashRaster.vm, g_flashRaster.context, target.current,
                        target.texture, target.framebuffer, target.logicalWidth, target.logicalHeight, 0};
    }
    const unsigned bit = scissor ? 2u : 1u;
    if (seen[index].mask & bit) return;
    seen[index].mask |= bit;
    const int savedErrno = errno;
    char line[640];
    snprintf(line, sizeof(line),
        "[flash-raster] kind=%s reason=%s driver=%#x rt=%#x texture=%#x extent=4096x4096 independent=1 depth=%u logical_viewport=%d logical=%ux%u context=%p fbo=%u source=%d,%d,%d,%d actual=%d,%d,%d,%d",
        scissor ? "scissor" : "viewport", reason, g_flashRaster.driver, target.current,
        target.texture, target.depth, target.logicalViewport, target.logicalWidth, target.logicalHeight, g_flashRaster.context,
        g_flashRaster.framebuffer, source.x, source.y, source.width, source.height,
        actual.x, actual.y, actual.width, actual.height);
    GuestRawLog(line);
    errno = savedErrno;
}
static void FlashRasterForward(bool scissor, GLRFn fn, const uint64_t *I) {
    const Rect source{int32_t(I[0]), int32_t(I[1]), int32_t(I[2]), int32_t(I[3])};
    Rect actual = source;
    bool mapped = false;
    if (g_flashDispatchVM) {
        FlashRasterContext(g_flashDispatchVM);
        const int reg = as6_flash_raster::driverRegister(scissor, GuestLR(g_flashDispatchVM));
        // Unknown callers keep their original GL arguments and cannot establish
        // a driver identity for the cache-hit repair before a later draw.
        g_flashRaster.driver = reg < 0 ? 0 : GuestReg(g_flashDispatchVM, reg);
        as6_flash_raster::Target target;
        if (FlashRasterTarget(target)) {
            mapped = as6_flash_raster::mappedRect(scissor, target, source, actual);
            if (mapped) FlashRasterObserve(scissor, target, source, actual, "original-call");
        }
    }
    auto &state = scissor ? g_flashRaster.scissor : g_flashRaster.viewport;
    state = {reinterpret_cast<RasterFn>(fn), actual, true, mapped};
    g_flashRaster.needsSync = true;
    state.fn(actual.x, actual.y, actual.width, actual.height);
}
static void FlashRasterBeforeDraw(GuestVM *vm) {
    FlashRasterContext(vm);
    if (!g_flashRaster.needsSync) return;
    as6_flash_raster::Target target;
    if (!FlashRasterTarget(target)) return;
    for (unsigned i = 0; i < 2; ++i) {
        const bool scissor = i != 0;
        auto &state = scissor ? g_flashRaster.scissor : g_flashRaster.viewport;
        if (!state.fn || !state.known || (!target.menu && !state.mapped)) continue;
        Rect source, actual;
        if (!as6_flash_raster::cachedRect([](uint32_t address, void *out, size_t size) {
                return bool(GuestRead(g_flashRaster.vm, address, out, size));
            }, g_flashRaster.driver, scissor, target, source)) continue;
        const bool mapped = as6_flash_raster::mappedRect(scissor, target, source, actual);
        if (!as6_flash_raster::equal(state.actual, actual)) {
            state.fn(actual.x, actual.y, actual.width, actual.height);
            state.actual = actual;
            if (mapped) FlashRasterObserve(scissor, target, source, actual, "cache-domain-change");
        }
        state.mapped = mapped;
    }
    g_flashRaster.needsSync = false;
}
static void FlashRasterFramebuffer(uint32_t target, uint32_t framebuffer) {
    if (!g_flashDispatchVM) return;
    FlashRasterContext(g_flashDispatchVM);
    g_flashRaster.framebuffer = framebuffer;
    g_flashRaster.framebufferKnown = target == 0x8d40u; // Original GL_FRAMEBUFFER binding.
    // RT binds and explicit raster calls are the only coordinate-domain
    // transitions. A settled draw adds no guest-memory walk or GL query.
    g_flashRaster.needsSync = true;
}
static void FlashRasterFramebufferLifetime(uint32_t count, const void *names, bool deleted) {
    if (!g_flashDispatchVM || !names || int32_t(count) <= 0) return;
    FlashRasterContext(g_flashDispatchVM);
    const auto *framebuffers = static_cast<const uint32_t *>(names);
    for (uint32_t i = 0; i < count; ++i) {
        g_flashRaster.domains.forgetFramebuffer(framebuffers[i]);
        if (deleted && g_flashRaster.framebufferKnown && g_flashRaster.framebuffer == framebuffers[i])
            g_flashRaster.framebuffer = 0; // GL deletion also unbinds the current FBO.
    }
    g_flashRaster.needsSync = true;
}
static void FlashRasterFramebufferStatus(uint32_t target, uint32_t status) {
    // Record only the original query's existing return. No glGetError, extra
    // framebuffer query, binding change or readback is introduced.
    static thread_local unsigned completeLines = 0, failureLines = 0;
    unsigned &lines = status == 0x8cd5u ? completeLines : failureLines;
    if (lines >= (status == 0x8cd5u ? 48u : 16u)) return;
    ++lines;
    const int savedErrno = errno;
    char line[224];
    snprintf(line, sizeof(line), "[flash-raster-fbo] context=%p fbo=%u query_target=%#x status=%#x complete=%d",
        FlashRasterCurrentContext(), g_flashRaster.framebuffer, target, status, status == 0x8cd5u);
    GuestRawLog(line);
    errno = savedErrno;
}
} // namespace

static void t_glActiveTexture(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0]);
}

static void t_glAlphaFunc(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, float);
    ((_F)(void *)fn)((uint32_t)I[0], F[1]);
}

static void t_glAttachShader(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1]);
}

static void t_glBindFramebuffer(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1]);
    FlashRasterFramebuffer(uint32_t(I[0]), uint32_t(I[1]));
}

static void t_glBindFramebufferOES(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t, uint32_t);
    GLSetRetU32(((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1]));
    FlashRasterFramebuffer(uint32_t(I[0]), uint32_t(I[1]));
}

static void t_glBindRenderbuffer(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1]);
}

static void t_glBindRenderbufferOES(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t, uint32_t);
    GLSetRetU32(((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1]));
}

static void t_glBindTexture(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1]);
}

static void t_glBlendColor(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(float, float, float, float);
    ((_F)(void *)fn)(F[0], F[1], F[2], F[3]);
}

static void t_glBlendEquation(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0]);
}

static void t_glBlendEquationOES(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t);
    GLSetRetU32(((_F)(void *)fn)((uint32_t)I[0]));
}

static void t_glBlendFunc(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1]);
}

static void t_glBufferData(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, void *, uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], P[2], (uint32_t)I[3]);
}

static void t_glBufferSubData(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2], P[3]);
}

static void t_glCheckFramebufferStatus(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t);
    const uint32_t status = ((_F)(void *)fn)((uint32_t)I[0]);
    GLSetRetU32(status);
    FlashRasterFramebufferStatus(uint32_t(I[0]), status);
}

static void t_glCheckFramebufferStatusOES(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t);
    const uint32_t status = ((_F)(void *)fn)((uint32_t)I[0]);
    GLSetRetU32(status);
    FlashRasterFramebufferStatus(uint32_t(I[0]), status);
}

static void t_glClear(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    GLRealHostCall([&]{((_F)(void *)fn)((uint32_t)I[0]);});
}

static void t_glClearColor(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(float, float, float, float);
    ((_F)(void *)fn)(F[0], F[1], F[2], F[3]);
}

static void t_glClearDepthf(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(float);
    ((_F)(void *)fn)(F[0]);
}

static void t_glClearStencil(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0]);
}

static void t_glClientActiveTexture(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0]);
}

static void t_glClipPlanef(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], P[1]);
}

static void t_glColor4f(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(float, float, float, float);
    ((_F)(void *)fn)(F[0], F[1], F[2], F[3]);
}

static void t_glColor4ub(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, uint32_t, uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2], (uint32_t)I[3]);
}

static void t_glColorMask(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, uint32_t, uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2], (uint32_t)I[3]);
}

static void t_glCompileShader(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    GLRealHostCall([&]{((_F)(void *)fn)((uint32_t)I[0]);});
}

static void t_glCompressedTexImage2D(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, void *);
    GLRealHostCall([&]{((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2], (uint32_t)I[3], (uint32_t)I[4], (uint32_t)I[5], (uint32_t)I[6], P[7]);});
}

static void t_glCompressedTexSubImage2D(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, void *);
    GLRealHostCall([&]{((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2], (uint32_t)I[3], (uint32_t)I[4], (uint32_t)I[5], (uint32_t)I[6], (uint32_t)I[7], P[8]);});
}

static void t_glCopyTexImage2D(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t);
    GLRealHostCall([&]{((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2], (uint32_t)I[3], (uint32_t)I[4], (uint32_t)I[5], (uint32_t)I[6], (uint32_t)I[7]);});
}

static void t_glCopyTexSubImage2D(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t);
    GLRealHostCall([&]{((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2], (uint32_t)I[3], (uint32_t)I[4], (uint32_t)I[5], (uint32_t)I[6], (uint32_t)I[7]);});
}

static void t_glCreateProgram(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(void);
    GLSetRetU32(((_F)(void *)fn)());
}

static void t_glCreateShader(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t);
    GLSetRetU32(((_F)(void *)fn)((uint32_t)I[0]));
}

static void t_glCullFace(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0]);
}

static void t_glDeleteBuffers(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], P[1]);
}

static void t_glDeleteFramebuffers(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, void *);
    GLRealHostCall([&]{((_F)(void *)fn)((uint32_t)I[0], P[1]);});
    FlashRasterFramebufferLifetime(uint32_t(I[0]), P[1], true);
}

static void t_glDeleteFramebuffersOES(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t, void *);
    uint32_t result=0;
    GLRealHostCall([&]{result=((_F)(void *)fn)((uint32_t)I[0], P[1]);});
    GLSetRetU32(result);
    FlashRasterFramebufferLifetime(uint32_t(I[0]), P[1], true);
}

static void t_glDeleteProgram(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0]);
}

static void t_glDeleteRenderbuffers(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, void *);
    GLRealHostCall([&]{((_F)(void *)fn)((uint32_t)I[0], P[1]);});
}

static void t_glDeleteRenderbuffersOES(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t, void *);
    uint32_t result=0;
    GLRealHostCall([&]{result=((_F)(void *)fn)((uint32_t)I[0], P[1]);});
    GLSetRetU32(result);
}

static void t_glDeleteShader(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0]);
}

static void t_glDeleteTextures(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, void *);
    GLRealHostCall([&]{((_F)(void *)fn)((uint32_t)I[0], P[1]);});
}

static void t_glDepthFunc(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0]);
}

static void t_glDepthMask(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0]);
}

static void t_glDepthRangef(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(float, float);
    ((_F)(void *)fn)(F[0], F[1]);
}

static void t_glDisable(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0]);
}

static void t_glDisableVertexAttribArray(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0]);
}

static void t_glDiscardFramebufferEXT(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t, uint32_t, void *);
    GLSetRetU32(((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], P[2]));
}

static void t_glEnable(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0]);
}

static void t_glEnableVertexAttribArray(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0]);
}

static void t_glFlush(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(void);
    GLRealHostCall([&]{((_F)(void *)fn)();});
}

static void t_glFogf(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, float);
    ((_F)(void *)fn)((uint32_t)I[0], F[1]);
}

static void t_glFogfv(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], P[1]);
}

static void t_glFramebufferRenderbuffer(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, uint32_t, uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2], (uint32_t)I[3]);
}

static void t_glFramebufferRenderbufferOES(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t, uint32_t, uint32_t, uint32_t);
    GLSetRetU32(((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2], (uint32_t)I[3]));
}

static void t_glFramebufferTexture2D(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2], (uint32_t)I[3], (uint32_t)I[4]);
}

static void t_glFramebufferTexture2DOES(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t);
    GLSetRetU32(((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2], (uint32_t)I[3], (uint32_t)I[4]));
}

static void t_glFrontFace(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0]);
}

static void t_glGenBuffers(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], P[1]);
}

static void t_glGenFramebuffers(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], P[1]);
    FlashRasterFramebufferLifetime(uint32_t(I[0]), P[1], false);
}

static void t_glGenFramebuffersOES(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t, void *);
    GLSetRetU32(((_F)(void *)fn)((uint32_t)I[0], P[1]));
    FlashRasterFramebufferLifetime(uint32_t(I[0]), P[1], false);
}

static void t_glGenRenderbuffers(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], P[1]);
}

static void t_glGenRenderbuffersOES(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t, void *);
    GLSetRetU32(((_F)(void *)fn)((uint32_t)I[0], P[1]));
}

static void t_glGenTextures(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], P[1]);
}

static void t_glGenerateMipmap(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    GLRealHostCall([&]{((_F)(void *)fn)((uint32_t)I[0]);});
}

static void t_glGenerateMipmapOES(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t);
    uint32_t result=0;
    GLRealHostCall([&]{result=((_F)(void *)fn)((uint32_t)I[0]);});
    GLSetRetU32(result);
}

static void t_glGetActiveAttrib(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, uint32_t, void *, void *, void *, void *);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2], P[3], P[4], P[5], P[6]);
}

static void t_glGetActiveUniform(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, uint32_t, void *, void *, void *, void *);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2], P[3], P[4], P[5], P[6]);
}

static void t_glGetAttribLocation(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t, void *);
    GLSetRetU32(((_F)(void *)fn)((uint32_t)I[0], P[1]));
}

static void t_glGetError(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(void);
    GLSetRetU32(((_F)(void *)fn)());
}

static void t_glGetFloatv(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], P[1]);
}

static void t_glGetIntegerv(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], P[1]);
}

static void t_glGetProgramInfoLog(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, void *, void *);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], P[2], P[3]);
}

static void t_glGetProgramiv(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], P[2]);
}

static void t_glGetRenderbufferParameterivOES(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t, uint32_t, void *);
    GLSetRetU32(((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], P[2]));
}

static void t_glGetShaderInfoLog(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, void *, void *);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], P[2], P[3]);
}

static void t_glGetShaderiv(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], P[2]);
}

static void t_glGetUniformLocation(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t, void *);
    GLSetRetU32(((_F)(void *)fn)((uint32_t)I[0], P[1]));
}

static void t_glHint(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1]);
}

static void t_glIsFramebuffer(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t);
    GLSetRetU32(((_F)(void *)fn)((uint32_t)I[0]));
}

static void t_glIsFramebufferOES(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t);
    GLSetRetU32(((_F)(void *)fn)((uint32_t)I[0]));
}

static void t_glIsRenderbuffer(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t);
    GLSetRetU32(((_F)(void *)fn)((uint32_t)I[0]));
}

static void t_glIsRenderbufferOES(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t);
    GLSetRetU32(((_F)(void *)fn)((uint32_t)I[0]));
}

static void t_glIsTexture(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t);
    GLSetRetU32(((_F)(void *)fn)((uint32_t)I[0]));
}

static void t_glLightModelf(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, float);
    ((_F)(void *)fn)((uint32_t)I[0], F[1]);
}

static void t_glLightModelfv(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], P[1]);
}

static void t_glLightf(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, float);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], F[2]);
}

static void t_glLightfv(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], P[2]);
}

static void t_glLineWidth(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(float);
    ((_F)(void *)fn)(F[0]);
}

static void t_glLinkProgram(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    GLRealHostCall([&]{((_F)(void *)fn)((uint32_t)I[0]);});
}

static void t_glLoadIdentity(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(void);
    ((_F)(void *)fn)();
}

static void t_glLoadMatrixf(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(void *);
    ((_F)(void *)fn)(P[0]);
}

static void t_glMaterialf(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, float);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], F[2]);
}

static void t_glMaterialfv(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], P[2]);
}

static void t_glMatrixMode(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0]);
}

static void t_glMultMatrixf(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(void *);
    ((_F)(void *)fn)(P[0]);
}

static void t_glMultiTexCoord4f(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, float, float, float, float);
    ((_F)(void *)fn)((uint32_t)I[0], F[1], F[2], F[3], F[4]);
}

static void t_glNormal3f(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(float, float, float);
    ((_F)(void *)fn)(F[0], F[1], F[2]);
}

static void t_glPixelStorei(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1]);
}

static void t_glPointParameterf(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, float);
    ((_F)(void *)fn)((uint32_t)I[0], F[1]);
}

static void t_glPointParameterfv(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], P[1]);
}

static void t_glPointSize(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(float);
    ((_F)(void *)fn)(F[0]);
}

static void t_glPolygonOffset(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(float, float);
    ((_F)(void *)fn)(F[0], F[1]);
}

static void t_glPopMatrix(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(void);
    ((_F)(void *)fn)();
}

static void t_glPushMatrix(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(void);
    ((_F)(void *)fn)();
}

static void t_glRenderbufferStorage(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, uint32_t, uint32_t);
    GLRealHostCall([&]{((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2], (uint32_t)I[3]);});
}

static void t_glRenderbufferStorageMultisampleAPPLE(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t);
    uint32_t result=0;
    GLRealHostCall([&]{result=((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2], (uint32_t)I[3], (uint32_t)I[4]);});
    GLSetRetU32(result);
}

static void t_glRenderbufferStorageOES(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(uint32_t, uint32_t, uint32_t, uint32_t);
    uint32_t result=0;
    GLRealHostCall([&]{result=((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2], (uint32_t)I[3]);});
    GLSetRetU32(result);
}

static void t_glResolveMultisampleFramebufferAPPLE(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef uint32_t (*_F)(void);
    GLSetRetU32(((_F)(void *)fn)());
}

static void t_glSampleCoverage(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(float, uint32_t);
    ((_F)(void *)fn)(F[0], (uint32_t)I[1]);
}

static void t_glScissor(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    FlashRasterForward(true, fn, I);
}

static void t_glShadeModel(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0]);
}

static void t_glStencilFunc(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2]);
}

static void t_glStencilMask(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0]);
}

static void t_glStencilOp(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2]);
}

static void t_glTexEnvf(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, float);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], F[2]);
}

static void t_glTexEnvfv(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], P[2]);
}

static void t_glTexEnvi(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2]);
}

static void t_glTexParameterf(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, float);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], F[2]);
}

static void t_glTexParameteri(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2]);
}

static void t_glUniform1f(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, float);
    ((_F)(void *)fn)((uint32_t)I[0], F[1]);
}

static void t_glUniform1fv(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], P[2]);
}

static void t_glUniform1i(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1]);
}

static void t_glUniform1iv(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], P[2]);
}

static void t_glUniform2fv(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], P[2]);
}

static void t_glUniform2iv(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], P[2]);
}

static void t_glUniform3fv(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], P[2]);
}

static void t_glUniform3iv(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], P[2]);
}

static void t_glUniform4fv(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], P[2]);
}

static void t_glUniform4iv(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], P[2]);
}

static void t_glUniformMatrix4fv(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, uint32_t, uint32_t, void *);
    ((_F)(void *)fn)((uint32_t)I[0], (uint32_t)I[1], (uint32_t)I[2], P[3]);
}

static void t_glUseProgram(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t);
    ((_F)(void *)fn)((uint32_t)I[0]);
}

static void t_glVertexAttrib4f(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    typedef void (*_F)(uint32_t, float, float, float, float);
    ((_F)(void *)fn)((uint32_t)I[0], F[1], F[2], F[3], F[4]);
}

static void t_glViewport(GLRFn fn, const uint64_t *I, const float *F, void *const *P) {
    FlashRasterForward(false, fn, I);
}

const GLRThunkRec kGLThunks[] = {
    {"", "", NULL},
    {"glActiveTexture", "v:i", t_glActiveTexture},
    {"glAlphaFunc", "v:i,f", t_glAlphaFunc},
    {"glAttachShader", "v:i,i", t_glAttachShader},
    {"glBindBuffer", "ov", NULL},
    {"glBindFramebuffer", "v:i,i", t_glBindFramebuffer},
    {"glBindFramebufferOES", "i:i,i", t_glBindFramebufferOES},
    {"glBindRenderbuffer", "v:i,i", t_glBindRenderbuffer},
    {"glBindRenderbufferOES", "i:i,i", t_glBindRenderbufferOES},
    {"glBindTexture", "v:i,i", t_glBindTexture},
    {"glBlendColor", "v:f,f,f,f", t_glBlendColor},
    {"glBlendEquation", "v:i", t_glBlendEquation},
    {"glBlendEquationOES", "i:i", t_glBlendEquationOES},
    {"glBlendFunc", "v:i,i", t_glBlendFunc},
    {"glBufferData", "v:i,i,M1:1,i", t_glBufferData},
    {"glBufferSubData", "v:i,i,i,M2:1", t_glBufferSubData},
    {"glCheckFramebufferStatus", "i:i", t_glCheckFramebufferStatus},
    {"glCheckFramebufferStatusOES", "i:i", t_glCheckFramebufferStatusOES},
    {"glClear", "v:i", t_glClear},
    {"glClearColor", "v:f,f,f,f", t_glClearColor},
    {"glClearDepthf", "v:f", t_glClearDepthf},
    {"glClearStencil", "v:i", t_glClearStencil},
    {"glClientActiveTexture", "v:i", t_glClientActiveTexture},
    {"glClipPlanef", "v:i,p16", t_glClipPlanef},
    {"glColor4f", "v:f,f,f,f", t_glColor4f},
    {"glColor4ub", "v:i,i,i,i", t_glColor4ub},
    {"glColorMask", "v:i,i,i,i", t_glColorMask},
    {"glColorPointer", "ov", NULL},
    {"glCompileShader", "v:i", t_glCompileShader},
    {"glCompressedTexImage2D", "v:i,i,i,i,i,i,i,M6:1", t_glCompressedTexImage2D},
    {"glCompressedTexSubImage2D", "v:i,i,i,i,i,i,i,i,M7:1", t_glCompressedTexSubImage2D},
    {"glCopyTexImage2D", "v:i,i,i,i,i,i,i,i", t_glCopyTexImage2D},
    {"glCopyTexSubImage2D", "v:i,i,i,i,i,i,i,i", t_glCopyTexSubImage2D},
    {"glCreateProgram", "i", t_glCreateProgram},
    {"glCreateShader", "i:i", t_glCreateShader},
    {"glCullFace", "v:i", t_glCullFace},
    {"glDeleteBuffers", "v:i,M0:4", t_glDeleteBuffers},
    {"glDeleteFramebuffers", "v:i,M0:4", t_glDeleteFramebuffers},
    {"glDeleteFramebuffersOES", "i:i,M0:4", t_glDeleteFramebuffersOES},
    {"glDeleteProgram", "v:i", t_glDeleteProgram},
    {"glDeleteRenderbuffers", "v:i,M0:4", t_glDeleteRenderbuffers},
    {"glDeleteRenderbuffersOES", "i:i,M0:4", t_glDeleteRenderbuffersOES},
    {"glDeleteShader", "v:i", t_glDeleteShader},
    {"glDeleteTextures", "v:i,M0:4", t_glDeleteTextures},
    {"glDepthFunc", "v:i", t_glDepthFunc},
    {"glDepthMask", "v:i", t_glDepthMask},
    {"glDepthRangef", "v:f,f", t_glDepthRangef},
    {"glDisable", "v:i", t_glDisable},
    {"glDisableClientState", "ov", NULL},
    {"glDisableVertexAttribArray", "v:i", t_glDisableVertexAttribArray},
    {"glDiscardFramebufferEXT", "i:i,i,M1:4", t_glDiscardFramebufferEXT},
    {"glDrawArrays", "ov", NULL},
    {"glDrawElements", "ov", NULL},
    {"glEnable", "v:i", t_glEnable},
    {"glEnableClientState", "ov", NULL},
    {"glEnableVertexAttribArray", "v:i", t_glEnableVertexAttribArray},
    {"glFlush", "v", t_glFlush},
    {"glFogf", "v:i,f", t_glFogf},
    {"glFogfv", "v:i,p16", t_glFogfv},
    {"glFramebufferRenderbuffer", "v:i,i,i,i", t_glFramebufferRenderbuffer},
    {"glFramebufferRenderbufferOES", "i:i,i,i,i", t_glFramebufferRenderbufferOES},
    {"glFramebufferTexture2D", "v:i,i,i,i,i", t_glFramebufferTexture2D},
    {"glFramebufferTexture2DOES", "i:i,i,i,i,i", t_glFramebufferTexture2DOES},
    {"glFrontFace", "v:i", t_glFrontFace},
    {"glGenBuffers", "v:i,M0:4", t_glGenBuffers},
    {"glGenFramebuffers", "v:i,M0:4", t_glGenFramebuffers},
    {"glGenFramebuffersOES", "i:i,M0:4", t_glGenFramebuffersOES},
    {"glGenRenderbuffers", "v:i,M0:4", t_glGenRenderbuffers},
    {"glGenRenderbuffersOES", "i:i,M0:4", t_glGenRenderbuffersOES},
    {"glGenTextures", "v:i,M0:4", t_glGenTextures},
    {"glGenerateMipmap", "v:i", t_glGenerateMipmap},
    {"glGenerateMipmapOES", "i:i", t_glGenerateMipmapOES},
    {"glGetActiveAttrib", "v:i,i,i,p4,p4,p4,M2:1", t_glGetActiveAttrib},
    {"glGetActiveUniform", "v:i,i,i,p4,p4,p4,M2:1", t_glGetActiveUniform},
    {"glGetAttribLocation", "i:i,z", t_glGetAttribLocation},
    {"glGetError", "i", t_glGetError},
    {"glGetFloatv", "v:i,p64", t_glGetFloatv},
    {"glGetIntegerv", "v:i,p64", t_glGetIntegerv},
    {"glGetProgramInfoLog", "v:i,i,p4,M1:1", t_glGetProgramInfoLog},
    {"glGetProgramiv", "v:i,i,p16", t_glGetProgramiv},
    {"glGetRenderbufferParameterivOES", "i:i,i,p16", t_glGetRenderbufferParameterivOES},
    {"glGetShaderInfoLog", "v:i,i,p4,M1:1", t_glGetShaderInfoLog},
    {"glGetShaderiv", "v:i,i,p16", t_glGetShaderiv},
    {"glGetString", "ov", NULL},
    {"glGetStringi", "ov", NULL},
    {"glGetUniformLocation", "i:i,z", t_glGetUniformLocation},
    {"glHint", "v:i,i", t_glHint},
    {"glIsFramebuffer", "i:i", t_glIsFramebuffer},
    {"glIsFramebufferOES", "i:i", t_glIsFramebufferOES},
    {"glIsRenderbuffer", "i:i", t_glIsRenderbuffer},
    {"glIsRenderbufferOES", "i:i", t_glIsRenderbufferOES},
    {"glIsTexture", "i:i", t_glIsTexture},
    {"glLightModelf", "v:i,f", t_glLightModelf},
    {"glLightModelfv", "v:i,p16", t_glLightModelfv},
    {"glLightf", "v:i,i,f", t_glLightf},
    {"glLightfv", "v:i,i,p64", t_glLightfv},
    {"glLineWidth", "v:f", t_glLineWidth},
    {"glLinkProgram", "v:i", t_glLinkProgram},
    {"glLoadIdentity", "v", t_glLoadIdentity},
    {"glLoadMatrixf", "v:p64", t_glLoadMatrixf},
    {"glMapBufferOES", "ov", NULL},
    {"glMaterialf", "v:i,i,f", t_glMaterialf},
    {"glMaterialfv", "v:i,i,p64", t_glMaterialfv},
    {"glMatrixMode", "v:i", t_glMatrixMode},
    {"glMultMatrixf", "v:p64", t_glMultMatrixf},
    {"glMultiTexCoord4f", "v:i,f,f,f,f", t_glMultiTexCoord4f},
    {"glNormal3f", "v:f,f,f", t_glNormal3f},
    {"glNormalPointer", "ov", NULL},
    {"glPixelStorei", "v:i,i", t_glPixelStorei},
    {"glPointParameterf", "v:i,f", t_glPointParameterf},
    {"glPointParameterfv", "v:i,p16", t_glPointParameterfv},
    {"glPointSize", "v:f", t_glPointSize},
    {"glPolygonOffset", "v:f,f", t_glPolygonOffset},
    {"glPopMatrix", "v", t_glPopMatrix},
    {"glPushMatrix", "v", t_glPushMatrix},
    {"glReadPixels", "ov", NULL},
    {"glRenderbufferStorage", "v:i,i,i,i", t_glRenderbufferStorage},
    {"glRenderbufferStorageMultisampleAPPLE", "i:i,i,i,i,i", t_glRenderbufferStorageMultisampleAPPLE},
    {"glRenderbufferStorageOES", "i:i,i,i,i", t_glRenderbufferStorageOES},
    {"glResolveMultisampleFramebufferAPPLE", "i", t_glResolveMultisampleFramebufferAPPLE},
    {"glSampleCoverage", "v:f,i", t_glSampleCoverage},
    {"glScissor", "v:i,i,i,i", t_glScissor},
    {"glShadeModel", "v:i", t_glShadeModel},
    {"glShaderSource", "ov", NULL},
    {"glStencilFunc", "v:i,i,i", t_glStencilFunc},
    {"glStencilMask", "v:i", t_glStencilMask},
    {"glStencilOp", "v:i,i,i", t_glStencilOp},
    {"glTexCoordPointer", "ov", NULL},
    {"glTexEnvf", "v:i,i,f", t_glTexEnvf},
    {"glTexEnvfv", "v:i,i,p16", t_glTexEnvfv},
    {"glTexEnvi", "v:i,i,i", t_glTexEnvi},
    {"glTexImage2D", "ov", NULL},
    {"glTexParameterf", "v:i,i,f", t_glTexParameterf},
    {"glTexParameteri", "v:i,i,i", t_glTexParameteri},
    {"glTexSubImage2D", "ov", NULL},
    {"glUniform1f", "v:i,f", t_glUniform1f},
    {"glUniform1fv", "v:i,i,M1:4", t_glUniform1fv},
    {"glUniform1i", "v:i,i", t_glUniform1i},
    {"glUniform1iv", "v:i,i,M1:4", t_glUniform1iv},
    {"glUniform2fv", "v:i,i,M1:8", t_glUniform2fv},
    {"glUniform2iv", "v:i,i,M1:8", t_glUniform2iv},
    {"glUniform3fv", "v:i,i,M1:12", t_glUniform3fv},
    {"glUniform3iv", "v:i,i,M1:12", t_glUniform3iv},
    {"glUniform4fv", "v:i,i,M1:16", t_glUniform4fv},
    {"glUniform4iv", "v:i,i,M1:16", t_glUniform4iv},
    {"glUniformMatrix4fv", "v:i,i,i,M1:64", t_glUniformMatrix4fv},
    {"glUnmapBufferOES", "ov", NULL},
    {"glUseProgram", "v:i", t_glUseProgram},
    {"glVertexAttrib4f", "v:i,f,f,f,f", t_glVertexAttrib4f},
    {"glVertexAttribPointer", "ov", NULL},
    {"glVertexPointer", "ov", NULL},
    {"glViewport", "v:i,i,i,i", t_glViewport},
};
const unsigned kGLThunkCount = sizeof(kGLThunks) / sizeof(kGLThunks[0]) - 1;

static void ForwardPreparedGL(GuestVM *vm,as6_render_plan::Call call) {
    if(!GLRealBeginSerialCall(vm))return;
    @try {
        if(call==as6_render_plan::Call::glDrawArrays||call==as6_render_plan::Call::glDrawElements||
           call==as6_render_plan::Call::glClear)FlashRasterBeforeDraw(vm);
        GuestVM *__unsafe_unretained previousVM = g_flashDispatchVM;
        g_flashDispatchVM = vm;
        @try {GLRealDispatchPrepared(vm,unsigned(call));}
        @finally {g_flashDispatchVM = previousVM;}
    } @finally {GLRealEndSerialCall(vm);}
}

HLE_DEFINE(hle_prepared_glActiveTexture) { ForwardPreparedGL(vm,as6_render_plan::Call::glActiveTexture); }
HLE_BIND("_glActiveTexture", hle_prepared_glActiveTexture)
HLE_DEFINE(hle_prepared_glAlphaFunc) { ForwardPreparedGL(vm,as6_render_plan::Call::glAlphaFunc); }
HLE_BIND("_glAlphaFunc", hle_prepared_glAlphaFunc)
HLE_DEFINE(hle_prepared_glAttachShader) { ForwardPreparedGL(vm,as6_render_plan::Call::glAttachShader); }
HLE_BIND("_glAttachShader", hle_prepared_glAttachShader)
HLE_DEFINE(hle_prepared_glBindBuffer) { ForwardPreparedGL(vm,as6_render_plan::Call::glBindBuffer); }
HLE_BIND("_glBindBuffer", hle_prepared_glBindBuffer)
HLE_DEFINE(hle_prepared_glBindFramebuffer) { ForwardPreparedGL(vm,as6_render_plan::Call::glBindFramebuffer); }
HLE_BIND("_glBindFramebuffer", hle_prepared_glBindFramebuffer)
HLE_DEFINE(hle_prepared_glBindFramebufferOES) { ForwardPreparedGL(vm,as6_render_plan::Call::glBindFramebufferOES); }
HLE_BIND("_glBindFramebufferOES", hle_prepared_glBindFramebufferOES)
HLE_DEFINE(hle_prepared_glBindRenderbuffer) { ForwardPreparedGL(vm,as6_render_plan::Call::glBindRenderbuffer); }
HLE_BIND("_glBindRenderbuffer", hle_prepared_glBindRenderbuffer)
HLE_DEFINE(hle_prepared_glBindRenderbufferOES) { ForwardPreparedGL(vm,as6_render_plan::Call::glBindRenderbufferOES); }
HLE_BIND("_glBindRenderbufferOES", hle_prepared_glBindRenderbufferOES)
HLE_DEFINE(hle_prepared_glBindTexture) { ForwardPreparedGL(vm,as6_render_plan::Call::glBindTexture); }
HLE_BIND("_glBindTexture", hle_prepared_glBindTexture)
HLE_DEFINE(hle_prepared_glBlendColor) { ForwardPreparedGL(vm,as6_render_plan::Call::glBlendColor); }
HLE_BIND("_glBlendColor", hle_prepared_glBlendColor)
HLE_DEFINE(hle_prepared_glBlendEquation) { ForwardPreparedGL(vm,as6_render_plan::Call::glBlendEquation); }
HLE_BIND("_glBlendEquation", hle_prepared_glBlendEquation)
HLE_DEFINE(hle_prepared_glBlendEquationOES) { ForwardPreparedGL(vm,as6_render_plan::Call::glBlendEquationOES); }
HLE_BIND("_glBlendEquationOES", hle_prepared_glBlendEquationOES)
HLE_DEFINE(hle_prepared_glBlendFunc) { ForwardPreparedGL(vm,as6_render_plan::Call::glBlendFunc); }
HLE_BIND("_glBlendFunc", hle_prepared_glBlendFunc)
HLE_DEFINE(hle_prepared_glBufferData) { ForwardPreparedGL(vm,as6_render_plan::Call::glBufferData); }
HLE_BIND("_glBufferData", hle_prepared_glBufferData)
HLE_DEFINE(hle_prepared_glBufferSubData) { ForwardPreparedGL(vm,as6_render_plan::Call::glBufferSubData); }
HLE_BIND("_glBufferSubData", hle_prepared_glBufferSubData)
HLE_DEFINE(hle_prepared_glCheckFramebufferStatus) { ForwardPreparedGL(vm,as6_render_plan::Call::glCheckFramebufferStatus); }
HLE_BIND("_glCheckFramebufferStatus", hle_prepared_glCheckFramebufferStatus)
HLE_DEFINE(hle_prepared_glCheckFramebufferStatusOES) { ForwardPreparedGL(vm,as6_render_plan::Call::glCheckFramebufferStatusOES); }
HLE_BIND("_glCheckFramebufferStatusOES", hle_prepared_glCheckFramebufferStatusOES)
HLE_DEFINE(hle_prepared_glClear) { ForwardPreparedGL(vm,as6_render_plan::Call::glClear); }
HLE_BIND("_glClear", hle_prepared_glClear)
HLE_DEFINE(hle_prepared_glClearColor) { ForwardPreparedGL(vm,as6_render_plan::Call::glClearColor); }
HLE_BIND("_glClearColor", hle_prepared_glClearColor)
HLE_DEFINE(hle_prepared_glClearDepthf) { ForwardPreparedGL(vm,as6_render_plan::Call::glClearDepthf); }
HLE_BIND("_glClearDepthf", hle_prepared_glClearDepthf)
HLE_DEFINE(hle_prepared_glClearStencil) { ForwardPreparedGL(vm,as6_render_plan::Call::glClearStencil); }
HLE_BIND("_glClearStencil", hle_prepared_glClearStencil)
HLE_DEFINE(hle_prepared_glClientActiveTexture) { ForwardPreparedGL(vm,as6_render_plan::Call::glClientActiveTexture); }
HLE_BIND("_glClientActiveTexture", hle_prepared_glClientActiveTexture)
HLE_DEFINE(hle_prepared_glClipPlanef) { ForwardPreparedGL(vm,as6_render_plan::Call::glClipPlanef); }
HLE_BIND("_glClipPlanef", hle_prepared_glClipPlanef)
HLE_DEFINE(hle_prepared_glColor4f) { ForwardPreparedGL(vm,as6_render_plan::Call::glColor4f); }
HLE_BIND("_glColor4f", hle_prepared_glColor4f)
HLE_DEFINE(hle_prepared_glColor4ub) { ForwardPreparedGL(vm,as6_render_plan::Call::glColor4ub); }
HLE_BIND("_glColor4ub", hle_prepared_glColor4ub)
HLE_DEFINE(hle_prepared_glColorMask) { ForwardPreparedGL(vm,as6_render_plan::Call::glColorMask); }
HLE_BIND("_glColorMask", hle_prepared_glColorMask)
HLE_DEFINE(hle_prepared_glColorPointer) { ForwardPreparedGL(vm,as6_render_plan::Call::glColorPointer); }
HLE_BIND("_glColorPointer", hle_prepared_glColorPointer)
HLE_DEFINE(hle_prepared_glCompileShader) { ForwardPreparedGL(vm,as6_render_plan::Call::glCompileShader); }
HLE_BIND("_glCompileShader", hle_prepared_glCompileShader)
HLE_DEFINE(hle_prepared_glCompressedTexImage2D) { ForwardPreparedGL(vm,as6_render_plan::Call::glCompressedTexImage2D); }
HLE_BIND("_glCompressedTexImage2D", hle_prepared_glCompressedTexImage2D)
HLE_DEFINE(hle_prepared_glCompressedTexSubImage2D) { ForwardPreparedGL(vm,as6_render_plan::Call::glCompressedTexSubImage2D); }
HLE_BIND("_glCompressedTexSubImage2D", hle_prepared_glCompressedTexSubImage2D)
HLE_DEFINE(hle_prepared_glCopyTexImage2D) { ForwardPreparedGL(vm,as6_render_plan::Call::glCopyTexImage2D); }
HLE_BIND("_glCopyTexImage2D", hle_prepared_glCopyTexImage2D)
HLE_DEFINE(hle_prepared_glCopyTexSubImage2D) { ForwardPreparedGL(vm,as6_render_plan::Call::glCopyTexSubImage2D); }
HLE_BIND("_glCopyTexSubImage2D", hle_prepared_glCopyTexSubImage2D)
HLE_DEFINE(hle_prepared_glCreateProgram) { ForwardPreparedGL(vm,as6_render_plan::Call::glCreateProgram); }
HLE_BIND("_glCreateProgram", hle_prepared_glCreateProgram)
HLE_DEFINE(hle_prepared_glCreateShader) { ForwardPreparedGL(vm,as6_render_plan::Call::glCreateShader); }
HLE_BIND("_glCreateShader", hle_prepared_glCreateShader)
HLE_DEFINE(hle_prepared_glCullFace) { ForwardPreparedGL(vm,as6_render_plan::Call::glCullFace); }
HLE_BIND("_glCullFace", hle_prepared_glCullFace)
HLE_DEFINE(hle_prepared_glDeleteBuffers) { ForwardPreparedGL(vm,as6_render_plan::Call::glDeleteBuffers); }
HLE_BIND("_glDeleteBuffers", hle_prepared_glDeleteBuffers)
HLE_DEFINE(hle_prepared_glDeleteFramebuffers) { ForwardPreparedGL(vm,as6_render_plan::Call::glDeleteFramebuffers); }
HLE_BIND("_glDeleteFramebuffers", hle_prepared_glDeleteFramebuffers)
HLE_DEFINE(hle_prepared_glDeleteFramebuffersOES) { ForwardPreparedGL(vm,as6_render_plan::Call::glDeleteFramebuffersOES); }
HLE_BIND("_glDeleteFramebuffersOES", hle_prepared_glDeleteFramebuffersOES)
HLE_DEFINE(hle_prepared_glDeleteProgram) { ForwardPreparedGL(vm,as6_render_plan::Call::glDeleteProgram); }
HLE_BIND("_glDeleteProgram", hle_prepared_glDeleteProgram)
HLE_DEFINE(hle_prepared_glDeleteRenderbuffers) { ForwardPreparedGL(vm,as6_render_plan::Call::glDeleteRenderbuffers); }
HLE_BIND("_glDeleteRenderbuffers", hle_prepared_glDeleteRenderbuffers)
HLE_DEFINE(hle_prepared_glDeleteRenderbuffersOES) { ForwardPreparedGL(vm,as6_render_plan::Call::glDeleteRenderbuffersOES); }
HLE_BIND("_glDeleteRenderbuffersOES", hle_prepared_glDeleteRenderbuffersOES)
HLE_DEFINE(hle_prepared_glDeleteShader) { ForwardPreparedGL(vm,as6_render_plan::Call::glDeleteShader); }
HLE_BIND("_glDeleteShader", hle_prepared_glDeleteShader)
HLE_DEFINE(hle_prepared_glDeleteTextures) { ForwardPreparedGL(vm,as6_render_plan::Call::glDeleteTextures); }
HLE_BIND("_glDeleteTextures", hle_prepared_glDeleteTextures)
HLE_DEFINE(hle_prepared_glDepthFunc) { ForwardPreparedGL(vm,as6_render_plan::Call::glDepthFunc); }
HLE_BIND("_glDepthFunc", hle_prepared_glDepthFunc)
HLE_DEFINE(hle_prepared_glDepthMask) { ForwardPreparedGL(vm,as6_render_plan::Call::glDepthMask); }
HLE_BIND("_glDepthMask", hle_prepared_glDepthMask)
HLE_DEFINE(hle_prepared_glDepthRangef) { ForwardPreparedGL(vm,as6_render_plan::Call::glDepthRangef); }
HLE_BIND("_glDepthRangef", hle_prepared_glDepthRangef)
HLE_DEFINE(hle_prepared_glDisable) { ForwardPreparedGL(vm,as6_render_plan::Call::glDisable); }
HLE_BIND("_glDisable", hle_prepared_glDisable)
HLE_DEFINE(hle_prepared_glDisableClientState) { ForwardPreparedGL(vm,as6_render_plan::Call::glDisableClientState); }
HLE_BIND("_glDisableClientState", hle_prepared_glDisableClientState)
HLE_DEFINE(hle_prepared_glDisableVertexAttribArray) { ForwardPreparedGL(vm,as6_render_plan::Call::glDisableVertexAttribArray); }
HLE_BIND("_glDisableVertexAttribArray", hle_prepared_glDisableVertexAttribArray)
HLE_DEFINE(hle_prepared_glDiscardFramebufferEXT) { ForwardPreparedGL(vm,as6_render_plan::Call::glDiscardFramebufferEXT); }
HLE_BIND("_glDiscardFramebufferEXT", hle_prepared_glDiscardFramebufferEXT)
HLE_DEFINE(hle_prepared_glDrawArrays) { ForwardPreparedGL(vm,as6_render_plan::Call::glDrawArrays); }
HLE_BIND("_glDrawArrays", hle_prepared_glDrawArrays)
HLE_DEFINE(hle_prepared_glDrawElements) { ForwardPreparedGL(vm,as6_render_plan::Call::glDrawElements); }
HLE_BIND("_glDrawElements", hle_prepared_glDrawElements)
HLE_DEFINE(hle_prepared_glEnable) { ForwardPreparedGL(vm,as6_render_plan::Call::glEnable); }
HLE_BIND("_glEnable", hle_prepared_glEnable)
HLE_DEFINE(hle_prepared_glEnableClientState) { ForwardPreparedGL(vm,as6_render_plan::Call::glEnableClientState); }
HLE_BIND("_glEnableClientState", hle_prepared_glEnableClientState)
HLE_DEFINE(hle_prepared_glEnableVertexAttribArray) { ForwardPreparedGL(vm,as6_render_plan::Call::glEnableVertexAttribArray); }
HLE_BIND("_glEnableVertexAttribArray", hle_prepared_glEnableVertexAttribArray)
HLE_DEFINE(hle_prepared_glFlush) { ForwardPreparedGL(vm,as6_render_plan::Call::glFlush); }
HLE_BIND("_glFlush", hle_prepared_glFlush)
HLE_DEFINE(hle_prepared_glFogf) { ForwardPreparedGL(vm,as6_render_plan::Call::glFogf); }
HLE_BIND("_glFogf", hle_prepared_glFogf)
HLE_DEFINE(hle_prepared_glFogfv) { ForwardPreparedGL(vm,as6_render_plan::Call::glFogfv); }
HLE_BIND("_glFogfv", hle_prepared_glFogfv)
HLE_DEFINE(hle_prepared_glFramebufferRenderbuffer) { ForwardPreparedGL(vm,as6_render_plan::Call::glFramebufferRenderbuffer); }
HLE_BIND("_glFramebufferRenderbuffer", hle_prepared_glFramebufferRenderbuffer)
HLE_DEFINE(hle_prepared_glFramebufferRenderbufferOES) { ForwardPreparedGL(vm,as6_render_plan::Call::glFramebufferRenderbufferOES); }
HLE_BIND("_glFramebufferRenderbufferOES", hle_prepared_glFramebufferRenderbufferOES)
HLE_DEFINE(hle_prepared_glFramebufferTexture2D) { ForwardPreparedGL(vm,as6_render_plan::Call::glFramebufferTexture2D); }
HLE_BIND("_glFramebufferTexture2D", hle_prepared_glFramebufferTexture2D)
HLE_DEFINE(hle_prepared_glFramebufferTexture2DOES) { ForwardPreparedGL(vm,as6_render_plan::Call::glFramebufferTexture2DOES); }
HLE_BIND("_glFramebufferTexture2DOES", hle_prepared_glFramebufferTexture2DOES)
HLE_DEFINE(hle_prepared_glFrontFace) { ForwardPreparedGL(vm,as6_render_plan::Call::glFrontFace); }
HLE_BIND("_glFrontFace", hle_prepared_glFrontFace)
HLE_DEFINE(hle_prepared_glGenBuffers) { ForwardPreparedGL(vm,as6_render_plan::Call::glGenBuffers); }
HLE_BIND("_glGenBuffers", hle_prepared_glGenBuffers)
HLE_DEFINE(hle_prepared_glGenFramebuffers) { ForwardPreparedGL(vm,as6_render_plan::Call::glGenFramebuffers); }
HLE_BIND("_glGenFramebuffers", hle_prepared_glGenFramebuffers)
HLE_DEFINE(hle_prepared_glGenFramebuffersOES) { ForwardPreparedGL(vm,as6_render_plan::Call::glGenFramebuffersOES); }
HLE_BIND("_glGenFramebuffersOES", hle_prepared_glGenFramebuffersOES)
HLE_DEFINE(hle_prepared_glGenRenderbuffers) { ForwardPreparedGL(vm,as6_render_plan::Call::glGenRenderbuffers); }
HLE_BIND("_glGenRenderbuffers", hle_prepared_glGenRenderbuffers)
HLE_DEFINE(hle_prepared_glGenRenderbuffersOES) { ForwardPreparedGL(vm,as6_render_plan::Call::glGenRenderbuffersOES); }
HLE_BIND("_glGenRenderbuffersOES", hle_prepared_glGenRenderbuffersOES)
HLE_DEFINE(hle_prepared_glGenTextures) { ForwardPreparedGL(vm,as6_render_plan::Call::glGenTextures); }
HLE_BIND("_glGenTextures", hle_prepared_glGenTextures)
HLE_DEFINE(hle_prepared_glGenerateMipmap) { ForwardPreparedGL(vm,as6_render_plan::Call::glGenerateMipmap); }
HLE_BIND("_glGenerateMipmap", hle_prepared_glGenerateMipmap)
HLE_DEFINE(hle_prepared_glGenerateMipmapOES) { ForwardPreparedGL(vm,as6_render_plan::Call::glGenerateMipmapOES); }
HLE_BIND("_glGenerateMipmapOES", hle_prepared_glGenerateMipmapOES)
HLE_DEFINE(hle_prepared_glGetActiveAttrib) { ForwardPreparedGL(vm,as6_render_plan::Call::glGetActiveAttrib); }
HLE_BIND("_glGetActiveAttrib", hle_prepared_glGetActiveAttrib)
HLE_DEFINE(hle_prepared_glGetActiveUniform) { ForwardPreparedGL(vm,as6_render_plan::Call::glGetActiveUniform); }
HLE_BIND("_glGetActiveUniform", hle_prepared_glGetActiveUniform)
HLE_DEFINE(hle_prepared_glGetAttribLocation) { ForwardPreparedGL(vm,as6_render_plan::Call::glGetAttribLocation); }
HLE_BIND("_glGetAttribLocation", hle_prepared_glGetAttribLocation)
HLE_DEFINE(hle_prepared_glGetError) { ForwardPreparedGL(vm,as6_render_plan::Call::glGetError); }
HLE_BIND("_glGetError", hle_prepared_glGetError)
HLE_DEFINE(hle_prepared_glGetFloatv) { ForwardPreparedGL(vm,as6_render_plan::Call::glGetFloatv); }
HLE_BIND("_glGetFloatv", hle_prepared_glGetFloatv)
HLE_DEFINE(hle_prepared_glGetIntegerv) { ForwardPreparedGL(vm,as6_render_plan::Call::glGetIntegerv); }
HLE_BIND("_glGetIntegerv", hle_prepared_glGetIntegerv)
HLE_DEFINE(hle_prepared_glGetProgramInfoLog) { ForwardPreparedGL(vm,as6_render_plan::Call::glGetProgramInfoLog); }
HLE_BIND("_glGetProgramInfoLog", hle_prepared_glGetProgramInfoLog)
HLE_DEFINE(hle_prepared_glGetProgramiv) { ForwardPreparedGL(vm,as6_render_plan::Call::glGetProgramiv); }
HLE_BIND("_glGetProgramiv", hle_prepared_glGetProgramiv)
HLE_DEFINE(hle_prepared_glGetRenderbufferParameterivOES) { ForwardPreparedGL(vm,as6_render_plan::Call::glGetRenderbufferParameterivOES); }
HLE_BIND("_glGetRenderbufferParameterivOES", hle_prepared_glGetRenderbufferParameterivOES)
HLE_DEFINE(hle_prepared_glGetShaderInfoLog) { ForwardPreparedGL(vm,as6_render_plan::Call::glGetShaderInfoLog); }
HLE_BIND("_glGetShaderInfoLog", hle_prepared_glGetShaderInfoLog)
HLE_DEFINE(hle_prepared_glGetShaderiv) { ForwardPreparedGL(vm,as6_render_plan::Call::glGetShaderiv); }
HLE_BIND("_glGetShaderiv", hle_prepared_glGetShaderiv)
HLE_DEFINE(hle_prepared_glGetString) { ForwardPreparedGL(vm,as6_render_plan::Call::glGetString); }
HLE_BIND("_glGetString", hle_prepared_glGetString)
HLE_DEFINE(hle_prepared_glGetStringi) { ForwardPreparedGL(vm,as6_render_plan::Call::glGetStringi); }
HLE_BIND("_glGetStringi", hle_prepared_glGetStringi)
HLE_DEFINE(hle_prepared_glGetUniformLocation) { ForwardPreparedGL(vm,as6_render_plan::Call::glGetUniformLocation); }
HLE_BIND("_glGetUniformLocation", hle_prepared_glGetUniformLocation)
HLE_DEFINE(hle_prepared_glHint) { ForwardPreparedGL(vm,as6_render_plan::Call::glHint); }
HLE_BIND("_glHint", hle_prepared_glHint)
HLE_DEFINE(hle_prepared_glIsFramebuffer) { ForwardPreparedGL(vm,as6_render_plan::Call::glIsFramebuffer); }
HLE_BIND("_glIsFramebuffer", hle_prepared_glIsFramebuffer)
HLE_DEFINE(hle_prepared_glIsFramebufferOES) { ForwardPreparedGL(vm,as6_render_plan::Call::glIsFramebufferOES); }
HLE_BIND("_glIsFramebufferOES", hle_prepared_glIsFramebufferOES)
HLE_DEFINE(hle_prepared_glIsRenderbuffer) { ForwardPreparedGL(vm,as6_render_plan::Call::glIsRenderbuffer); }
HLE_BIND("_glIsRenderbuffer", hle_prepared_glIsRenderbuffer)
HLE_DEFINE(hle_prepared_glIsRenderbufferOES) { ForwardPreparedGL(vm,as6_render_plan::Call::glIsRenderbufferOES); }
HLE_BIND("_glIsRenderbufferOES", hle_prepared_glIsRenderbufferOES)
HLE_DEFINE(hle_prepared_glIsTexture) { ForwardPreparedGL(vm,as6_render_plan::Call::glIsTexture); }
HLE_BIND("_glIsTexture", hle_prepared_glIsTexture)
HLE_DEFINE(hle_prepared_glLightModelf) { ForwardPreparedGL(vm,as6_render_plan::Call::glLightModelf); }
HLE_BIND("_glLightModelf", hle_prepared_glLightModelf)
HLE_DEFINE(hle_prepared_glLightModelfv) { ForwardPreparedGL(vm,as6_render_plan::Call::glLightModelfv); }
HLE_BIND("_glLightModelfv", hle_prepared_glLightModelfv)
HLE_DEFINE(hle_prepared_glLightf) { ForwardPreparedGL(vm,as6_render_plan::Call::glLightf); }
HLE_BIND("_glLightf", hle_prepared_glLightf)
HLE_DEFINE(hle_prepared_glLightfv) { ForwardPreparedGL(vm,as6_render_plan::Call::glLightfv); }
HLE_BIND("_glLightfv", hle_prepared_glLightfv)
HLE_DEFINE(hle_prepared_glLineWidth) { ForwardPreparedGL(vm,as6_render_plan::Call::glLineWidth); }
HLE_BIND("_glLineWidth", hle_prepared_glLineWidth)
HLE_DEFINE(hle_prepared_glLinkProgram) { ForwardPreparedGL(vm,as6_render_plan::Call::glLinkProgram); }
HLE_BIND("_glLinkProgram", hle_prepared_glLinkProgram)
HLE_DEFINE(hle_prepared_glLoadIdentity) { ForwardPreparedGL(vm,as6_render_plan::Call::glLoadIdentity); }
HLE_BIND("_glLoadIdentity", hle_prepared_glLoadIdentity)
HLE_DEFINE(hle_prepared_glLoadMatrixf) { ForwardPreparedGL(vm,as6_render_plan::Call::glLoadMatrixf); }
HLE_BIND("_glLoadMatrixf", hle_prepared_glLoadMatrixf)
HLE_DEFINE(hle_prepared_glMapBufferOES) { ForwardPreparedGL(vm,as6_render_plan::Call::glMapBufferOES); }
HLE_BIND("_glMapBufferOES", hle_prepared_glMapBufferOES)
HLE_DEFINE(hle_prepared_glMaterialf) { ForwardPreparedGL(vm,as6_render_plan::Call::glMaterialf); }
HLE_BIND("_glMaterialf", hle_prepared_glMaterialf)
HLE_DEFINE(hle_prepared_glMaterialfv) { ForwardPreparedGL(vm,as6_render_plan::Call::glMaterialfv); }
HLE_BIND("_glMaterialfv", hle_prepared_glMaterialfv)
HLE_DEFINE(hle_prepared_glMatrixMode) { ForwardPreparedGL(vm,as6_render_plan::Call::glMatrixMode); }
HLE_BIND("_glMatrixMode", hle_prepared_glMatrixMode)
HLE_DEFINE(hle_prepared_glMultMatrixf) { ForwardPreparedGL(vm,as6_render_plan::Call::glMultMatrixf); }
HLE_BIND("_glMultMatrixf", hle_prepared_glMultMatrixf)
HLE_DEFINE(hle_prepared_glMultiTexCoord4f) { ForwardPreparedGL(vm,as6_render_plan::Call::glMultiTexCoord4f); }
HLE_BIND("_glMultiTexCoord4f", hle_prepared_glMultiTexCoord4f)
HLE_DEFINE(hle_prepared_glNormal3f) { ForwardPreparedGL(vm,as6_render_plan::Call::glNormal3f); }
HLE_BIND("_glNormal3f", hle_prepared_glNormal3f)
HLE_DEFINE(hle_prepared_glNormalPointer) { ForwardPreparedGL(vm,as6_render_plan::Call::glNormalPointer); }
HLE_BIND("_glNormalPointer", hle_prepared_glNormalPointer)
HLE_DEFINE(hle_prepared_glPixelStorei) { ForwardPreparedGL(vm,as6_render_plan::Call::glPixelStorei); }
HLE_BIND("_glPixelStorei", hle_prepared_glPixelStorei)
HLE_DEFINE(hle_prepared_glPointParameterf) { ForwardPreparedGL(vm,as6_render_plan::Call::glPointParameterf); }
HLE_BIND("_glPointParameterf", hle_prepared_glPointParameterf)
HLE_DEFINE(hle_prepared_glPointParameterfv) { ForwardPreparedGL(vm,as6_render_plan::Call::glPointParameterfv); }
HLE_BIND("_glPointParameterfv", hle_prepared_glPointParameterfv)
HLE_DEFINE(hle_prepared_glPointSize) { ForwardPreparedGL(vm,as6_render_plan::Call::glPointSize); }
HLE_BIND("_glPointSize", hle_prepared_glPointSize)
HLE_DEFINE(hle_prepared_glPolygonOffset) { ForwardPreparedGL(vm,as6_render_plan::Call::glPolygonOffset); }
HLE_BIND("_glPolygonOffset", hle_prepared_glPolygonOffset)
HLE_DEFINE(hle_prepared_glPopMatrix) { ForwardPreparedGL(vm,as6_render_plan::Call::glPopMatrix); }
HLE_BIND("_glPopMatrix", hle_prepared_glPopMatrix)
HLE_DEFINE(hle_prepared_glPushMatrix) { ForwardPreparedGL(vm,as6_render_plan::Call::glPushMatrix); }
HLE_BIND("_glPushMatrix", hle_prepared_glPushMatrix)
HLE_DEFINE(hle_prepared_glReadPixels) { ForwardPreparedGL(vm,as6_render_plan::Call::glReadPixels); }
HLE_BIND("_glReadPixels", hle_prepared_glReadPixels)
HLE_DEFINE(hle_prepared_glRenderbufferStorage) { ForwardPreparedGL(vm,as6_render_plan::Call::glRenderbufferStorage); }
HLE_BIND("_glRenderbufferStorage", hle_prepared_glRenderbufferStorage)
HLE_DEFINE(hle_prepared_glRenderbufferStorageMultisampleAPPLE) { ForwardPreparedGL(vm,as6_render_plan::Call::glRenderbufferStorageMultisampleAPPLE); }
HLE_BIND("_glRenderbufferStorageMultisampleAPPLE", hle_prepared_glRenderbufferStorageMultisampleAPPLE)
HLE_DEFINE(hle_prepared_glRenderbufferStorageOES) { ForwardPreparedGL(vm,as6_render_plan::Call::glRenderbufferStorageOES); }
HLE_BIND("_glRenderbufferStorageOES", hle_prepared_glRenderbufferStorageOES)
HLE_DEFINE(hle_prepared_glResolveMultisampleFramebufferAPPLE) { ForwardPreparedGL(vm,as6_render_plan::Call::glResolveMultisampleFramebufferAPPLE); }
HLE_BIND("_glResolveMultisampleFramebufferAPPLE", hle_prepared_glResolveMultisampleFramebufferAPPLE)
HLE_DEFINE(hle_prepared_glSampleCoverage) { ForwardPreparedGL(vm,as6_render_plan::Call::glSampleCoverage); }
HLE_BIND("_glSampleCoverage", hle_prepared_glSampleCoverage)
HLE_DEFINE(hle_prepared_glScissor) { ForwardPreparedGL(vm,as6_render_plan::Call::glScissor); }
HLE_BIND("_glScissor", hle_prepared_glScissor)
HLE_DEFINE(hle_prepared_glShadeModel) { ForwardPreparedGL(vm,as6_render_plan::Call::glShadeModel); }
HLE_BIND("_glShadeModel", hle_prepared_glShadeModel)
HLE_DEFINE(hle_prepared_glShaderSource) { ForwardPreparedGL(vm,as6_render_plan::Call::glShaderSource); }
HLE_BIND("_glShaderSource", hle_prepared_glShaderSource)
HLE_DEFINE(hle_prepared_glStencilFunc) { ForwardPreparedGL(vm,as6_render_plan::Call::glStencilFunc); }
HLE_BIND("_glStencilFunc", hle_prepared_glStencilFunc)
HLE_DEFINE(hle_prepared_glStencilMask) { ForwardPreparedGL(vm,as6_render_plan::Call::glStencilMask); }
HLE_BIND("_glStencilMask", hle_prepared_glStencilMask)
HLE_DEFINE(hle_prepared_glStencilOp) { ForwardPreparedGL(vm,as6_render_plan::Call::glStencilOp); }
HLE_BIND("_glStencilOp", hle_prepared_glStencilOp)
HLE_DEFINE(hle_prepared_glTexCoordPointer) { ForwardPreparedGL(vm,as6_render_plan::Call::glTexCoordPointer); }
HLE_BIND("_glTexCoordPointer", hle_prepared_glTexCoordPointer)
HLE_DEFINE(hle_prepared_glTexEnvf) { ForwardPreparedGL(vm,as6_render_plan::Call::glTexEnvf); }
HLE_BIND("_glTexEnvf", hle_prepared_glTexEnvf)
HLE_DEFINE(hle_prepared_glTexEnvfv) { ForwardPreparedGL(vm,as6_render_plan::Call::glTexEnvfv); }
HLE_BIND("_glTexEnvfv", hle_prepared_glTexEnvfv)
HLE_DEFINE(hle_prepared_glTexEnvi) { ForwardPreparedGL(vm,as6_render_plan::Call::glTexEnvi); }
HLE_BIND("_glTexEnvi", hle_prepared_glTexEnvi)
HLE_DEFINE(hle_prepared_glTexImage2D) { ForwardPreparedGL(vm,as6_render_plan::Call::glTexImage2D); }
HLE_BIND("_glTexImage2D", hle_prepared_glTexImage2D)
HLE_DEFINE(hle_prepared_glTexParameterf) { ForwardPreparedGL(vm,as6_render_plan::Call::glTexParameterf); }
HLE_BIND("_glTexParameterf", hle_prepared_glTexParameterf)
HLE_DEFINE(hle_prepared_glTexParameteri) { ForwardPreparedGL(vm,as6_render_plan::Call::glTexParameteri); }
HLE_BIND("_glTexParameteri", hle_prepared_glTexParameteri)
HLE_DEFINE(hle_prepared_glTexSubImage2D) { ForwardPreparedGL(vm,as6_render_plan::Call::glTexSubImage2D); }
HLE_BIND("_glTexSubImage2D", hle_prepared_glTexSubImage2D)
HLE_DEFINE(hle_prepared_glUniform1f) { ForwardPreparedGL(vm,as6_render_plan::Call::glUniform1f); }
HLE_BIND("_glUniform1f", hle_prepared_glUniform1f)
HLE_DEFINE(hle_prepared_glUniform1fv) { ForwardPreparedGL(vm,as6_render_plan::Call::glUniform1fv); }
HLE_BIND("_glUniform1fv", hle_prepared_glUniform1fv)
HLE_DEFINE(hle_prepared_glUniform1i) { ForwardPreparedGL(vm,as6_render_plan::Call::glUniform1i); }
HLE_BIND("_glUniform1i", hle_prepared_glUniform1i)
HLE_DEFINE(hle_prepared_glUniform1iv) { ForwardPreparedGL(vm,as6_render_plan::Call::glUniform1iv); }
HLE_BIND("_glUniform1iv", hle_prepared_glUniform1iv)
HLE_DEFINE(hle_prepared_glUniform2fv) { ForwardPreparedGL(vm,as6_render_plan::Call::glUniform2fv); }
HLE_BIND("_glUniform2fv", hle_prepared_glUniform2fv)
HLE_DEFINE(hle_prepared_glUniform2iv) { ForwardPreparedGL(vm,as6_render_plan::Call::glUniform2iv); }
HLE_BIND("_glUniform2iv", hle_prepared_glUniform2iv)
HLE_DEFINE(hle_prepared_glUniform3fv) { ForwardPreparedGL(vm,as6_render_plan::Call::glUniform3fv); }
HLE_BIND("_glUniform3fv", hle_prepared_glUniform3fv)
HLE_DEFINE(hle_prepared_glUniform3iv) { ForwardPreparedGL(vm,as6_render_plan::Call::glUniform3iv); }
HLE_BIND("_glUniform3iv", hle_prepared_glUniform3iv)
HLE_DEFINE(hle_prepared_glUniform4fv) { ForwardPreparedGL(vm,as6_render_plan::Call::glUniform4fv); }
HLE_BIND("_glUniform4fv", hle_prepared_glUniform4fv)
HLE_DEFINE(hle_prepared_glUniform4iv) { ForwardPreparedGL(vm,as6_render_plan::Call::glUniform4iv); }
HLE_BIND("_glUniform4iv", hle_prepared_glUniform4iv)
HLE_DEFINE(hle_prepared_glUniformMatrix4fv) { ForwardPreparedGL(vm,as6_render_plan::Call::glUniformMatrix4fv); }
HLE_BIND("_glUniformMatrix4fv", hle_prepared_glUniformMatrix4fv)
HLE_DEFINE(hle_prepared_glUnmapBufferOES) { ForwardPreparedGL(vm,as6_render_plan::Call::glUnmapBufferOES); }
HLE_BIND("_glUnmapBufferOES", hle_prepared_glUnmapBufferOES)
HLE_DEFINE(hle_prepared_glUseProgram) { ForwardPreparedGL(vm,as6_render_plan::Call::glUseProgram); }
HLE_BIND("_glUseProgram", hle_prepared_glUseProgram)
HLE_DEFINE(hle_prepared_glVertexAttrib4f) { ForwardPreparedGL(vm,as6_render_plan::Call::glVertexAttrib4f); }
HLE_BIND("_glVertexAttrib4f", hle_prepared_glVertexAttrib4f)
HLE_DEFINE(hle_prepared_glVertexAttribPointer) { ForwardPreparedGL(vm,as6_render_plan::Call::glVertexAttribPointer); }
HLE_BIND("_glVertexAttribPointer", hle_prepared_glVertexAttribPointer)
HLE_DEFINE(hle_prepared_glVertexPointer) { ForwardPreparedGL(vm,as6_render_plan::Call::glVertexPointer); }
HLE_BIND("_glVertexPointer", hle_prepared_glVertexPointer)
HLE_DEFINE(hle_prepared_glViewport) { ForwardPreparedGL(vm,as6_render_plan::Call::glViewport); }
HLE_BIND("_glViewport", hle_prepared_glViewport)
