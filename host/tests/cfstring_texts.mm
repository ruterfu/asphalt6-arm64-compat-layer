#import "GuestObjC.h"
#import "GuestVM.h"
#include "NativeDataBundle.hpp"
#include "text-proofs.hpp"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <vector>

static std::vector<uint8_t> bytes(0x1000000), valid(0x1000000);
static uint32_t sectionBase, sectionSize;
static size_t reads, maxReadEnd;
extern "C" BOOL GuestRead(GuestVM *,gva_t address,void *out,size_t size) {
    ++reads;
    if (uint64_t(address)+size > bytes.size()) return NO;
    for (size_t i=0;i<size;++i) if (!valid[address+i]) return NO;
    maxReadEnd=std::max(maxReadEnd,size_t(address)+size);
    memcpy(out,bytes.data()+address,size); return YES;
}
extern "C" uint32_t GuestSectionAddress(GuestVM *,const char *name) {return strcmp(name,"__cfstring")?0:sectionBase;}
extern "C" uint32_t GuestSectionSize(GuestVM *,const char *name) {return strcmp(name,"__cfstring")?0:sectionSize;}
extern "C" BOOL GuestSectionContains(GuestVM *,const char *name,uint32_t address) {
    return !strcmp(name,"__cfstring") && address>=sectionBase && uint64_t(address)<uint64_t(sectionBase)+sectionSize;
}
static uint64_t fnv(NSData *data,size_t trailing) {
    uint64_t value=14695981039346656037ULL;
    const auto *p=static_cast<const uint8_t *>(data.bytes);
    for (size_t i=0;i<data.length;++i) {value^=p[i];value*=1099511628211ULL;}
    for (size_t i=0;i<trailing;++i)value*=1099511628211ULL;
    return value;
}
static void word(uint32_t address,uint32_t value) {memcpy(bytes.data()+address,&value,4);}

int main() { @autoreleasepool {
    const auto *manifest=AS6GeneratedDataManifest();
    for(size_t i=0;i<manifest->section_count;++i) {
        const auto &section=manifest->sections[i];
        if(!strcmp(section.name,"__cfstring")){sectionBase=section.address;sectionSize=section.size;}
    }
    assert(sectionBase&&sectionSize);
    for(size_t i=0;i<manifest->span_count;++i) {
        const auto &span=manifest->spans[i];assert(uint64_t(span.address)+span.length<=bytes.size());
        memset(valid.data()+span.address,1,span.length);
        if(span.bytes)memcpy(bytes.data()+span.address,span.bytes,span.length);
    }
    size_t eight=0,unicode=0,checks=0;
    for(const auto &proof:cf_text_proofs) {
        NSString *text=GuestObjCCFString(nil,proof.object);assert(text);
        auto encoding=proof.flags==0x7d0?NSUTF16LittleEndianStringEncoding:NSUTF8StringEncoding;
        NSData *encoded=[text dataUsingEncoding:encoding allowLossyConversion:NO];assert(encoded);
        const size_t content=proof.units*(proof.flags==0x7d0?2:1);
        assert(encoded.length==content&&fnv(encoded,proof.bytes-content)==proof.fnv);
        assert(content==0 || !memcmp(encoded.bytes,bytes.data()+proof.text,content));
        if(proof.flags==0x7d0){++unicode;assert(text.length==proof.units);}else ++eight;
        const uint8_t saved=valid[proof.text];valid[proof.text]=0;
        assert(content==0 || GuestObjCCFString(nil,proof.object)==nil);valid[proof.text]=saved;
        word(proof.object+4,0x7e8);assert(GuestObjCCFString(nil,proof.object)==nil);word(proof.object+4,proof.flags);
        word(proof.object+12,4097);assert(GuestObjCCFString(nil,proof.object)==nil);word(proof.object+12,proof.units);
        assert(GuestObjCCFString(nil,proof.object+1)==nil);checks+=7;
    }
    const auto &first=cf_text_proofs[0];
    word(first.object+8,0xffffffff);word(first.object+12,2);assert(!GuestObjCCFString(nil,first.object));
    word(first.object+8,first.text);word(first.object+12,first.units);
    valid[first.object+4]=0;assert(!GuestObjCCFString(nil,first.object));valid[first.object+4]=1;
    assert(!GuestObjCCFString(nil,0));assert(!GuestObjCCFString(nil,sectionBase+sectionSize));
    // The original __ustring section includes its final padding byte. Its
    // outer boundary remains invalid, and the string does not need padding
    // or a terminator beyond its explicitly recorded twelve UTF16 units.
    assert(valid[0x6ffffc]&&!valid[0x6ffffd]);
    maxReadEnd=0;NSString *last=GuestObjCCFString(nil,0x7163c8);assert(last&&last.length==12);
    valid[0x6ffffc]=0;assert([GuestObjCCFString(nil,0x7163c8) isEqualToString:last]);valid[0x6ffffc]=1;
    uint8_t byte=0xff;assert(GuestRead(nil,0x6ffffc,&byte,1)&&byte==0);
    byte=0xff;assert(!GuestRead(nil,0x6ffffd,&byte,1)&&byte==0xff);
    assert(eight==649&&unicode==142);checks+=11;
    printf("{\"passed\":true,\"original_cfstrings\":791,\"eight_bit\":649,\"utf16\":142,\"checks\":%zu,\"final_utf16_requires_no_terminator\":true,\"game_executed\":false}\n",checks);
} }
