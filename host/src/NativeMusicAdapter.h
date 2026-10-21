#pragma once
#import "GuestVM.h"
typedef NS_ENUM(NSInteger,AS6NativeMusicBoundaryResult) {
    AS6NativeMusicOriginal=0,AS6NativeMusicHandled=1,AS6NativeMusicFailed=2,
};
#ifdef __cplusplus
extern "C" {
#endif
AS6NativeMusicBoundaryResult AS6NativeMusicHandleBoundary(GuestVM *vm,uint32_t pc);
void AS6NativeMusicForgetVM(GuestVM *vm);
#ifdef __cplusplus
}
#endif
