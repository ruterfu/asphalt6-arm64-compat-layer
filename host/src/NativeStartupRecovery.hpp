#pragma once
#include "native_program.hpp"

// Fixed compiled supplement to the immutable original native archive.
// An overlap or missing compiled recovery instruction rejects the provider.
extern "C" const as6aot::NativeProgram *AS6NativeProgramWithStartupRecovery();
