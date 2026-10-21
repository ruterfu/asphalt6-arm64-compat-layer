// Native delegates for the original guest NSObject classes. These objects only
// translate native callback arguments; the original ARMv7 IMPs own all StoreKit,
// download, and motion behavior. No transaction, response, or sensor value is invented.
#import "GuestObjC.h"
#import "GuestVM.h"
#import "HLE_motion.h"
#import <limits.h>
#import <objc/runtime.h>
#import <string.h>

typedef NS_ENUM(NSUInteger, PortGuestDelegateKind) {
    PortGuestDelegatePaymentObserverKind,
    PortGuestDelegateProductRequestKind,
    PortGuestDelegateLinkGrabberKind,
    PortGuestDelegateAccelerometerKind,
};

// Original ObjC32 method encodings, read directly from class_ro_t.baseMethods.
// Keeping explicit native methods avoids treating 32-bit encodings as arm64
// NSInvocation signatures. These are all void callbacks with object arguments,
// except the original UIAlertView button index, which is a Darwin32 int.
static const char *DelegateEncoding(PortGuestDelegateKind kind, const char *name) {
    switch (kind) {
        case PortGuestDelegatePaymentObserverKind:
            if (!strcmp(name, "paymentQueue:updatedTransactions:") ||
                !strcmp(name, "paymentQueue:restoreCompletedTransactionsFailedWithError:"))
                return "v16@0:4@8@12";
            if (!strcmp(name, "paymentQueueRestoreCompletedTransactionsFinished:"))
                return "v12@0:4@8";
            break;
        case PortGuestDelegateProductRequestKind:
            if (!strcmp(name, "productsRequest:didReceiveResponse:") ||
                !strcmp(name, "request:didFailWithError:"))
                return "v16@0:4@8@12";
            if (!strcmp(name, "alertView:didDismissWithButtonIndex:"))
                return "v16@0:4@8i12";
            break;
        case PortGuestDelegateLinkGrabberKind:
            if (!strcmp(name, "connection:didReceiveResponse:") ||
                !strcmp(name, "connection:didReceiveData:") ||
                !strcmp(name, "connection:didFailWithError:"))
                return "v16@0:4@8@12";
            if (!strcmp(name, "connectionDidFinishLoading:"))
                return "v12@0:4@8";
            break;
        case PortGuestDelegateAccelerometerKind:
            if (!strcmp(name, "accelerometer:didAccelerate:"))
                return "v16@0:4@8@12";
            break;
    }
    return NULL;
}

static BOOL DelegateReadWord(GuestVM *vm, gva_t address, uint32_t *value) {
    return address && GuestRead(vm, address, value, sizeof(*value));
}

static gva_t DelegateMethod(GuestVM *vm, gva_t object, gva_t expectedClass,
                            const char *name, const char *encoding) {
    uint32_t cls = 0;
    if (!DelegateReadWord(vm, object, &cls) || cls != expectedClass) return 0;
    // Only registered in-image classes are traversed. A host superclass handle
    // is not a guest class_t and must never be read as guest memory.
    for (unsigned depth = 0; cls && depth < 32; ++depth) {
        if (!GuestObjCNameForClass(vm, cls)) break;
        uint32_t ro = 0, methods = 0, stride = 0, count = 0;
        if (!DelegateReadWord(vm, cls + 16, &ro) ||
            !DelegateReadWord(vm, ro + 20, &methods)) return 0;
        if (methods) {
            if (!DelegateReadWord(vm, methods, &stride) || stride != 12 ||
                !DelegateReadWord(vm, methods + 4, &count) || count > 4096) return 0;
            for (uint32_t index = 0; index < count; ++index) {
                uint32_t entry[3] = {};
                uint64_t address = (uint64_t)methods + 8 + 12 * (uint64_t)index;
                if (address > UINT32_MAX || !GuestRead(vm, (gva_t)address, entry, sizeof(entry))) return 0;
                NSString *selector = GuestReadCString(vm, entry[0], 256);
                if (!selector || strcmp(selector.UTF8String, name)) continue;
                NSString *types = GuestReadCString(vm, entry[1], 128);
                if (!types || strcmp(types.UTF8String, encoding)) return 0;
                // Preserve the original ARM/Thumb bit. There is no replacement
                // callback implementation or hard-coded "success" target.
                return entry[2];
            }
        }
        if (!DelegateReadWord(vm, cls + 4, &cls)) return 0;
    }
    return 0;
}

@interface PortGuestDelegate : NSObject
@property(nonatomic, weak) GuestVM *vm;
@property(nonatomic) gva_t guestAddress;
@property(nonatomic) gva_t guestClass;
@property(nonatomic) PortGuestDelegateKind kind;
- (void)deliver:(SEL)selector first:(id)first second:(id)second count:(int)count;
- (void)deliverButton:(SEL)selector alert:(id)alert index:(NSInteger)index;
@end

@implementation PortGuestDelegate
- (BOOL)respondsToSelector:(SEL)selector {
    const char *name = sel_getName(selector);
    const char *encoding = DelegateEncoding(self.kind, name);
    if (!encoding) return [super respondsToSelector:selector];
    GuestVM *vm = self.vm;
    if (!vm) return NO;
    GuestLock(vm);
    BOOL found = NO;
    @try { found = DelegateMethod(vm, self.guestAddress, self.guestClass, name, encoding) != 0; }
    @finally { GuestUnlock(vm); }
    return found;
}
- (BOOL)conformsToProtocol:(Protocol *)protocol {
    if ([super conformsToProtocol:protocol]) return YES;
    // These formal protocols are explicitly present in the original metadata.
    // StorekitLinkGrabber uses informal NSURLConnection delegates in that IPA.
    const char *declared = self.kind == PortGuestDelegatePaymentObserverKind ? "SKPaymentTransactionObserver" :
                           self.kind == PortGuestDelegateProductRequestKind ? "SKProductsRequestDelegate" :
                           self.kind == PortGuestDelegateAccelerometerKind ? "UIAccelerometerDelegate" : NULL;
    Protocol *native = declared ? objc_getProtocol(declared) : nil;
    return native && protocol && protocol_conformsToProtocol(native, protocol);
}
- (void)invoke:(SEL)selector first:(id)first second:(id)second count:(int)count
     scalar:(uint32_t)scalar scalarSecond:(BOOL)scalarSecond {
    GuestVM *vm = self.vm;
    if (!vm) return;
    const char *name = sel_getName(selector);
    const char *encoding = DelegateEncoding(self.kind, name);
    if (!encoding) return;
    GuestLock(vm);
    GuestCpuSnapshot *context = NULL;
    BOOL saved = NO;
    gva_t oldStret = GuestStretDestination();
    @try {
        if (self.kind == PortGuestDelegateAccelerometerKind &&
            !GuestMotionCallbackIsCurrent(vm, first, second)) return;
        gva_t imp = DelegateMethod(vm, self.guestAddress, self.guestClass, name, encoding);
        if (!imp) {
            GuestTrace(vm, @"[delegates] original callback %s unavailable for guest %#x", name, self.guestAddress);
            GuestRequestFault(vm);
            return;
        }
        GuestExecutionResult error = GuestCPUAllocate(vm, &context);
        if (error == GuestExecutionSuccess) error = GuestCPUSave(vm, context);
        if (error != GuestExecutionSuccess) {
            GuestTrace(vm, @"[delegates] cannot preserve guest CPU for %s: %s", name, GuestExecutionErrorText(error));
            GuestRequestFault(vm);
            return;
        }
        saved = YES;
        uint32_t args[4] = {self.guestAddress, GuestObjCGuestSelNamed(vm, name),
                            GuestObjCWrap(vm, first), 0};
        if (count == 4) args[3] = scalarSecond ? scalar : GuestObjCWrap(vm, second);
        if (!args[1]) {
            GuestTrace(vm, @"[delegates] cannot encode original selector %s", name);
            GuestRequestFault(vm);
            return;
        }
        // GuestCall saves registers before installing these arguments. A full
        // native CPU snapshot also preserves VFP/CPSR on synchronous native reentry.
        GuestCall(vm, imp, args, count, 2000000000ull);
    } @catch (NSException *exception) {
        GuestTrace(vm, @"[delegates] original callback %s failed: %@ %@", name, exception.name, exception.reason);
        GuestRequestFault(vm);
    } @finally {
        if (saved && GuestCPURestore(vm, context) != GuestExecutionSuccess) {
            GuestTrace(vm, @"[delegates] cannot restore guest CPU after %s", name);
            GuestRequestFault(vm);
        }
        GuestSetStretDestination(oldStret);
        if (context) GuestCPUFree(context);
        GuestUnlock(vm);
    }
}
- (void)deliver:(SEL)selector first:(id)first second:(id)second count:(int)count {
    [self invoke:selector first:first second:second count:count scalar:0 scalarSecond:NO];
}
- (void)deliverButton:(SEL)selector alert:(id)alert index:(NSInteger)index {
    if (index < INT32_MIN || index > INT32_MAX) {
        GuestVM *vm = self.vm;
        GuestTrace(vm, @"[delegates] UIAlertView button index does not fit Darwin32: %lld", (long long)index);
        GuestRequestFault(vm);
        return;
    }
    [self invoke:selector first:alert second:nil count:4 scalar:(uint32_t)(int32_t)index scalarSecond:YES];
}
@end

@interface PortGuestPaymentObserver : PortGuestDelegate
@end
@implementation PortGuestPaymentObserver
- (void)paymentQueue:(id)queue updatedTransactions:(id)transactions {
    [self deliver:_cmd first:queue second:transactions count:4];
}
- (void)paymentQueue:(id)queue restoreCompletedTransactionsFailedWithError:(id)error {
    [self deliver:_cmd first:queue second:error count:4];
}
- (void)paymentQueueRestoreCompletedTransactionsFinished:(id)queue {
    [self deliver:_cmd first:queue second:nil count:3];
}
@end

@interface PortGuestProductRequest : PortGuestDelegate
@end
@implementation PortGuestProductRequest
- (void)productsRequest:(id)request didReceiveResponse:(id)response {
    [self deliver:_cmd first:request second:response count:4];
}
- (void)request:(id)request didFailWithError:(id)error {
    [self deliver:_cmd first:request second:error count:4];
}
- (void)alertView:(id)alert didDismissWithButtonIndex:(NSInteger)index {
    [self deliverButton:_cmd alert:alert index:index];
}
@end

@interface PortGuestLinkGrabber : PortGuestDelegate
@end
@implementation PortGuestLinkGrabber
- (void)connection:(id)connection didReceiveResponse:(id)response {
    [self deliver:_cmd first:connection second:response count:4];
}
- (void)connection:(id)connection didReceiveData:(id)data {
    [self deliver:_cmd first:connection second:data count:4];
}
- (void)connection:(id)connection didFailWithError:(id)error {
    [self deliver:_cmd first:connection second:error count:4];
}
- (void)connectionDidFinishLoading:(id)connection {
    [self deliver:_cmd first:connection second:nil count:3];
}
@end

@interface PortGuestAccelerometerDelegate : PortGuestDelegate
@end
@implementation PortGuestAccelerometerDelegate
- (void)accelerometer:(id)accelerometer didAccelerate:(id)acceleration {
    // UIAcceleration remains the actual native object. The original IMP reads
    // x/y/z doubles and runs the original conversion and steering algorithms.
    [self deliver:_cmd first:accelerometer second:acceleration count:4];
}
@end

// A native API may store delegates weakly. Keep one proxy for each live VM and
// guest address so set/get/remove operations preserve the original identity.
static NSMapTable<GuestVM *, NSMutableDictionary<NSNumber *, PortGuestDelegate *> *> *g_delegateVMs;

extern "C" id GuestObjCDelegateProxy(GuestVM *vm, gva_t guestObject) {
    if (!vm || !guestObject || GuestIsHostObject(guestObject) || GuestIsHostClass(guestObject)) return nil;
    GuestLock(vm);
    id result = nil;
    @try {
        uint32_t guestClass = 0;
        if (!DelegateReadWord(vm, guestObject, &guestClass)) return nil;
        NSString *name = GuestObjCNameForClass(vm, guestClass);
        Class adapter = Nil;
        PortGuestDelegateKind kind = PortGuestDelegatePaymentObserverKind;
        if ([name isEqualToString:@"CStoreObserver"]) adapter = [PortGuestPaymentObserver class];
        else if ([name isEqualToString:@"CStore"]) { adapter = [PortGuestProductRequest class]; kind = PortGuestDelegateProductRequestKind; }
        else if ([name isEqualToString:@"StorekitLinkGrabber"]) { adapter = [PortGuestLinkGrabber class]; kind = PortGuestDelegateLinkGrabberKind; }
        else if ([name isEqualToString:@"Asphalt6AppDelegate"]) { adapter = [PortGuestAccelerometerDelegate class]; kind = PortGuestDelegateAccelerometerKind; }
        if (!adapter) return nil;
        @synchronized ([PortGuestDelegate class]) {
            if (!g_delegateVMs) g_delegateVMs = [NSMapTable weakToStrongObjectsMapTable];
            NSMutableDictionary *objects = [g_delegateVMs objectForKey:vm];
            if (!objects) { objects = [NSMutableDictionary dictionary]; [g_delegateVMs setObject:objects forKey:vm]; }
            PortGuestDelegate *proxy = objects[@(guestObject)];
            if (!proxy || proxy.guestClass != guestClass) {
                proxy = [[adapter alloc] init];
                proxy.vm = vm;
                proxy.guestAddress = guestObject;
                proxy.guestClass = guestClass;
                proxy.kind = kind;
                objects[@(guestObject)] = proxy;
            }
            result = proxy;
        }
    } @finally { GuestUnlock(vm); }
    return result;
}

extern "C" gva_t GuestObjCDelegateGuestAddress(GuestUnsafeId object) {
    // Do not bind arbitrary input to a strong id: even a type-checking ARC hop
    // would retain a real NSAutoreleasePool, which Foundation rejects.
    Class cls = object_getClass(object);
    if (cls != [PortGuestPaymentObserver class] && cls != [PortGuestProductRequest class] &&
        cls != [PortGuestLinkGrabber class] && cls != [PortGuestAccelerometerDelegate class]) return 0;
    PortGuestDelegate *__unsafe_unretained proxy = object;
    return proxy.vm ? proxy.guestAddress : 0;
}
