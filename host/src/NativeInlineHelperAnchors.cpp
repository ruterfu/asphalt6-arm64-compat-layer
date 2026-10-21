// Emit only unchanged inline bodies from the frozen aot_support.hpp at -O1.
// Link this object before frozen O0 members to select these weak definitions.
// All data callbacks, bounds, fault/status semantics and caller locks remain
// those of the frozen header. No original instruction or guest ABI is added.
#include "aot_support.hpp"

namespace {
#define AS6_ANCHOR(name) [[gnu::used]] constexpr auto name##_anchor = &as6aot::name
AS6_ANCHOR(arm_condition_passed);
AS6_ANCHOR(mask);
AS6_ANCHOR(narrow);
AS6_ANCHOR(range);
AS6_ANCHOR(read_bytes);
AS6_ANCHOR(write_bytes);
AS6_ANCHOR(load);
AS6_ANCHOR(store);
AS6_ANCHOR(sign_extend);
AS6_ANCHOR(signed_less);
AS6_ANCHOR(shift_left);
AS6_ANCHOR(shift_right);
AS6_ANCHOR(shift_signed_right);
AS6_ANCHOR(carry);
AS6_ANCHOR(signed_carry);
AS6_ANCHOR(signed_borrow);
AS6_ANCHOR(signed_divide);
AS6_ANCHOR(population_count);
AS6_ANCHOR(leading_zero_count);
#undef AS6_ANCHOR
}
