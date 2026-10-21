#pragma once
// Isolated host proposal. Include only in GuestObjC.m (compiled as Objective-C++).
#import "GuestVM.h"
#import "GuestObjC.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/CAEAGLLayer.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES2/gl.h>
#include <cmath>
#include <cstdio>
#include <cstring>

extern "C" gva_t GuestGLView(void);
// Existing typed host guard: VM lock held and nativeDepth == 0.
extern "C" BOOL GuestDiagnosticSnapshotLockHeld(GuestVM *vm);

namespace as6_gameplay_backing {
constexpr float kStartupScale = 2.f, kGameplayScale = 5.f;
constexpr int kWidth = 1600, kHeight = 2400;
struct State {
    __weak GuestVM *owner = nil;
    gva_t view = 0;
    bool applied = false, busy = false;
};
inline bool callOriginal(GuestVM *vm, gva_t view, const char *name, bool truth = false) {
    const auto selector = GuestObjCGuestSelNamed(vm, name);
    if (!selector) return false;
    GuestSetReg(vm, 0, view); GuestSetReg(vm, 1, selector);
    GuestSetReg(vm, 2, 0); GuestSetReg(vm, 3, 0);
    if (!GuestObjCSend(vm, view, selector, NO) ||
        GuestLastExecutionResult(vm) != GuestExecutionSuccess) return false;
    return !truth || (GuestReg(vm, 0) & 0xffu);
}
inline bool completeAttachments() {
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return false;
    GLint saved = 0; glGetIntegerv(GL_RENDERBUFFER_BINDING, &saved);
    bool valid = true;
    const GLenum attachments[] = {GL_COLOR_ATTACHMENT0, GL_DEPTH_ATTACHMENT, GL_STENCIL_ATTACHMENT};
    for (const auto attachment : attachments) {
        GLint type = 0, object = 0;
        glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, attachment, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &type);
        glGetFramebufferAttachmentParameteriv(GL_FRAMEBUFFER, attachment, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &object);
        if (!object && attachment == GL_STENCIL_ATTACHMENT) continue;
        if (!object || type != GL_RENDERBUFFER) { valid = false; break; }
        glBindRenderbuffer(GL_RENDERBUFFER, GLuint(object));
        GLint width = 0, height = 0;
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &width);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &height);
        if (width != kWidth || height != kHeight) { valid = false; break; }
    }
    glBindRenderbuffer(GL_RENDERBUFFER, GLuint(saved));
    return valid;
}

// Runs immediately after GuestObjCSend decoded SEL, before original IMP dispatch.
// Every drawViewEventPump iteration sends drawView via original objc_msgSend.
inline bool beforeMessage(GuestVM *vm, gva_t receiver, SEL selector, State &state) {
    if (!selector || strcmp(sel_getName(selector), "drawView") || receiver != GuestGLView()) return true;
    if (state.owner != vm || state.view != receiver) {
        state.owner = vm; state.view = receiver; state.applied = state.busy = false;
    }
    if (state.busy) return false;
    uint32_t phase = 0;
    if (!GuestRead(vm, receiver + 0x60, &phase, sizeof(phase))) return false;
    // Original states0/2 select both movies using UIScreen.bounds * view.scale.
    if (phase != 5 || state.applied) return true;
    if (!NSThread.isMainThread || !GuestDiagnosticSnapshotLockHeld(vm) || GuestHasStopRequest(vm)) return false;
    // Validate frozen-image ivar identities and the exact measured baseline.
    if (GuestReadU32(vm, 0x702514) != 0x60 || GuestReadU32(vm, 0x702508) != 0x54 ||
        GuestReadU32(vm, 0x7021c8) != 0x34 || GuestReadU32(vm, 0x7024e8) != 0x2c ||
        GuestReadU32(vm, 0x7024ec) != 0x30) return false;
    const auto applicationSlot = GuestReadU32(vm, 0x700bec);
    uint8_t msaa = 0;
    if (!applicationSlot || GuestReadU32(vm, applicationSlot) ||
        !GuestRead(vm, 0x70ae8c, &msaa, 1) || msaa) return false;
    float startupScale = 0;
    int32_t width = 0, height = 0;
    if (!GuestRead(vm, receiver + 0x54, &startupScale, 4) ||
        !GuestRead(vm, receiver + 0x2c, &width, 4) || !GuestRead(vm, receiver + 0x30, &height, 4) ||
        startupScale != kStartupScale || width != 640 || height != 960 || GuestScreenBackingScale() != 2.) return false;
    UIView *shadow = GuestObjCShadow(vm, receiver);
    id contextObject = GuestObjCUnwrap(vm, GuestReadU32(vm, receiver + 0x34));
    if (!shadow || ![shadow.layer isKindOfClass:CAEAGLLayer.class] ||
        ![contextObject isKindOfClass:EAGLContext.class] ||
        !CGRectEqualToRect(shadow.bounds, CGRectMake(0, 0, 320, 480))) return false;
    EAGLContext *context = contextObject;
    if (context.API != kEAGLRenderingAPIOpenGLES2) return false;
    EAGLContext *previousContext = EAGLContext.currentContext;
    GuestCpuSnapshot *snapshot = nullptr;
    const auto stret = GuestStretDestination();
    bool saved = false, ok = false;
    state.busy = true;
    @try {
        if (GuestCPUAllocate(vm, &snapshot) != GuestExecutionSuccess ||
            GuestCPUSave(vm, snapshot) != GuestExecutionSuccess) return false;
        saved = true;
        if (![EAGLContext setCurrentContext:context]) return false;
        // Original destroy/create own all actual FBO/RBO names and attachments.
        if (!callOriginal(vm, receiver, "destroyFramebuffer")) return false;
        shadow.contentScaleFactor = kGameplayScale;
        shadow.layer.contentsScale = kGameplayScale;
        if (shadow.contentScaleFactor != kGameplayScale || shadow.layer.contentsScale != kGameplayScale ||
            !GuestWrite(vm, receiver + 0x54, &kGameplayScale, sizeof(kGameplayScale))) return false;
        if (!callOriginal(vm, receiver, "createFramebuffer", true)) return false;
        if (!GuestRead(vm, receiver + 0x2c, &width, 4) || !GuestRead(vm, receiver + 0x30, &height, 4) ||
            width != kWidth || height != kHeight || !completeAttachments()) return false;
        GLint actualFBO = 0; glGetIntegerv(GL_FRAMEBUFFER_BINDING, &actualFBO);
        if (GLuint(actualFBO) != GuestReadU32(vm, 0x749d20)) return false;
        state.applied = true;
        char line[192];
        snprintf(line, sizeof(line), "[gameplay-backing] scale=5 backing=%dx%d all-attachments=verified startup-scale=2", width, height);
        GuestRawLog(line);
        ok = true;
    } @finally {
        if (![EAGLContext setCurrentContext:previousContext]) ok = false;
        if (saved && GuestCPURestore(vm, snapshot) != GuestExecutionSuccess) ok = false;
        GuestSetStretDestination(stret);
        if (snapshot) GuestCPUFree(snapshot);
        state.busy = false;
    }
    return ok;
}
}
