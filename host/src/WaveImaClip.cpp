#include "WaveImaClip.hpp"
#include "ImaAdpcmDecoder.hpp"
#include <algorithm>
#include <array>
#include <cstring>
#include <limits>
#include <stdexcept>

namespace as6::audio {
namespace {
std::uint16_t u16(const std::uint8_t *p) {return p[0]|std::uint16_t(p[1])<<8;}
std::uint32_t u32(const std::uint8_t *p) {return p[0]|std::uint32_t(p[1])<<8|std::uint32_t(p[2])<<16|std::uint32_t(p[3])<<24;}
bool tag(const std::uint8_t *p,const char *value) {return std::memcmp(p,value,4)==0;}
[[noreturn]] void bad(const char *reason) {throw std::invalid_argument(reason);}
std::uint32_t crc32(const std::uint8_t *data,std::size_t size) {
    static const auto table=[] {
        std::array<std::uint32_t,256> values{};
        for(unsigned i=0;i<256;++i) {
            auto c=std::uint32_t(i);
            for(unsigned bit=0;bit<8;++bit)c=(c>>1)^((c&1)?0xedb88320u:0);
            values[i]=c;
        }
        return values;
    }();
    std::uint32_t value=0xffffffffu;
    for(std::size_t i=0;i<size;++i)value=(value>>8)^table[(value^data[i])&255];
    return value^0xffffffffu;
}
}

WaveImaInfo inspectWaveIma(const std::uint8_t *bytes,std::size_t size) {
    if(!bytes||size<12||!tag(bytes,"RIFF")||!tag(bytes+8,"WAVE"))bad("Not a RIFF/WAVE member");
    WaveImaInfo result;
    bool format=false,fact=false,data=false;
    std::uint32_t declaredFrames=0;
    std::size_t cursor=12;
    while(cursor<size) {
        if(size-cursor<8)bad("Truncated WAVE chunk header");
        const auto count=std::uint64_t(u32(bytes+cursor+4));
        const auto start=cursor+8;
        if(count>size-start)bad("WAVE chunk exceeds member");
        const auto *chunk=bytes+start;
        if(tag(bytes+cursor,"fmt ")) {
            if(format||count!=20)bad("Unsupported or duplicate WAVE format chunk");
            format=true;
            if(u16(chunk)!=0x11||u16(chunk+14)!=4||u16(chunk+16)!=2)
                bad("Unsupported WAVE codec contract");
            result.channels=u16(chunk+2);result.sampleRate=u32(chunk+4);result.blockBytes=u16(chunk+12);
            if(!result.sampleRate)bad("Zero WAVE sample rate");
            const auto frames=ImaAdpcmDecoder::framesPerBlock(result.blockBytes,result.channels);
            if(frames!=u16(chunk+18))bad("WAVE samples-per-block mismatch");
            result.framesPerBlock=std::uint32_t(frames);
        } else if(tag(bytes+cursor,"fact")) {
            if(fact||count!=4)bad("Unsupported or duplicate WAVE fact chunk");
            fact=true;declaredFrames=u32(chunk);
        } else if(tag(bytes+cursor,"data")) {
            if(data)bad("Duplicate WAVE data chunk");
            data=true;result.dataOffset=start;result.dataBytes=count;
        }
        const auto padded=count+(count&1);
        if(padded>size-start)bad("Missing WAVE chunk padding");
        cursor=start+std::size_t(padded);
    }
    if(!format||!fact||!data)bad("WAVE requires fmt, fact and data chunks");
    if(result.dataBytes%result.blockBytes)bad("Partial IMA block is unsupported");
    result.physicalFrames=(result.dataBytes/result.blockBytes)*result.framesPerBlock;
    result.validFrames=declaredFrames;
    if(result.validFrames>result.physicalFrames)bad("WAVE fact exceeds decoded frames");
    const auto declared=std::uint64_t(u32(bytes+4));
    const auto decodedBytes=result.validFrames*result.channels*2;
    result.originalRiffLength=declared==decodedBytes;
    if(declared!=size-8&&!result.originalRiffLength)bad("Unrecognized RIFF length mismatch");
    return result;
}

SharedPcmClip loadWaveImaClip(const StoredAudioArchive &archive,std::string_view name,WaveImaInfo *info) {
    const auto *entry=archive.findExact(name);
    if(!entry)throw ArchiveError(ArchiveErrorCode::MissingMember,"Music member is absent");
    if(entry->size>std::vector<std::uint8_t>().max_size())throw std::length_error("Music member is too large");
    std::vector<std::uint8_t> encoded(std::size_t(entry->size));
    archive.readRange(name,0,encoded.data(),encoded.size());
    if(crc32(encoded.data(),encoded.size())!=entry->crc32)throw std::runtime_error("Music member CRC mismatch");
    const auto format=inspectWaveIma(encoded.data(),encoded.size());
    auto output=std::make_shared<PcmClip>();
    output->sampleRate=format.sampleRate;output->channels=format.channels;output->frames=format.validFrames;
    if(format.validFrames>output->interleaved.max_size()/format.channels)throw std::length_error("Decoded music is too large");
    output->interleaved.resize(std::size_t(format.validFrames)*format.channels);
    std::vector<std::int16_t> block(std::size_t(format.framesPerBlock)*format.channels);
    std::uint64_t written=0;
    for(std::uint64_t offset=0;offset<format.dataBytes&&written<format.validFrames;offset+=format.blockBytes) {
        const auto frames=ImaAdpcmDecoder::decodeBlock(encoded.data()+format.dataOffset+offset,
            format.blockBytes,format.channels,block.data(),block.size());
        const auto take=std::min<std::uint64_t>(frames,format.validFrames-written);
        std::copy_n(block.data(),std::size_t(take)*format.channels,
                    output->interleaved.data()+std::size_t(written)*format.channels);
        written+=take;
    }
    if(written!=format.validFrames)throw std::runtime_error("Music decode ended early");
    if(info)*info=format;
    return output;
}
}
