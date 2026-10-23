/* Compares every hardware fast path in aot/math/arm_float.c with the pure
 * software path (built with AS6_NO_FAST_NEON, symbols prefixed ref_): status,
 * result bits and FPSCR must match exactly. */
#include "as6_arm_float.h"
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#define F2(n,t) uint32_t ref_##n(t,t,uint32_t,as6_fp_result*);
#define F1(n,t) uint32_t ref_##n(t,uint32_t,as6_fp_result*);
#define F3(n,t) uint32_t ref_##n(t,t,t,uint32_t,as6_fp_result*);
F2(as6_vfp_div_f32,uint32_t) F2(as6_vfp_add_f64,uint64_t) F2(as6_vfp_sub_f64,uint64_t) F2(as6_vfp_mul_f64,uint64_t)
F2(as6_vfp_div_f64,uint64_t) F1(as6_vfp_sqrt_f32,uint32_t) F1(as6_vfp_sqrt_f64,uint64_t) F1(as6_vfp_f32_to_f64,uint32_t)
F1(as6_vfp_f64_to_f32,uint64_t) F1(as6_vfp_u32_to_f32,uint32_t) F1(as6_vfp_s32_to_f32,uint32_t) F1(as6_vfp_f32_to_s32_rtz,uint32_t)
F2(as6_vfp_cmp_f32,uint32_t) F2(as6_vfp_cmpe_f32,uint32_t) F2(as6_vfp_cmp_f64,uint64_t) F2(as6_vfp_cmpe_f64,uint64_t)
F2(as6_neon_add_2f32,uint64_t) F2(as6_neon_sub_2f32,uint64_t) F2(as6_neon_mul_2f32,uint64_t)
F1(as6_vfp_s32_to_f64,uint32_t) F1(as6_vfp_u32_to_f64,uint32_t) F1(as6_vfp_f64_to_s32_rtz,uint64_t)
F1(as6_vfp_f32_to_u32_rtz,uint32_t) F1(as6_vfp_f64_to_u32_rtz,uint64_t)
F3(as6_vfp_mla_f64,uint64_t) F3(as6_vfp_mls_f32,uint32_t) F3(as6_vfp_mls_f64,uint64_t) F3(as6_vfp_nmla_f32,uint32_t)
F3(as6_vfp_nmls_f64,uint64_t) F2(as6_vfp_nmul_f32,uint32_t)

static uint64_t s=0x9e3779b97f4a7c15ull;
static uint64_t rnd(void){s^=s<<13;s^=s>>7;s^=s<<17;return s;}
static uint32_t f32(void){
    static const uint32_t special[]={0,0x80000000,0x00800000,0x80800000,0x00800001,0x007fffff,0x00000001,0x7f7fffff,0xff7fffff,
        0x7f800000,0xff800000,0x7fc00000,0x7f800001,0xffc00001,0x3f800000,0xbf800000,0x20000000,0x1f800000,0x5f800000,0x3f800001,
        0x33800000,0x34000000,0x4f000000,0xcf000000,0x4f800000,0x4effffff,0xcf000001,0x4f7fffff,0x3f000000,0xbf000000,0xbf7fffff};
    uint32_t r=(uint32_t)rnd();
    switch(rnd()%10){
    case 0: return special[rnd()%(sizeof special/4)];
    case 1: return (r&0x807fffff)|((uint32_t)(rnd()%8+60)<<23);   /* near the fast-path thresholds */
    case 2: return (r&0x807fffff)|((uint32_t)(rnd()%8)<<23);      /* tiny / denormal */
    case 3: return (r&0x807fffff)|((uint32_t)(248+rnd()%8)<<23);  /* huge / inf / nan */
    case 4: return (r&0x80000000)|((r&0x7fffff)&~0xfffu)|((uint32_t)(120+rnd()%16)<<23); /* short mantissas: exact results */
    case 5: return (r&0x807fffff)|((uint32_t)(96+rnd()%8)<<23);   /* near the divisor threshold */
    case 6: return (r&0x807fffff)|((uint32_t)(150+rnd()%8)<<23);  /* near the integer range */
    default: return r;
    }
}
static uint64_t f64(void){
    static const uint64_t special[]={0,0x8000000000000000ull,0x0010000000000000ull,0x000fffffffffffffull,1,0x7fefffffffffffffull,
        0x7ff0000000000000ull,0xfff0000000000000ull,0x7ff8000000000000ull,0x7ff0000000000001ull,0x3ff0000000000000ull,
        0xbff0000000000000ull,0x41e0000000000000ull,0xc1e0000000000000ull,0x41f0000000000000ull,0x41dfffffffffffffull,
        0xc1e0000000200000ull,0x41efffffffe00000ull,0x47efffffe0000000ull,0x47efffff10000000ull,0x3810000000000000ull,0x380fffffffffffffull,
        0x36a0000000000000ull,0x3690000000000000ull,0x3fe0000000000000ull};
    uint64_t r=rnd();
    switch(rnd()%10){
    case 0: return special[rnd()%(sizeof special/8)];
    case 1: return (r&0x800fffffffffffffull)|((uint64_t)(rnd()%8+124)<<52);
    case 2: return (r&0x800fffffffffffffull)|((uint64_t)(rnd()%8)<<52);
    case 3: return (r&0x800fffffffffffffull)|((uint64_t)(2040+rnd()%8)<<52);
    case 4: return (r&0x8000000000000000ull)|((r&0xfffffffffffffull)&~0xffffffffffull)|((uint64_t)(1016+rnd()%16)<<52);
    case 5: return (r&0x800fffffffffffffull)|((uint64_t)(944+rnd()%8)<<52);
    case 6: return (r&0x800fffffffffffffull)|((uint64_t)(892+rnd()%24)<<52);  /* float range edges */
    case 7: return (r&0x800fffffffffffffull)|((uint64_t)(1050+rnd()%8)<<52); /* integer range edges */
    case 8: { /* exactly a float, sometimes a denormal one */ uint32_t x=f32(); float f; memcpy(&f,&x,4); double d=f; uint64_t b; memcpy(&b,&d,8); return b; }
    default: return r;
    }
}
static uint32_t i32(void){static const uint32_t sp[]={0,1,0xffffffff,0x80000000,0x7fffffff,0x01000000,0x01000001,0xff000001,0x00ffffff};
    return rnd()%4==0?sp[rnd()%9]:(uint32_t)(rnd()>>(rnd()%40));}
static uint32_t fpscr(void){
    static const uint32_t base[]={0,0x10,0x03000000,0x03000010,0x9f,0x60,0x0300009f,0x00400000,0x00800000,0x00c00000,0x01000000,0x02000000,0xf0000000,0x0f800000};
    return base[rnd()%14];
}
static unsigned long long n,bad;
static void check(const char *name,uint32_t sx,as6_fp_result x,uint32_t sy,as6_fp_result y){
    n++;
    if(sx!=sy||x.bits!=y.bits||x.fpscr!=y.fpscr||x.reserved!=y.reserved){
        if(bad++<20)printf("%s: fast=%u %016llx/%08x ref=%u %016llx/%08x\n",name,sx,(unsigned long long)x.bits,x.fpscr,sy,(unsigned long long)y.bits,y.fpscr);
    }
}
#define T2(fn,gen) {__typeof__(gen) a=gen,b=gen;if(rnd()%5==0)b=a;uint32_t f=fpscr();as6_fp_result x,y;memset(&x,0x5a,sizeof x);memset(&y,0x5a,sizeof y);uint32_t sx=fn(a,b,f,&x),sy=ref_##fn(a,b,f,&y);check(#fn,sx,x,sy,y);}
#define T1(fn,gen) {__typeof__(gen) a=gen;uint32_t f=fpscr();as6_fp_result x,y;memset(&x,0x5a,sizeof x);memset(&y,0x5a,sizeof y);uint32_t sx=fn(a,f,&x),sy=ref_##fn(a,f,&y);check(#fn,sx,x,sy,y);}
#define T3(fn,gen) {__typeof__(gen) d=gen,a=gen,b=gen;uint32_t f=fpscr();as6_fp_result x,y;memset(&x,0x5a,sizeof x);memset(&y,0x5a,sizeof y);uint32_t sx=fn(d,a,b,f,&x),sy=ref_##fn(d,a,b,f,&y);check(#fn,sx,x,sy,y);}
static uint64_t pair(void){uint64_t a=((uint64_t)f32()<<32)|f32();return a;}
int main(int argc,char**argv){
    long rounds=argc>1?atol(argv[1]):2000000;
    for(long i=0;i<rounds;i++){
        T2(as6_vfp_div_f32,f32()) T2(as6_vfp_add_f64,f64()) T2(as6_vfp_sub_f64,f64()) T2(as6_vfp_mul_f64,f64()) T2(as6_vfp_div_f64,f64())
        T1(as6_vfp_sqrt_f32,f32()) T1(as6_vfp_sqrt_f64,f64()) T1(as6_vfp_f32_to_f64,f32()) T1(as6_vfp_f64_to_f32,f64())
        T1(as6_vfp_u32_to_f32,i32()) T1(as6_vfp_s32_to_f32,i32()) T1(as6_vfp_f32_to_s32_rtz,f32())
        T2(as6_vfp_cmp_f32,f32()) T2(as6_vfp_cmpe_f32,f32()) T2(as6_vfp_cmp_f64,f64()) T2(as6_vfp_cmpe_f64,f64())
        T2(as6_neon_add_2f32,pair()) T2(as6_neon_sub_2f32,pair()) T2(as6_neon_mul_2f32,pair())
        T1(as6_vfp_s32_to_f64,i32()) T1(as6_vfp_u32_to_f64,i32()) T1(as6_vfp_f64_to_s32_rtz,f64())
        T1(as6_vfp_f32_to_u32_rtz,f32()) T1(as6_vfp_f64_to_u32_rtz,f64())
        T3(as6_vfp_mla_f64,f64()) T3(as6_vfp_mls_f32,f32()) T3(as6_vfp_mls_f64,f64()) T3(as6_vfp_nmla_f32,f32())
        T3(as6_vfp_nmls_f64,f64()) T2(as6_vfp_nmul_f32,f32())
    }
    printf("%llu cases, %llu mismatches\n",n,bad);return bad!=0;
}
