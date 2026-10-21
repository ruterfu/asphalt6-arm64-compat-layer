// Existing baseline VM fixtures already supply their own scheduler hooks.
// Actual owner retirement is checked by the separate real pthread/VM probes.
#include <TargetConditionals.h>
#if !TARGET_OS_OSX || !defined(AS6_MACOS_MOTION_ABSENCE_FIXTURE) || !defined(AS6_NAV_BASELINE_SUPPORT_ABSENCE)
#error This scheduler absence is restricted to the declared macOS baseline fixtures
#endif
#include <cstdint>
extern "C" void HLEPthreadForgetCPUOwner(std::uint64_t) {}
