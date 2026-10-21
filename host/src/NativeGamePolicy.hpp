#pragma once
#include "native_program.hpp"

// Fixed, compiled product policy around the immutable original-game program.
extern "C" const as6aot::NativeProgram *AS6NativeProgramWithGamePolicy();
