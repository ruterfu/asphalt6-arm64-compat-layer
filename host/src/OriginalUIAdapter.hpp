#pragma once
#include <cstdint>
#ifdef __OBJC__
@class GuestVM;
#else
struct GuestVM;
#endif
extern "C" bool AS6OriginalUIBeforeAdvance(GuestVM *,std::uint32_t handler);
extern "C" bool AS6OriginalUIApply(GuestVM *,std::uint32_t handler);
extern "C" void AS6OriginalUIForgetVM(GuestVM *);
extern "C" bool AS6OriginalUIBeforeUnload(GuestVM *);
