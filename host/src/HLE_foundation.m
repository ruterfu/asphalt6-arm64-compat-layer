// Foundation C APIs have known Objective-C object return types. Return those
// objects through the same handle table used by objc_msgSend, independent of
// heap mappings, tagged pointers, or the generic native-pointer heuristic.
#import "HLE.h"
#import "GuestVM.h"
#import "GuestObjC.h"

HLE_DEFINE(hle_foundation_search_paths) {
    // Both typedefs are NSUInteger in Darwin: one32-bit guest word becomes
    // one64-bit native scalar. The original BOOL occupies its low byte.
    NSSearchPathDirectory directory = (NSSearchPathDirectory)(uint32_t)GuestArg(vm, 0);
    NSSearchPathDomainMask domains = (NSSearchPathDomainMask)(uint32_t)GuestArg(vm, 1);
    BOOL expandTilde = (uint8_t)GuestArg(vm, 2) != 0;
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(directory, domains, expandTilde);
    GuestSetRet(vm, GuestObjCWrap(vm, paths));
}
HLE_BIND("_NSSearchPathForDirectoriesInDomains", hle_foundation_search_paths)

HLE_DEFINE(hle_foundation_home_directory) {
    GuestSetRet(vm, GuestObjCWrap(vm, NSHomeDirectory()));
}
HLE_BIND("_NSHomeDirectory", hle_foundation_home_directory)

HLE_DEFINE(hle_foundation_temporary_directory) {
    GuestSetRet(vm, GuestObjCWrap(vm, NSTemporaryDirectory()));
}
HLE_BIND("_NSTemporaryDirectory", hle_foundation_temporary_directory)
