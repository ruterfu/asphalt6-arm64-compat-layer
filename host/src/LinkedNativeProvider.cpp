#include "GuestNativeProvider.hpp"
#include "NavProvider.hpp"
#include "NativeDataBundle.hpp"
#include "NativeBuildConfig.hpp"
#include "NativeRuntimeRecovery.hpp"
#include "NativeSystemZlibProvider.hpp"
#include "NativeCollisionBoundary.hpp"
#include "NativeCollisionBoundary36.hpp"
#include "NativeVertexBoundary.hpp"
#include "NativeTrailBoundary.hpp"
#include "NativeCopyBoundary.hpp"
#include "NativeUIWorkBoundary.hpp"
#include "NativeSceneBoundary.hpp"
#include "NativeCollisionInverseBoundary.hpp"
#include <cstring>

extern "C" const char *as6_stream_abi_fingerprint();

extern "C" const as6native::Provider *AS6LinkedNativeProvider() {
    const char *actual = as6_stream_abi_fingerprint();
    if (!actual || std::strcmp(actual, AS6_EXPECTED_STREAM_ABI)) return nullptr;
    if (!AS6NativeProgramWithRuntimeRecovery()) return nullptr;
    static const as6native::Provider provider = [] {
        std::size_t count = 0;
        const auto *bridges = AS6GeneratedBridges(&count);
        return as6native::Provider{as6native::ProviderVersion, AS6NativeProgramWithRuntimeRecovery(),
            bridges, count, AS6GeneratedDataManifest(), AS6GeneratedEntry(), AS6_HOST_BUILD_ID};
    }();
    const as6native::Provider *linked=AS6ProviderWithSystemZlib(&provider);
    linked=as6_collision_boundary::withCollision(linked,{});
    linked=as6_collision36_boundary::withCollision(linked,{});
    linked=as6_vertex_boundary::withVertices(linked,{});
    linked=as6_trail_boundary::withTrails(linked,{});
    linked=as6_copy_boundary::withCopies(linked,{});
    linked=as6_ui_work_boundary::withWork(linked,{});
    linked=as6_scene_boundary::withScene(linked,{});
    linked=as6_collision_inverse_boundary::withInverse(linked,{});
    return as6_nav_vm::withNavigation(linked,{});
}
