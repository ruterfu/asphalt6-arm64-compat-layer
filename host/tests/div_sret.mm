// Reuse the genuine compiled tiny provider, data service and scheduling stubs.
#define main AS6YieldFixtureUnusedMain
// AS6_DIV_YIELD_FIXTURE
#undef main
#include <cstdlib>
#include <climits>
static int divGuestErrno;
void HLESetGuestErrno(GuestVM *,int value){divGuestErrno=value;}
// AS6_DIV_BYTE_HELPERS
// AS6_DIV_PRODUCTION

static bool SameCPU(const NativeState::Snapshot &a,const NativeState::Snapshot &b,bool ignoreR0=false){
    auto x=a.registers,y=b.registers;if(ignoreR0)for(unsigned i=0;i<4;++i)x[layout::r0+i]=y[layout::r0+i];
    return x==y&&a.pc==b.pc&&a.budget==b.budget&&a.status==b.status&&a.fault_address==b.fault_address;
}
static void Valid(int32_t a,int32_t b){
    auto *vm=Make();GuestLock(vm);auto &state=*GuestNativeCPUState(vm);
    GuestSetReg(vm,13,GuestSP(vm)-0x100);const gva_t out=GuestSP(vm)+0x48;
    uint8_t before[32];memset(before,0xa5,sizeof(before));CHECK(GuestWrite(vm,out-8,before,sizeof(before)));
    GuestSetReg(vm,0,out);GuestSetReg(vm,1,uint32_t(a));GuestSetReg(vm,2,uint32_t(b));GuestSetReg(vm,3,0xac9a4);
    GuestSetPC(vm,0x6a3478);GuestSetReg(vm,14,0xac8e4);state.context().budget=12345;current="_div";
    const auto cpu=state.save();const div_t reference=::div(a,b);hle_div(vm);
    CHECK(!GuestHasStopRequest(vm));CHECK(GuestReg(vm,0)==out);
    uint8_t after[32]{};CHECK(GuestRead(vm,out-8,after,sizeof(after)));
    memcpy(before+8,&reference.quot,4);memcpy(before+12,&reference.rem,4);CHECK(!memcmp(before,after,sizeof(before)));
    CHECK(SameCPU(cpu,state.save()));CHECK(GuestSP(vm)+0x48==out);
    GuestUnlock(vm);Dispose(vm);
}
static void Invalid(gva_t out,int32_t a,int32_t b,bool arithmetic){
    auto *vm=Make();GuestLock(vm);auto &state=*GuestNativeCPUState(vm);const auto stack=GuestSP(vm)-0x80;
    uint8_t canary[32];memset(canary,0x93,sizeof(canary));CHECK(GuestWrite(vm,stack,canary,sizeof(canary)));
    if(arithmetic)out=stack+8;
    GuestSetReg(vm,0,out);GuestSetReg(vm,1,uint32_t(a));GuestSetReg(vm,2,uint32_t(b));GuestSetReg(vm,3,0xac9a4);
    GuestSetPC(vm,0x6a3478);state.context().budget=321;const auto cpu=state.save();divGuestErrno=0;
    hle_div(vm);CHECK(GuestHasStopRequest(vm));CHECK(divGuestErrno==(arithmetic?EDOM:EFAULT));
    uint8_t after[32]{};CHECK(GuestRead(vm,stack,after,sizeof(after))&&!memcmp(after,canary,sizeof(after)));
    CHECK(GuestReadU32(vm,0x8000)==9);CHECK(SameCPU(cpu,state.save(),true));
    GuestUnlock(vm);Dispose(vm);
}
int main(){@autoreleasepool{
#ifdef AS6_DIV_BASELINE
    auto *vm=Make();GuestLock(vm);const auto out=GuestSP(vm)-0x80;uint32_t value[2]={0xa5a5a5a5,0xa5a5a5a5};GuestWrite(vm,out,value,8);
    GuestSetReg(vm,0,out);GuestSetReg(vm,1,123456789);GuestSetReg(vm,2,3600000);GuestSetReg(vm,3,0xac9a4);GuestSetPC(vm,0x6a3478);hle_div(vm);
    CHECK(GuestHasStopRequest(vm));CHECK(GuestReadU32(vm,out)==0xa5a5a5a5);NSString *trace=GuestTraceText(vm);
    CHECK([trace containsString:@"0x36ee80"]&&[trace containsString:@"0xac9a4"]);
    std::puts("{\"expected_original_failure_reproduced\":true,\"wrong_divisor_and_r3_code_writes_rejected\":true}");GuestUnlock(vm);Dispose(vm);
#else
    const int32_t cases[][2]={{0,1},{1,1},{10,3},{-10,3},{10,-3},{-10,-3},{42,7},{-42,7},{INT32_MIN,1},{INT32_MAX,-1},{INT32_MIN,INT32_MIN},{INT32_MAX,INT32_MAX},{123456789,3600000},{106789,60000},{123456,1000}};
    for(auto &pair:cases)Valid(pair[0],pair[1]);
    Invalid(0,7,0,true);Invalid(0,INT32_MIN,-1,true);
    for(gva_t out:{0u,0x1000u,0x8000u,0x8002u,0xfffffffcu})Invalid(out,7,3,false);
    std::printf("{\"passed\":true,\"checks\":%u,\"valid_arithmetic_cases\":15,\"controlled_invalid_cases\":7,\"production_div_and_byte_helpers\":true,\"real_native_VM\":true,\"game_executed\":false}\n",checks);
#endif
}}
