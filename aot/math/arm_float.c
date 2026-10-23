/* Native mathematical candidate, independently owned ARM instruction wrappers.
 * Mathematical implementation is the separately noticed SoftFloat derivative.
 * No instruction bytes, decoder, CPUARMState, p-code executor, or JIT are used.
 */
#include "as6_arm_float.h"
#include "as6_math_support.h"
#include "fpu/softfloat.h"
#include <math.h>
#include <stdbool.h>
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

/* Hardware fast paths. NEON arithmetic always runs flush-to-zero,
 * default-NaN, round-to-nearest; scalar VFP takes its rounding mode and
 * FZ/DN from the FPSCR. On normal or zero inputs with a normal (or exact
 * zero) result, rounding to nearest, none of FZ/DN can matter and the host
 * FPU (round-to-nearest, no flush) yields the same bits. The only flag such
 * an operation can raise is inexact, recovered exactly: from the rounding
 * error (TwoSum, or FMA for products, quotients and roots) or by converting
 * back. Anything else (another rounding mode, denormal, infinity, NaN,
 * overflow, results near the underflow threshold, out of range conversions)
 * takes the software path unchanged. tools/neon_fast_equivalence compares
 * every fast path with the software path bit for bit, FPSCR included. */
#if defined(__aarch64__) && !defined(AS6_NO_FAST_NEON)
#pragma clang fp contract(off)
#define AS6_FAST_FP 1
enum { FAST_ADD, FAST_SUB, FAST_MUL, FAST_DIV };

static inline float as_float(uint32_t x) { float f; memcpy(&f, &x, 4); return f; }
static inline uint32_t as_bits(float f) { uint32_t x; memcpy(&x, &f, 4); return x; }
static inline double as_double(uint64_t x) { double f; memcpy(&f, &x, 8); return f; }
static inline uint64_t as_bits64(double f) { uint64_t x; memcpy(&x, &f, 8); return x; }

/* Normal or zero. */
static inline bool fast_operand(uint32_t x) {
    const uint32_t exponent = (x >> 23) & 0xff;
    return (exponent != 0 && exponent != 0xff) || !(x & 0x7fffffffu);
}
static inline bool fast_operand64(uint64_t x) {
    const uint64_t exponent = (x >> 52) & 0x7ff;
    return (exponent != 0 && exponent != 0x7ff) || !(x & UINT64_C(0x7fffffffffffffff));
}
/* Not NaN and not denormal (infinities allowed). */
static inline bool ordered_operand(uint32_t x) {
    const uint32_t exponent = (x >> 23) & 0xff, mantissa = x & 0x7fffffu;
    return exponent == 0 ? !mantissa : exponent != 0xff || !mantissa;
}
static inline bool ordered_operand64(uint64_t x) {
    const uint64_t exponent = (x >> 52) & 0x7ff, mantissa = x & UINT64_C(0xfffffffffffff);
    return exponent == 0 ? !mantissa : exponent != 0x7ff || !mantissa;
}
/* No trap enables or vector length, and (for arithmetic) round to nearest. */
static inline bool fast_env(uint32_t fpscr, const as6_fp_result *out) { return out && !(fpscr & AS6_UNSUPPORTED_FPSCR); }
static inline bool fast_nearest(uint32_t fpscr, const as6_fp_result *out) { return fast_env(fpscr, out) && !((fpscr >> 22) & 3); }
static inline uint32_t fast_done(as6_fp_result *out, uint64_t bits, uint32_t fpscr, bool inexact) {
    *out = (as6_fp_result){bits, fpscr | (inexact ? 16u : 0u), 0};
    return AS6_FP_OK;
}

/* false: use the software path. Otherwise *result holds the lane and
 * *inexact whether rounding occurred (only computed when `need_inexact`, i.e.
 * the cumulative inexact flag is still clear). */
static inline bool fast_lane(int op, uint32_t a, uint32_t b, bool need_inexact, uint32_t *result, bool *inexact) {
    if (!fast_operand(a) || !fast_operand(b)) return false;
    const float x = as_float(a), y = as_float(b);
    float r, error = 0.0f;
    if (op == FAST_MUL) {
        r = x * y;
    } else if (op == FAST_DIV) {
        /* Division by zero; and a divisor small enough that the remainder
         * below could fall under the denormal grid and not be exact. */
        if (((b >> 23) & 0xff) < 100) return false;
        r = x / y;
    } else {
        const float addend = op == FAST_SUB ? -y : y;
        r = x + addend;
        if (need_inexact) {
            /* TwoSum: the exact rounding error of x + addend (no overflow here). */
            const float bv = r - x, av = r - bv;
            error = (x - av) + (addend - bv);
        }
    }
    const uint32_t bits = as_bits(r), exponent = (bits >> 23) & 0xff;
    if (exponent == 0xff) return false;                 /* overflow */
    if (exponent == 0) {
        if (bits & 0x7fffffffu) return false;           /* subnormal: FZ flushes */
        /* Exact zero: a cancelled sum, or a product or quotient with a zero
         * operand. A product or quotient of nonzero values that reached zero
         * underflowed. */
        if (op == FAST_MUL && (a & 0x7fffffffu) && (b & 0x7fffffffu)) return false;
        if (op == FAST_DIV && (a & 0x7fffffffu)) return false;
        *result = bits; *inexact = false; return true;
    }
    if (exponent < 64) return false;                    /* keep clear of tininess and FMA underflow */
    *result = bits;
    if (!need_inexact) { *inexact = false; return true; }
    if (op == FAST_MUL) error = fmaf(x, y, -r);         /* exact product error */
    else if (op == FAST_DIV) error = fmaf(r, y, -x);    /* exact remainder */
    *inexact = error != 0.0f; return true;
}
static inline bool fast_lane64(int op, uint64_t a, uint64_t b, bool need_inexact, uint64_t *result, bool *inexact) {
    if (!fast_operand64(a) || !fast_operand64(b)) return false;
    const double x = as_double(a), y = as_double(b);
    double r, error = 0.0;
    if (op == FAST_MUL) {
        r = x * y;
    } else if (op == FAST_DIV) {
        if (((b >> 52) & 0x7ff) < 948) return false;
        r = x / y;
    } else {
        const double addend = op == FAST_SUB ? -y : y;
        r = x + addend;
        if (need_inexact) {
            const double bv = r - x, av = r - bv;
            error = (x - av) + (addend - bv);
        }
    }
    const uint64_t bits = as_bits64(r), exponent = (bits >> 52) & 0x7ff;
    if (exponent == 0x7ff) return false;
    if (exponent == 0) {
        if (bits & UINT64_C(0x7fffffffffffffff)) return false;
        if (op == FAST_MUL && (a & UINT64_C(0x7fffffffffffffff)) && (b & UINT64_C(0x7fffffffffffffff))) return false;
        if (op == FAST_DIV && (a & UINT64_C(0x7fffffffffffffff))) return false;
        *result = bits; *inexact = false; return true;
    }
    if (exponent < 128) return false;
    *result = bits;
    if (!need_inexact) { *inexact = false; return true; }
    if (op == FAST_MUL) error = fma(x, y, -r);
    else if (op == FAST_DIV) error = fma(r, y, -x);
    *inexact = error != 0.0; return true;
}

static inline bool fast_neon(int op, uint64_t a, uint64_t b, uint32_t fpscr, as6_fp_result *out) {
    uint32_t lo, hi; bool lo_inexact, hi_inexact;
    const bool need_inexact = !(fpscr & 16u);
    if (!fast_lane(op, (uint32_t)a, (uint32_t)b, need_inexact, &lo, &lo_inexact) ||
        !fast_lane(op, (uint32_t)(a >> 32), (uint32_t)(b >> 32), need_inexact, &hi, &hi_inexact)) return false;
    fast_done(out, (uint64_t)lo | ((uint64_t)hi << 32), fpscr, lo_inexact || hi_inexact);
    return true;
}
/* d + sign_p * (n * m), the product rounded first; d negated first when
 * negate_d (MLS: product negated; NMLA: both; NMLS: d). */
static inline bool fast_multiply_add(uint32_t d, uint32_t n, uint32_t m, bool negate_p, bool negate_d, uint32_t fpscr, as6_fp_result *out) {
    uint32_t p, r; bool i1, i2;
    if (!fast_nearest(fpscr, out) || !fast_lane(FAST_MUL, n, m, !(fpscr & 16u), &p, &i1)) return false;
    if (negate_p) p ^= 0x80000000u;
    if (negate_d) d ^= 0x80000000u;
    if (!fast_lane(FAST_ADD, d, p, !(fpscr & 16u) && !i1, &r, &i2)) return false;
    fast_done(out, r, fpscr, i1 || i2); return true;
}
static inline bool fast_multiply_add64(uint64_t d, uint64_t n, uint64_t m, bool negate_p, bool negate_d, uint32_t fpscr, as6_fp_result *out) {
    uint64_t p, r; bool i1, i2;
    if (!fast_nearest(fpscr, out) || !fast_lane64(FAST_MUL, n, m, !(fpscr & 16u), &p, &i1)) return false;
    if (negate_p) p ^= UINT64_C(0x8000000000000000);
    if (negate_d) d ^= UINT64_C(0x8000000000000000);
    if (!fast_lane64(FAST_ADD, d, p, !(fpscr & 16u) && !i1, &r, &i2)) return false;
    fast_done(out, r, fpscr, i1 || i2); return true;
}
static inline bool fast_binary(int op, uint32_t a, uint32_t b, uint32_t fpscr, as6_fp_result *out) {
    uint32_t r; bool inexact;
    if (!fast_nearest(fpscr, out) || !fast_lane(op, a, b, !(fpscr & 16u), &r, &inexact)) return false;
    fast_done(out, r, fpscr, inexact); return true;
}
static inline bool fast_binary64(int op, uint64_t a, uint64_t b, uint32_t fpscr, as6_fp_result *out) {
    uint64_t r; bool inexact;
    if (!fast_nearest(fpscr, out) || !fast_lane64(op, a, b, !(fpscr & 16u), &r, &inexact)) return false;
    fast_done(out, r, fpscr, inexact); return true;
}
/* Square root of zero or a positive normal: the residual r*r - x is exact. */
static inline bool fast_sqrt(uint32_t a, uint32_t fpscr, as6_fp_result *out) {
    if (!fast_nearest(fpscr, out) || !fast_operand(a)) return false;
    if (!(a & 0x7fffffffu)) { fast_done(out, a, fpscr, false); return true; }  /* sqrt(+-0) = +-0 */
    if (a >> 31) return false;                                                 /* invalid */
    if (((a >> 23) & 0xff) < 64) return false;                                 /* keep the residual exact */
    const float x = as_float(a), r = sqrtf(x);
    fast_done(out, as_bits(r), fpscr, !(fpscr & 16u) && fmaf(r, r, -x) != 0.0f); return true;
}
static inline bool fast_sqrt64(uint64_t a, uint32_t fpscr, as6_fp_result *out) {
    if (!fast_nearest(fpscr, out) || !fast_operand64(a)) return false;
    if (!(a & UINT64_C(0x7fffffffffffffff))) { fast_done(out, a, fpscr, false); return true; }
    if (a >> 63) return false;
    if (((a >> 52) & 0x7ff) < 128) return false;
    const double x = as_double(a), r = sqrt(x);
    fast_done(out, as_bits64(r), fpscr, !(fpscr & 16u) && fma(r, r, -x) != 0.0); return true;
}
/* NZCV of an ordered comparison; no flag is raised without a NaN, and
 * without a denormal there is nothing for FZ to flush. */
static inline bool fast_compare(bool ordered, double x, double y, uint32_t fpscr, as6_fp_result *out) {
    if (!fast_env(fpscr, out) || !ordered) return false;
    const unsigned nzcv = x < y ? 8 : x == y ? 6 : 2;
    *out = (as6_fp_result){nzcv, (fpscr & UINT32_C(0x0fffffff)) | ((uint32_t)nzcv << 28), 0};
    return true;
}
/* Integer to float, rounded to nearest; inexact when it does not convert back. */
static inline bool fast_int_to_f32(bool is_signed, uint32_t a, uint32_t fpscr, as6_fp_result *out) {
    if (!fast_nearest(fpscr, out)) return false;
    int32_t si; memcpy(&si, &a, 4);
    const double exact = is_signed ? (double)si : (double)a;
    const float r = is_signed ? (float)si : (float)a;
    fast_done(out, as_bits(r), fpscr, (double)r != exact); return true;
}
/* Every 32-bit integer is exact in a double, whatever the rounding mode. */
static inline bool fast_int_to_f64(bool is_signed, uint32_t a, uint32_t fpscr, as6_fp_result *out) {
    if (!fast_env(fpscr, out)) return false;
    int32_t si; memcpy(&si, &a, 4);
    fast_done(out, as_bits64(is_signed ? (double)si : (double)a), fpscr, false); return true;
}
/* Truncation of an in-range value (rounding mode does not apply). */
static inline bool fast_to_int(bool is_signed, double x, bool ordered, uint32_t fpscr, as6_fp_result *out) {
    if (!fast_env(fpscr, out) || !ordered) return false;
    uint32_t r;
    if (is_signed) { if (!(x >= -2147483648.0 && x < 2147483648.0)) return false; const int32_t v = (int32_t)x; memcpy(&r, &v, 4); }
    else { if (!(x >= 0.0 && x < 4294967296.0) || signbit(x)) return false; r = (uint32_t)x; }
    const double back = is_signed ? (double)(int32_t)r : (double)r;
    fast_done(out, r, fpscr, back != x); return true;
}
/* Widening is exact for normals, zeros and infinities. */
static inline bool fast_f32_to_f64(uint32_t a, uint32_t fpscr, as6_fp_result *out) {
    if (!fast_env(fpscr, out) || !ordered_operand(a)) return false;
    fast_done(out, as_bits64((double)as_float(a)), fpscr, false); return true;
}
/* Narrowing to a normal float (clear of tininess) or an exact zero. */
static inline bool fast_f64_to_f32(uint64_t a, uint32_t fpscr, as6_fp_result *out) {
    if (!fast_nearest(fpscr, out) || !fast_operand64(a)) return false;
    const double x = as_double(a);
    const float r = (float)x;
    const uint32_t bits = as_bits(r), exponent = (bits >> 23) & 0xff;
    if (exponent == 0xff) return false;
    if (exponent < 2) { if ((bits & 0x7fffffffu) || (a & UINT64_C(0x7fffffffffffffff))) return false; }
    fast_done(out, bits, fpscr, (double)r != x); return true;
}
/* One lane of a NEON op whose other lane needs the software path (often an
 * unused lane holding a stale NaN or denormal): this lane still takes the
 * hardware when it can. Flags are sticky, so the order lanes raise them in
 * does not matter. */
static inline uint32_t neon_lane(int op, float32 (*helper)(float32, float32, float_status *),
                                 uint32_t a, uint32_t b, float_status *state) {
    uint32_t r; bool inexact;
    if (fast_lane(op, a, b, !(state->float_exception_flags & float_flag_inexact), &r, &inexact)) {
        if (inexact) state->float_exception_flags |= float_flag_inexact;
        return r;
    }
    return helper(a, b, state);
}
#define NEON_LANE(helper, op, a, b, state) neon_lane(op, helper, a, b, state)
#define FAST_IF(condition) if (condition) return AS6_FP_OK;
#else
#define NEON_LANE(helper, op, a, b, state) helper(a, b, state)
#define FAST_IF(condition)
#endif

#define VFP_BINARY(name, type, helper, fast) \
uint32_t name(type a, type b, uint32_t fpscr, as6_fp_result *out) { \
    FAST_IF(fast) \
    float_status state; uint32_t status = begin(fpscr, false, out, &state); \
    if (status) return status; \
    return finish(helper(a, b, &state), fpscr, &state, out); \
}
VFP_BINARY(as6_vfp_div_f32, uint32_t, float32_div, fast_binary(FAST_DIV, a, b, fpscr, out))
VFP_BINARY(as6_vfp_add_f64, uint64_t, float64_add, fast_binary64(FAST_ADD, a, b, fpscr, out))
VFP_BINARY(as6_vfp_sub_f64, uint64_t, float64_sub, fast_binary64(FAST_SUB, a, b, fpscr, out))
VFP_BINARY(as6_vfp_mul_f64, uint64_t, float64_mul, fast_binary64(FAST_MUL, a, b, fpscr, out))
VFP_BINARY(as6_vfp_div_f64, uint64_t, float64_div, fast_binary64(FAST_DIV, a, b, fpscr, out))
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

#define VFP_UNARY(name, type, helper, fast) \
uint32_t name(type a, uint32_t fpscr, as6_fp_result *out) { \
    FAST_IF(fast) \
    float_status state; uint32_t status = begin(fpscr, false, out, &state); \
    if (status) return status; \
    return finish(helper(a, &state), fpscr, &state, out); \
}
VFP_UNARY(as6_vfp_sqrt_f32, uint32_t, float32_sqrt, fast_sqrt(a, fpscr, out))
VFP_UNARY(as6_vfp_sqrt_f64, uint64_t, float64_sqrt, fast_sqrt64(a, fpscr, out))
VFP_UNARY(as6_vfp_f32_to_f64, uint32_t, float32_to_float64, fast_f32_to_f64(a, fpscr, out))
VFP_UNARY(as6_vfp_f64_to_f32, uint64_t, float64_to_float32, fast_f64_to_f32(a, fpscr, out))
VFP_UNARY(as6_vfp_u32_to_f32, uint32_t, uint32_to_float32, fast_int_to_f32(false, a, fpscr, out))
#undef VFP_UNARY

uint32_t as6_vfp_s32_to_f32(uint32_t a, uint32_t fpscr, as6_fp_result *out) {
    FAST_IF(fast_int_to_f32(true, a, fpscr, out))
    float_status state; uint32_t status = begin(fpscr, false, out, &state);
    if (status) return status;
    int32_t signed_bits;
    memcpy(&signed_bits, &a, sizeof(a));
    return finish(int32_to_float32(signed_bits, &state), fpscr, &state, out);
}

uint32_t as6_vfp_f32_to_s32_rtz(uint32_t a, uint32_t fpscr, as6_fp_result *out) {
    FAST_IF(fast_to_int(true, (double)as_float(a), ordered_operand(a), fpscr, out))
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

#define VFP_COMPARE(name, type, helper, fast) \
uint32_t name(type a, type b, uint32_t fpscr, as6_fp_result *out) { \
    FAST_IF(fast) \
    float_status state; uint32_t status = begin(fpscr, false, out, &state); \
    if (status) return status; \
    unsigned nzcv = compare_nzcv(helper(a, b, &state)); \
    return finish(nzcv, (fpscr & UINT32_C(0x0fffffff)) | ((uint32_t)nzcv << 28), &state, out); \
}
#define FAST_COMPARE32 fast_compare(ordered_operand(a) && ordered_operand(b), as_float(a), as_float(b), fpscr, out)
#define FAST_COMPARE64 fast_compare(ordered_operand64(a) && ordered_operand64(b), as_double(a), as_double(b), fpscr, out)
VFP_COMPARE(as6_vfp_cmp_f32, uint32_t, float32_compare_quiet, FAST_COMPARE32)
VFP_COMPARE(as6_vfp_cmpe_f32, uint32_t, float32_compare, FAST_COMPARE32)
VFP_COMPARE(as6_vfp_cmp_f64, uint64_t, float64_compare_quiet, FAST_COMPARE64)
VFP_COMPARE(as6_vfp_cmpe_f64, uint64_t, float64_compare, FAST_COMPARE64)
#undef FAST_COMPARE32
#undef FAST_COMPARE64
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

#define NEON_BINARY(name, helper, op) \
uint32_t name(uint64_t a, uint64_t b, uint32_t fpscr, as6_fp_result *out) { \
    FAST_IF(fast_env(fpscr, out) && fast_neon(op, a, b, fpscr, out)) \
    float_status state; uint32_t status = begin(fpscr, true, out, &state); \
    if (status) return status; \
    uint64_t lo = NEON_LANE(helper, op, (uint32_t)a, (uint32_t)b, &state); \
    uint64_t hi = NEON_LANE(helper, op, (uint32_t)(a >> 32), (uint32_t)(b >> 32), &state); \
    return finish(lo | (hi << 32), fpscr, &state, out); \
}
NEON_BINARY(as6_neon_add_2f32, float32_add, FAST_ADD)
NEON_BINARY(as6_neon_sub_2f32, float32_sub, FAST_SUB)
NEON_BINARY(as6_neon_mul_2f32, float32_mul, FAST_MUL)
#undef NEON_BINARY

/* Extended forms with actual original ARM examples. See semantic-authority.json.
 * These are independently owned wrappers, not a CPU helper/decoder import.
 * Keep the operand order and intermediate bit-negations: algebraic rewrites
 * change ARM NaN priority/sign and two-stage rounding semantics.
 */
uint32_t as6_vfp_s32_to_f64(uint32_t a, uint32_t fpscr, as6_fp_result *out) {
    FAST_IF(fast_int_to_f64(true, a, fpscr, out))
    float_status state; uint32_t status = begin(fpscr, false, out, &state);
    if (status) return status;
    int32_t signed_bits; memcpy(&signed_bits, &a, sizeof(a));
    return finish(int32_to_float64(signed_bits, &state), fpscr, &state, out);
}

uint32_t as6_vfp_u32_to_f64(uint32_t a, uint32_t fpscr, as6_fp_result *out) {
    FAST_IF(fast_int_to_f64(false, a, fpscr, out))
    float_status state; uint32_t status = begin(fpscr, false, out, &state);
    if (status) return status;
    return finish(uint32_to_float64(a, &state), fpscr, &state, out);
}

#define ARM_EXT_FTOI(name, type, any_nan, convert, fast) \
uint32_t name(type a, uint32_t fpscr, as6_fp_result *out) { \
    FAST_IF(fast) \
    float_status state; uint32_t status = begin(fpscr, false, out, &state); \
    if (status) return status; \
    uint32_t result; \
    if (any_nan(a)) { float_raise(float_flag_invalid, &state); result = 0; } \
    else result = (uint32_t)convert(a, &state); \
    return finish(result, fpscr, &state, out); \
}
ARM_EXT_FTOI(as6_vfp_f64_to_s32_rtz, uint64_t, float64_is_any_nan, float64_to_int32_round_to_zero,
             fast_to_int(true, as_double(a), ordered_operand64(a), fpscr, out))
ARM_EXT_FTOI(as6_vfp_f32_to_u32_rtz, uint32_t, float32_is_any_nan, float32_to_uint32_round_to_zero,
             fast_to_int(false, (double)as_float(a), ordered_operand(a), fpscr, out))
ARM_EXT_FTOI(as6_vfp_f64_to_u32_rtz, uint64_t, float64_is_any_nan, float64_to_uint32_round_to_zero,
             fast_to_int(false, as_double(a), ordered_operand64(a), fpscr, out))
#undef ARM_EXT_FTOI

uint32_t as6_vfp_mla_f64(uint64_t d, uint64_t n, uint64_t m, uint32_t fpscr, as6_fp_result *out) {
    FAST_IF(fast_multiply_add64(d, n, m, false, false, fpscr, out))
    float_status state; uint32_t status = begin(fpscr, false, out, &state);
    if (status) return status;
    uint64_t product = float64_mul(n, m, &state);
    return finish(float64_add(d, product, &state), fpscr, &state, out);
}

uint32_t as6_vfp_mls_f32(uint32_t d, uint32_t n, uint32_t m, uint32_t fpscr, as6_fp_result *out) {
    FAST_IF(fast_multiply_add(d, n, m, true, false, fpscr, out))
    float_status state; uint32_t status = begin(fpscr, false, out, &state);
    if (status) return status;
    uint32_t product = float32_mul(n, m, &state);
    product ^= UINT32_C(0x80000000);
    return finish(float32_add(d, product, &state), fpscr, &state, out);
}

uint32_t as6_vfp_mls_f64(uint64_t d, uint64_t n, uint64_t m, uint32_t fpscr, as6_fp_result *out) {
    FAST_IF(fast_multiply_add64(d, n, m, true, false, fpscr, out))
    float_status state; uint32_t status = begin(fpscr, false, out, &state);
    if (status) return status;
    uint64_t product = float64_mul(n, m, &state);
    product ^= UINT64_C(0x8000000000000000);
    return finish(float64_add(d, product, &state), fpscr, &state, out);
}

uint32_t as6_vfp_nmla_f32(uint32_t d, uint32_t n, uint32_t m, uint32_t fpscr, as6_fp_result *out) {
    FAST_IF(fast_multiply_add(d, n, m, true, true, fpscr, out))
    float_status state; uint32_t status = begin(fpscr, false, out, &state);
    if (status) return status;
    uint32_t product = float32_mul(n, m, &state);
    product ^= UINT32_C(0x80000000);
    d ^= UINT32_C(0x80000000);
    return finish(float32_add(d, product, &state), fpscr, &state, out);
}

uint32_t as6_vfp_nmls_f64(uint64_t d, uint64_t n, uint64_t m, uint32_t fpscr, as6_fp_result *out) {
    FAST_IF(fast_multiply_add64(d, n, m, false, true, fpscr, out))
    float_status state; uint32_t status = begin(fpscr, false, out, &state);
    if (status) return status;
    uint64_t product = float64_mul(n, m, &state);
    d ^= UINT64_C(0x8000000000000000);
    return finish(float64_add(d, product, &state), fpscr, &state, out);
}

uint32_t as6_vfp_nmul_f32(uint32_t n, uint32_t m, uint32_t fpscr, as6_fp_result *out) {
    FAST_IF(fast_binary(FAST_MUL, n, m, fpscr, out) && (out->bits ^= UINT32_C(0x80000000), true))
    float_status state; uint32_t status = begin(fpscr, false, out, &state);
    if (status) return status;
    uint32_t product = float32_mul(n, m, &state);
    return finish(product ^ UINT32_C(0x80000000), fpscr, &state, out);
}
#undef FAST_IF
