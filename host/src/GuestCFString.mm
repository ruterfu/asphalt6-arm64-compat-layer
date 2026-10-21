#import "GuestObjC.h"
#import "GuestVM.h"

// Original CFConstantString is {isa, flags, characters, unitCount}. Its text
// is length-delimited; the final UTF16 object has no complete trailing NUL.
NSString *GuestObjCCFString(GuestVM *vm, gva_t address) {
    if (!address || !GuestSectionContains(vm, "__cfstring", address)) return nil;
    const uint32_t base = GuestSectionAddress(vm, "__cfstring");
    const uint32_t size = GuestSectionSize(vm, "__cfstring");
    if (address < base || size < 16 || address-base > size-16 || (address-base)%16) return nil;
    uint32_t fields[3] = {};
    if (!GuestRead(vm, address+4, fields, sizeof(fields))) return nil;
    const uint32_t flags = fields[0], chars = fields[1], units = fields[2];
    if ((flags != 0x7c8 && flags != 0x7d0) || !chars || units > 4096) return nil;
    const size_t bytes = size_t(units) * (flags == 0x7d0 ? 2 : 1);
    if (uint64_t(chars)+bytes > 0x100000000ULL || (flags == 0x7d0 && (chars&1))) return nil;
    if (!bytes) return @"";
    NSMutableData *buffer = [NSMutableData dataWithLength:bytes];
    if (!GuestRead(vm, chars, buffer.mutableBytes, bytes)) return nil;
    const NSStringEncoding encoding = flags == 0x7d0 ? NSUTF16LittleEndianStringEncoding : NSUTF8StringEncoding;
    return [[NSString alloc] initWithData:buffer encoding:encoding];
}
