/* Native mathematical candidate, independently owned ARM instruction wrappers.
 * Mathematical implementation is the separately noticed SoftFloat derivative.
 * No instruction bytes, decoder, CPUARMState, p-code executor, or JIT are used.
 */
#include "as6_arm_float.h"
#include "as6_math_support.h"
#include "fpu/softfloat.h"
#include <string.h>

#define AS6_FPSCR_FLAGS UINT32_C(0x9f)
#define AS6_UNSUPPORTED_FPSCR (UINT32_C(0x9f00) | (7u << 16) | (3u << 20))

static uint32_t exception_bits(uint8_t flags) {
    uint32_t result = 0;
    if (flags & float_flag_invalid) result |= 1;
    if (flags & float_flag_divbyzero) result |= 2;
    if (flags & float_flag_overflow) result |= 4;
    if (flags & (float_flag_underflow | float_flag_output_denormal)) result |= 8;
    if (flags & float_flag_inexact) result |= 16;
    if (flags & float_flag_input_denormal) result |= 128;
    return result;
}

static uint8_t internal_flags(uint32_t fpscr) {
    uint8_t result = 0;
    if (fpscr & 1) result |= float_flag_invalid;
    if (fpscr & 2) result |= float_flag_divbyzero;
    if (fpscr & 4) result |= float_flag_overflow;
    if (fpscr & 8) result |= float_flag_underflow;
    if (fpscr & 16) result |= float_flag_inexact;
    if (fpscr & 128) result |= float_flag_input_denormal;
    return result;
}

static uint32_t begin(uint32_t fpscr, bool neon, as6_fp_result *out, float_status *status) {
    if (!out) return AS6_FP_INVALID_ARGUMENT;
    *out = (as6_fp_result){0, fpscr, 0};
    if (fpscr & AS6_UNSUPPORTED_FPSCR) return AS6_FP_UNSUPPORTED_ENVIRONMENT;
    static const int rounding[] = {
        float_round_nearest_even, float_round_up, float_round_down, float_round_to_zero,
    };
    *status = (float_status){0};
    status->float_detect_tininess = float_tininess_before_rounding;
    status->float_rounding_mode = neon ? float_round_nearest_even : rounding[(fpscr >> 22) & 3];
    status->float_exception_flags = internal_flags(fpscr);
    status->floatx80_rounding_precision = 80;
    status->flush_to_zero = neon || ((fpscr >> 24) & 1);
    status->flush_inputs_to_zero = neon || ((fpscr >> 24) & 1);
    status->default_nan_mode = neon || ((fpscr >> 25) & 1);
    return AS6_FP_OK;
}

static uint32_t finish(uint64_t bits, uint32_t fpscr, const float_status *status, as6_fp_result *out) {
    out->bits = bits;
    out->fpscr = (fpscr & ~AS6_FPSCR_FLAGS) | exception_bits(status->float_exception_flags);
    return AS6_FP_OK;
}

#define VFP_BINARY(name, type, helper) \
uint32_t name(type a, type b, uint32_t fpscr, as6_fp_result *out) { \
    float_status state; uint32_t status = begin(fpscr, false, out, &state); \
    if (status) return status; \
    return finish(helper(a, b, &state), fpscr, &state, out); \
}
VFP_BINARY(as6_vfp_div_f32, uint32_t, float32_div)
VFP_BINARY(as6_vfp_add_f64, uint64_t, float64_add)
VFP_BINARY(as6_vfp_sub_f64, uint64_t, float64_sub)
VFP_BINARY(as6_vfp_mul_f64, uint64_t, float64_mul)
VFP_BINARY(as6_vfp_div_f64, uint64_t, float64_div)
#undef VFP_BINARY

#define UNSUPPORTED_SCALAR(name) \
uint32_t name(uint32_t a, uint32_t b, uint32_t fpscr, as6_fp_result *out) { \
    (void)a; (void)b; \
    float_status state; uint32_t status = begin(fpscr, false, out, &state); \
    return status ? status : AS6_FP_UNSUPPORTED_OPERATION; \
}
UNSUPPORTED_SCALAR(as6_vfp_add_f32)
UNSUPPORTED_SCALAR(as6_vfp_sub_f32)
UNSUPPORTED_SCALAR(as6_vfp_mul_f32)
#undef UNSUPPORTED_SCALAR

#define VFP_UNARY(name, type, helper) \
uint32_t name(type a, uint32_t fpscr, as6_fp_result *out) { \
    float_status state; uint32_t status = begin(fpscr, false, out, &state); \
    if (status) return status; \
    return finish(helper(a, &state), fpscr, &state, out); \
}
VFP_UNARY(as6_vfp_sqrt_f32, uint32_t, float32_sqrt)
VFP_UNARY(as6_vfp_sqrt_f64, uint64_t, float64_sqrt)
VFP_UNARY(as6_vfp_f32_to_f64, uint32_t, float32_to_float64)
VFP_UNARY(as6_vfp_f64_to_f32, uint64_t, float64_to_float32)
VFP_UNARY(as6_vfp_u32_to_f32, uint32_t, uint32_to_float32)
#undef VFP_UNARY

uint32_t as6_vfp_s32_to_f32(uint32_t a, uint32_t fpscr, as6_fp_result *out) {
    float_status state; uint32_t status = begin(fpscr, false, out, &state);
    if (status) return status;
    int32_t signed_bits;
    memcpy(&signed_bits, &a, sizeof(a));
    return finish(int32_to_float32(signed_bits, &state), fpscr, &state, out);
}

uint32_t as6_vfp_f32_to_s32_rtz(uint32_t a, uint32_t fpscr, as6_fp_result *out) {
    float_status state; uint32_t status = begin(fpscr, false, out, &state);
    if (status) return status;
    uint32_t result;
    if (float32_is_any_nan(a)) {
        float_raise(float_flag_invalid, &state);
        result = 0;  /* ARM VFP special case, not generic SoftFloat saturation. */
    } else {
        result = (uint32_t)float32_to_int32_round_to_zero(a, &state);
    }
    return finish(result, fpscr, &state, out);
}

static unsigned compare_nzcv(int relation) {
    switch (relation) {
        case float_relation_less: return 8;
        case float_relation_equal: return 6;
        case float_relation_greater: return 2;
        case float_relation_unordered: return 3;
        default: as6_math_fatal(__FILE__, __LINE__);
    }
}

#define VFP_COMPARE(name, type, helper) \
uint32_t name(type a, type b, uint32_t fpscr, as6_fp_result *out) { \
    float_status state; uint32_t status = begin(fpscr, false, out, &state); \
    if (status) return status; \
    unsigned nzcv = compare_nzcv(helper(a, b, &state)); \
    return finish(nzcv, (fpscr & UINT32_C(0x0fffffff)) | ((uint32_t)nzcv << 28), &state, out); \
}
VFP_COMPARE(as6_vfp_cmp_f32, uint32_t, float32_compare_quiet)
VFP_COMPARE(as6_vfp_cmpe_f32, uint32_t, float32_compare)
VFP_COMPARE(as6_vfp_cmp_f64, uint64_t, float64_compare_quiet)
VFP_COMPARE(as6_vfp_cmpe_f64, uint64_t, float64_compare)
#undef VFP_COMPARE

#define VFP_BITS(name, type, expression) \
uint32_t name(type a, uint32_t fpscr, as6_fp_result *out) { \
    float_status state; uint32_t status = begin(fpscr, false, out, &state); \
    if (status) return status; \
    out->bits = (expression); return AS6_FP_OK; \
}
VFP_BITS(as6_vfp_neg_f32, uint32_t, a ^ UINT32_C(0x80000000))
VFP_BITS(as6_vfp_abs_f32, uint32_t, a & UINT32_C(0x7fffffff))
VFP_BITS(as6_vfp_neg_f64, uint64_t, a ^ UINT64_C(0x8000000000000000))
VFP_BITS(as6_vfp_abs_f64, uint64_t, a & UINT64_C(0x7fffffffffffffff))
#undef VFP_BITS

#define NEON_BINARY(name, helper) \
uint32_t name(uint64_t a, uint64_t b, uint32_t fpscr, as6_fp_result *out) { \
    float_status state; uint32_t status = begin(fpscr, true, out, &state); \
    if (status) return status; \
    uint64_t lo = helper((uint32_t)a, (uint32_t)b, &state); \
    uint64_t hi = helper((uint32_t)(a >> 32), (uint32_t)(b >> 32), &state); \
    return finish(lo | (hi << 32), fpscr, &state, out); \
}
NEON_BINARY(as6_neon_add_2f32, float32_add)
NEON_BINARY(as6_neon_sub_2f32, float32_sub)
NEON_BINARY(as6_neon_mul_2f32, float32_mul)
#undef NEON_BINARY

/* Extended forms with actual original ARM examples. See semantic-authority.json.
 * These are independently owned wrappers, not a CPU helper/decoder import.
 * Keep the operand order and intermediate bit-negations: algebraic rewrites
 * change ARM NaN priority/sign and two-stage rounding semantics.
 */
uint32_t as6_vfp_s32_to_f64(uint32_t a, uint32_t fpscr, as6_fp_result *out) {
    float_status state; uint32_t status = begin(fpscr, false, out, &state);
    if (status) return status;
    int32_t signed_bits; memcpy(&signed_bits, &a, sizeof(a));
    return finish(int32_to_float64(signed_bits, &state), fpscr, &state, out);
}

uint32_t as6_vfp_u32_to_f64(uint32_t a, uint32_t fpscr, as6_fp_result *out) {
    float_status state; uint32_t status = begin(fpscr, false, out, &state);
    if (status) return status;
    return finish(uint32_to_float64(a, &state), fpscr, &state, out);
}

#define ARM_EXT_FTOI(name, type, any_nan, convert) \
uint32_t name(type a, uint32_t fpscr, as6_fp_result *out) { \
    float_status state; uint32_t status = begin(fpscr, false, out, &state); \
    if (status) return status; \
    uint32_t result; \
    if (any_nan(a)) { float_raise(float_flag_invalid, &state); result = 0; } \
    else result = (uint32_t)convert(a, &state); \
    return finish(result, fpscr, &state, out); \
}
ARM_EXT_FTOI(as6_vfp_f64_to_s32_rtz, uint64_t, float64_is_any_nan, float64_to_int32_round_to_zero)
ARM_EXT_FTOI(as6_vfp_f32_to_u32_rtz, uint32_t, float32_is_any_nan, float32_to_uint32_round_to_zero)
ARM_EXT_FTOI(as6_vfp_f64_to_u32_rtz, uint64_t, float64_is_any_nan, float64_to_uint32_round_to_zero)
#undef ARM_EXT_FTOI

uint32_t as6_vfp_mla_f64(uint64_t d, uint64_t n, uint64_t m, uint32_t fpscr, as6_fp_result *out) {
    float_status state; uint32_t status = begin(fpscr, false, out, &state);
    if (status) return status;
    uint64_t product = float64_mul(n, m, &state);
    return finish(float64_add(d, product, &state), fpscr, &state, out);
}

uint32_t as6_vfp_mls_f32(uint32_t d, uint32_t n, uint32_t m, uint32_t fpscr, as6_fp_result *out) {
    float_status state; uint32_t status = begin(fpscr, false, out, &state);
    if (status) return status;
    uint32_t product = float32_mul(n, m, &state);
    product ^= UINT32_C(0x80000000);
    return finish(float32_add(d, product, &state), fpscr, &state, out);
}

uint32_t as6_vfp_mls_f64(uint64_t d, uint64_t n, uint64_t m, uint32_t fpscr, as6_fp_result *out) {
    float_status state; uint32_t status = begin(fpscr, false, out, &state);
    if (status) return status;
    uint64_t product = float64_mul(n, m, &state);
    product ^= UINT64_C(0x8000000000000000);
    return finish(float64_add(d, product, &state), fpscr, &state, out);
}

uint32_t as6_vfp_nmla_f32(uint32_t d, uint32_t n, uint32_t m, uint32_t fpscr, as6_fp_result *out) {
    float_status state; uint32_t status = begin(fpscr, false, out, &state);
    if (status) return status;
    uint32_t product = float32_mul(n, m, &state);
    product ^= UINT32_C(0x80000000);
    d ^= UINT32_C(0x80000000);
    return finish(float32_add(d, product, &state), fpscr, &state, out);
}

uint32_t as6_vfp_nmls_f64(uint64_t d, uint64_t n, uint64_t m, uint32_t fpscr, as6_fp_result *out) {
    float_status state; uint32_t status = begin(fpscr, false, out, &state);
    if (status) return status;
    uint64_t product = float64_mul(n, m, &state);
    d ^= UINT64_C(0x8000000000000000);
    return finish(float64_add(d, product, &state), fpscr, &state, out);
}

uint32_t as6_vfp_nmul_f32(uint32_t n, uint32_t m, uint32_t fpscr, as6_fp_result *out) {
    float_status state; uint32_t status = begin(fpscr, false, out, &state);
    if (status) return status;
    uint32_t product = float32_mul(n, m, &state);
    return finish(product ^ UINT32_C(0x80000000), fpscr, &state, out);
}
