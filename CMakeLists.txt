cmake_minimum_required(VERSION 3.20)
project(Asphalt6Arm64Compat LANGUAGES C CXX)

# Sources produced from the user's own game copy by scripts/buildGame.py.
set(AS6_GENERATED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/generated" CACHE PATH
    "Directory with aot/, host/ and NativeDataBundle.cpp produced by scripts/buildGame.py")
set(AS6_HOST_BUILD_ID "compat-layer" CACHE STRING "Build identity reported in diagnostics")

if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    message(FATAL_ERROR "The compatibility layer requires Clang")
endif()
foreach(AS6_REQUIRED aot/program.cpp host/NativeDataBundle.cpp)
    if(NOT EXISTS "${AS6_GENERATED_DIR}/${AS6_REQUIRED}")
        message(FATAL_ERROR "Missing ${AS6_GENERATED_DIR}/${AS6_REQUIRED}; run scripts/buildGame.py first")
    endif()
endforeach()

# Software floating point used for bit-exact ARMv7 VFP/NEON semantics.
add_library(as6_aot_math STATIC
    aot/math/arm_float.c
    aot/math/support/fatal.c
    aot/math/vendor/fpu/softfloat.c)
set_target_properties(as6_aot_math PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED YES)
target_include_directories(as6_aot_math PUBLIC aot/math/include
    PRIVATE aot/math/support aot/math/vendor/include)
target_compile_definitions(as6_aot_math PRIVATE TARGET_ARM=1 AS6_FORCE_SOFTFLOAT=1)
target_compile_options(as6_aot_math PRIVATE
    -O2 -UNDEBUG -fno-fast-math -ffp-contract=off -fvisibility=hidden -fno-common)

# Translated program modules.
file(GLOB AS6_AOT_SOURCES CONFIGURE_DEPENDS "${AS6_GENERATED_DIR}/aot/*.cpp")
add_library(as6_aot_program STATIC ${AS6_AOT_SOURCES})
target_compile_features(as6_aot_program PUBLIC cxx_std_17)
target_include_directories(as6_aot_program PUBLIC aot/runtime)
target_link_libraries(as6_aot_program PUBLIC as6_aot_math)
target_compile_options(as6_aot_program PRIVATE
    -O2 -fno-strict-aliasing -fno-exceptions -fno-rtti
    -fno-fast-math -ffp-contract=off -fvisibility=hidden
    -fvisibility-inlines-hidden -Wno-unused-label -Wno-unused-but-set-variable)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set_source_files_properties("${AS6_GENERATED_DIR}/aot/native_02543.cpp"
        "${AS6_GENERATED_DIR}/aot/native_02957.cpp" PROPERTIES COMPILE_OPTIONS "-fno-slp-vectorize")
endif()

if(NOT APPLE OR NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    return()
endif()

# iOS host: system bridges, rendering, audio, input and UI adaptation.
enable_language(OBJCXX)
file(GLOB AS6_HOST_SOURCES CONFIGURE_DEPENDS host/src/*.cpp host/src/*.m host/src/*.mm)
file(GLOB AS6_HOST_GENERATED CONFIGURE_DEPENDS "${AS6_GENERATED_DIR}/host/*.cpp")
file(GLOB AS6_HOST_OBJC_SOURCES CONFIGURE_DEPENDS host/src/*.m host/src/*.mm host/app/*.mm)
set_source_files_properties(${AS6_HOST_OBJC_SOURCES} PROPERTIES
    LANGUAGE OBJCXX COMPILE_OPTIONS "-fobjc-arc;-fblocks")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/NativeBuildConfig.hpp"
    "#pragma once\n#define AS6_EXPECTED_STREAM_ABI \"1c80fe5c2eb7ddf38d5b63ee026a9c4d5714b6379c160631fa80745ec7dbc840\"\n#define AS6_HOST_BUILD_ID \"${AS6_HOST_BUILD_ID}\"\n")
add_library(as6_ios_host STATIC ${AS6_HOST_SOURCES} ${AS6_HOST_GENERATED} host/app/NativeApp.mm)
set_target_properties(as6_ios_host PROPERTIES CXX_STANDARD 17 OBJCXX_STANDARD 17)
target_include_directories(as6_ios_host PRIVATE host/src aot/runtime "${CMAKE_CURRENT_BINARY_DIR}")
target_compile_options(as6_ios_host PRIVATE -O2 -fno-fast-math -ffp-contract=off
    -fno-strict-aliasing -fvisibility=hidden -fvisibility-inlines-hidden)
target_link_libraries(as6_ios_host PUBLIC as6_aot_program z objc)
