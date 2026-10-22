#include "as6_arm_float.h"
#include <stdio.h>
#include <string.h>
#include <stdint.h>
uint32_t ref_add(uint64_t,uint64_t,uint32_t,as6_fp_result*);
uint32_t ref_sub(uint64_t,uint64_t,uint32_t,as6_fp_result*);
uint32_t ref_mul(uint64_t,uint64_t,uint32_t,as6_fp_result*);
static uint64_t s=0x9e3779b97f4a7c15ull;
static uint64_t rnd(void){s^=s<<13;s^=s>>7;s^=s<<17;return s;}
static uint32_t pick(void){
    static const uint32_t special[]={0,0x80000000,0x00800000,0x80800000,0x00800001,0x007fffff,0x00000001,0x7f7fffff,0xff7fffff,0x7f800000,0xff800000,0x7fc00000,0x7f800001,0x3f800000,0xbf800000,0x20000000,0x1f800000,0x5f800000,0x3f800001,0x33800000,0x34000000};
    uint32_t r=(uint32_t)rnd();
    switch(rnd()%8){
    case 0: return special[rnd()%(sizeof special/4)];
    case 1: return (r&0x807fffff)|((uint32_t)(rnd()%6+60)<<23);   /* near the fast-path threshold */
    case 2: return (r&0x807fffff)|((uint32_t)(rnd()%8)<<23);      /* tiny / denormal */
    case 3: return (r&0x807fffff)|((uint32_t)(250+rnd()%6)<<23);  /* huge / inf / nan */
    case 4: return (r&0x80000000)|((r&0x7fffff)&~0xfffu)|((uint32_t)(120+rnd()%16)<<23); /* short mantissas: exact sums/products */
    default: return r;
    }
}
int main(void){
    typedef uint32_t (*fn)(uint64_t,uint64_t,uint32_t,as6_fp_result*);
    fn fast[]={as6_neon_add_2f32,as6_neon_sub_2f32,as6_neon_mul_2f32},ref[]={ref_add,ref_sub,ref_mul};
    const uint32_t fpscrs[]={0,0x10,0x03000000,0x03000010,0x9f,0x60,0x0300009f};
    unsigned long long n=0,bad=0;
    for(long i=0;i<60000000;i++){
        uint64_t a=((uint64_t)pick()<<32)|pick(),b=((uint64_t)pick()<<32)|pick();
        if(rnd()%4==0)b=(b&0xffffffff00000000ull)|((uint32_t)a^0x80000000); /* exact cancellation */
        uint32_t f=fpscrs[rnd()%7];int op=(int)(rnd()%3);
        as6_fp_result x,y;uint32_t sx=fast[op](a,b,f,&x),sy=ref[op](a,b,f,&y);n++;
        if(sx!=sy||memcmp(&x,&y,sizeof x)){if(bad++<10)printf("op%d a=%016llx b=%016llx fpscr=%08x fast=%016llx/%08x ref=%016llx/%08x\n",op,(unsigned long long)a,(unsigned long long)b,f,(unsigned long long)x.bits,x.fpscr,(unsigned long long)y.bits,y.fpscr);}
    }
    printf("%llu cases, %llu mismatches\n",n,bad);return bad!=0;
}
