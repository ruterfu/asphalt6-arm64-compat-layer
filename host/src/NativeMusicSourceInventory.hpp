#pragma once
#include <cstddef>
namespace as6_music_sources {
struct Pin {const char *source,*sha256;};
inline constexpr Pin Pins[]={
    {"src/audio/ApplePcmOutput.hpp","e0e1b57751f00c73cdf546b8ab675ffbf39aebf6f2fc9877b7b9c4a4ce8c82a8"},
    {"src/audio/ApplePcmOutput.mm","336929d309cb20e338facaf6863e13204ac225cb7464938a81a7f7159327e26b"},
    {"src/audio/ImaAdpcmDecoder.cpp","c1be0f9851b1afc292c28dc4a222387584b87a7be14abcb632d1c62c405d7211"},
    {"src/audio/ImaAdpcmDecoder.hpp","a884edd8647c6103a3546562d9b612e5a9241a6583800fa4168cc4adc1f99c34"},
    {"src/audio/MusicController.cpp","96d3d5d7b7609584ea75ba53bfb7972a383bc1c595937d6fef51d6998eca6956"},
    {"src/audio/MusicController.hpp","2f67b64befe447210cb8a6c51606781f443d89963394203818a71dc0118366e4"},
    {"src/audio/MusicRandomSelection.cpp","0b31978a88dee1a5e010fbb84bf9d3bc07f615d99ac6cf885405df92e9b01184"},
    {"src/audio/MusicRandomSelection.hpp","f4384d8665c787c73437355e53e92614e2d45e79f36f4e13eb23aa1b366519c5"},
    {"src/audio/MusicWorker.cpp","175ed2397e229a0a4fb8042b4b6632bb750d9813f73dc1ed8eead9fa476c268d"},
    {"src/audio/MusicWorker.hpp","f07ecb5a0952c6bae74d4a0db8e849df15b8022e0df3826c91733d0b657a30cb"},
    {"src/audio/NativeMusicAction.hpp","5fe98378ae7a3c01e7bc0c3478e081ffa823aaccc65c9eb5d4d33e18cfecf35b"},
    {"src/audio/NativeMusicCatalog.hpp","0b269d19b35076eb6165c9fe2cb2e26ce74a252b12fd4369295730a5c36cb316"},
    {"src/audio/NativeMusicService.cpp","e188b49e7ecd43d1a2cd989e870eca542d354ce25afc97e118c78cf4daa8d0fe"},
    {"src/audio/NativeMusicService.hpp","96972eeffccd991e3c1700aa26e4e1c5be0729fdcc856b0bb3ba036b7644d564"},
    {"src/audio/PcmClip.hpp","f8f2cc5e1940460fec999a8e8287a6017124c2fb1dde0a4eb90f756341c0e689"},
    {"src/audio/StoredAudioArchive.cpp","ea7c9b388328e31a139f27992151d06108b37bf918991e378e87a17700784f20"},
    {"src/audio/StoredAudioArchive.hpp","3cebde76a0293c9f668b135e89f467527881e4dfefb468907f72e1e84b47bca0"},
    {"src/audio/WaveImaClip.cpp","dff96936abbc815cc174f7badf9d33fa6503cbed4565887b1feeff847f80ecd3"},
    {"src/audio/WaveImaClip.hpp","a28500366512aad95d08b384636ff754536e2aadc80843699228ba6878bdc4c5"},
};
inline constexpr std::size_t Count=sizeof(Pins)/sizeof(Pins[0]);
}
