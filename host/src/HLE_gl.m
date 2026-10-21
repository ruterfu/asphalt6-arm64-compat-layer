// Stand-ins for the EAGL classes, used only if the runtime really lacks them.
// The iOS 27 simulator still ships EAGLContext and CAEAGLLayer, so in practice
// the original image binds to the real ones and nothing here registers.

#import "HLE.h"
#import "GuestVM.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
