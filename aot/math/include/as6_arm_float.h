/* Explicit native ARM VFP/NEON mathematical candidate. Bit patterns, no code. */
#ifndef AS6_ARM_FLOAT_H
#define AS6_ARM_FLOAT_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define AS6_FP_API __attribute__((visibility("default")))
enum { AS6_FP_OK = 0, AS6_FP_INVALID_ARGUMENT = 1, AS6_FP_UNSUPPORTED_ENVIRONMENT = 2,
       AS6_FP_UNSUPPORTED_OPERATION = 3 };
typedef struct as6_fp_result {
    uint64_t bits;
    uint32_t fpscr;
    uint32_t reserved;
} as6_fp_result;
/* Calls reject trap-enable bits and legacy LEN/STRIDE. No caller FP state is used. */
#define AS6_FP_BINARY_DECL(name, type) \
AS6_FP_API uint32_t name(type a, type b, uint32_t fpscr, as6_fp_result *result)
#define AS6_FP_UNARY_DECL(name, type) \
AS6_FP_API uint32_t name(type a, uint32_t fpscr, as6_fp_result *result)
/* These three scalar forms return UNSUPPORTED_OPERATION: the frozen original
 * Listing contains no verified example. Two-lane NEON forms are supported. */
AS6_FP_BINARY_DECL(as6_vfp_add_f32, uint32_t);
AS6_FP_BINARY_DECL(as6_vfp_sub_f32, uint32_t);
AS6_FP_BINARY_DECL(as6_vfp_mul_f32, uint32_t);
AS6_FP_BINARY_DECL(as6_vfp_div_f32, uint32_t);
AS6_FP_BINARY_DECL(as6_vfp_add_f64, uint64_t);
AS6_FP_BINARY_DECL(as6_vfp_sub_f64, uint64_t);
AS6_FP_BINARY_DECL(as6_vfp_mul_f64, uint64_t);
AS6_FP_BINARY_DECL(as6_vfp_div_f64, uint64_t);
AS6_FP_UNARY_DECL(as6_vfp_sqrt_f32, uint32_t);
AS6_FP_UNARY_DECL(as6_vfp_sqrt_f64, uint64_t);
AS6_FP_UNARY_DECL(as6_vfp_neg_f32, uint32_t);
AS6_FP_UNARY_DECL(as6_vfp_abs_f32, uint32_t);
AS6_FP_UNARY_DECL(as6_vfp_neg_f64, uint64_t);
AS6_FP_UNARY_DECL(as6_vfp_abs_f64, uint64_t);
/* bits is the NZCV nibble; fpscr contains the updated architectural state. */
AS6_FP_BINARY_DECL(as6_vfp_cmp_f32, uint32_t);
AS6_FP_BINARY_DECL(as6_vfp_cmpe_f32, uint32_t);
AS6_FP_BINARY_DECL(as6_vfp_cmp_f64, uint64_t);
AS6_FP_BINARY_DECL(as6_vfp_cmpe_f64, uint64_t);
AS6_FP_UNARY_DECL(as6_vfp_f32_to_f64, uint32_t);
AS6_FP_UNARY_DECL(as6_vfp_f64_to_f32, uint64_t);
AS6_FP_UNARY_DECL(as6_vfp_s32_to_f32, uint32_t);
AS6_FP_UNARY_DECL(as6_vfp_u32_to_f32, uint32_t);
AS6_FP_UNARY_DECL(as6_vfp_f32_to_s32_rtz, uint32_t);
/* Two f32 lanes in a little-endian 64-bit D-register bit pattern. */
AS6_FP_BINARY_DECL(as6_neon_add_2f32, uint64_t);
AS6_FP_BINARY_DECL(as6_neon_sub_2f32, uint64_t);
AS6_FP_BINARY_DECL(as6_neon_mul_2f32, uint64_t);
#undef AS6_FP_BINARY_DECL
#undef AS6_FP_UNARY_DECL

/* Additive native extension. Inputs are original register bit patterns.
 * MLA/MLS/NMLA/NMLS take (old destination, Vn, Vm), in that exact order.
 * Their multiplication is rounded before the ordered addition (not fused). */
AS6_FP_API uint32_t as6_vfp_s32_to_f64(uint32_t a, uint32_t fpscr, as6_fp_result *result);
AS6_FP_API uint32_t as6_vfp_u32_to_f64(uint32_t a, uint32_t fpscr, as6_fp_result *result);
AS6_FP_API uint32_t as6_vfp_f64_to_s32_rtz(uint64_t a, uint32_t fpscr, as6_fp_result *result);
AS6_FP_API uint32_t as6_vfp_f32_to_u32_rtz(uint32_t a, uint32_t fpscr, as6_fp_result *result);
AS6_FP_API uint32_t as6_vfp_f64_to_u32_rtz(uint64_t a, uint32_t fpscr, as6_fp_result *result);
AS6_FP_API uint32_t as6_vfp_mla_f64(uint64_t d, uint64_t n, uint64_t m, uint32_t fpscr, as6_fp_result *result);
AS6_FP_API uint32_t as6_vfp_mls_f32(uint32_t d, uint32_t n, uint32_t m, uint32_t fpscr, as6_fp_result *result);
AS6_FP_API uint32_t as6_vfp_mls_f64(uint64_t d, uint64_t n, uint64_t m, uint32_t fpscr, as6_fp_result *result);
AS6_FP_API uint32_t as6_vfp_nmla_f32(uint32_t d, uint32_t n, uint32_t m, uint32_t fpscr, as6_fp_result *result);
AS6_FP_API uint32_t as6_vfp_nmls_f64(uint64_t d, uint64_t n, uint64_t m, uint32_t fpscr, as6_fp_result *result);
AS6_FP_API uint32_t as6_vfp_nmul_f32(uint32_t n, uint32_t m, uint32_t fpscr, as6_fp_result *result);
#ifdef __cplusplus
}
#endif
#endif
