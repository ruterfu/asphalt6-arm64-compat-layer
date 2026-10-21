#ifndef PORT_GLREAL_H
#define PORT_GLREAL_H

#import <Foundation/Foundation.h>
#import "GuestTypes.h"

@class GuestVM;

typedef void (*GLRFn)(void);
// A generated thunk: performs the host call with already-marshalled arguments.
typedef void (*GLRThunkFn)(GLRFn fn, const uint64_t *I, const float *F, void *const *P);

// One generated entry point: the name the original image imports, a signature
// descriptor, and the typed thunk that performs the host call.
struct GLRThunkRec {
    const char *name;
    const char *sig;
    GLRThunkFn fn;
};
typedef struct GLRThunkRec GLRThunkRec;

extern const GLRThunkRec kGLThunks[];
extern const unsigned kGLThunkCount;

#ifdef __cplusplus
extern "C" {
#endif

// Dispatch one guest GL import to the arm64 OpenGL ES driver.
void GLRealDispatch(GuestVM *vm, const char *symbol);
void GLRealDispatchPrepared(GuestVM *vm,uint32_t callID);
// Atomic cumulative CPU preparation statistics; no driver/context/Guest access.
NSDictionary *AS6GLRenderWorkDiagnostics(void);
// Serializes the complete GL bridge, including external raster adjustments.
// Contended acquisition suspends the caller's VM locks while waiting.
BOOL GLRealBeginSerialCall(GuestVM *vm);
void GLRealEndSerialCall(GuestVM *vm);
// Synchronous native-driver operation only: arguments/outputs must be host
// storage already marshalled while locked. Never access GuestVM in operation.
void GLRealHostOperation(void (*operation)(void *), void *context);
// Return marshalling for the generated thunks (the guest is single threaded and
// the call is synchronous, so the current VM is stashed by the dispatcher).
void GLSetRetU32(uint32_t v);
void GLSetRetPtr(void *p);

// The real GLES context the original renderer asked EAGLContext for, or NULL.
void *GLRealCurrentContext(void);
// True once the guest's EAGLView owns a real CAEAGLLayer-backed surface.
BOOL GLRealHasSurface(void);

#ifdef __cplusplus
}

template<class Operation> inline void GLRealHostCall(Operation operation) {
    GLRealHostOperation([](void *raw) { (*static_cast<Operation *>(raw))(); }, &operation);
}
#endif

#endif  // PORT_GLREAL_H
