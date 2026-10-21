#pragma once
#import "GuestVM.h"
#ifdef __cplusplus
extern "C" {
#endif
BOOL GuestAudioProducerNeedsService(void);
// Non-RT operation, only after HLEPthreadBlockingCall released the VM lock.
int GuestAudioWaitForProducerTurn(void);
// Balanced token for a tagged producer restoring VM locks after a host wait.
// Nested/non-producer calls return NO; End must receive the owning token.
BOOL GuestAudioProducerBeginResumeWait(GuestVM *vm);
void GuestAudioProducerEndResumeWait(GuestVM *vm,BOOL registered);
// Only the captured original refcon+4 mutex may use cancellable polling.
BOOL GuestAudioProducerIsMutexWait(GuestVM *vm,uint32_t mutex);
BOOL GuestAudioProducerCancelMutexWait(GuestVM *vm,uint32_t mutex);
// Call only if that exact mutex has NOT been acquired.
void GuestAudioProducerMarkCancelled(void);
// Query, not consume; remains true until GuestCall and CPU restore completed.
BOOL GuestAudioProducerWasCancelled(GuestVM *vm);
#ifdef __cplusplus
}
#endif
