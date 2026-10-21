#pragma once
#include "native_program.hpp"

// Fixed compiled gap recovery around the current startup and product policy.
extern "C" const as6aot::NativeProgram *AS6NativeProgramWithRuntimeRecovery();
