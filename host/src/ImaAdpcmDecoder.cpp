#include "ImaAdpcmDecoder.hpp"

#include <algorithm>
#include <array>
#include <limits>
#include <stdexcept>

namespace as6::audio {
namespace {

constexpr std::array<int,89> Steps{
    7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,
    60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,
    337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,
    1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,
    5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,
    16818,18500,20350,22385,24623,27086,29794,32767
};
constexpr std::array<int,16> IndexChanges{-1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8};
struct Channel { int predictor, index; };

std::int16_t nibble(Channel &channel, unsigned value) noexcept {
    const int step = Steps[channel.index];
    int delta = step >> 3;
    if (value & 4) delta += step;
    if (value & 2) delta += step >> 1;
    if (value & 1) delta += step >> 2;
    channel.predictor = std::clamp(channel.predictor + ((value & 8) ? -delta : delta), -32768, 32767);
    channel.index = std::clamp(channel.index + IndexChanges[value], 0, 88);
    return static_cast<std::int16_t>(channel.predictor);
}

} // namespace

std::size_t ImaAdpcmDecoder::framesPerBlock(std::size_t bytes, unsigned channels) {
    if (channels != 1 && channels != 2) throw std::invalid_argument("IMA decoder supports one/two channels");
    const std::size_t group = 4 * channels;
    if (bytes < group || (bytes - group) % group)
        throw std::invalid_argument("IMA block requires headers and complete four-byte channel groups");
    const auto groups = (bytes - group) / group;
    if (groups > (std::numeric_limits<std::size_t>::max() - 1) / 8)
        throw std::length_error("IMA decoded frame count overflows");
    return 1 + groups * 8;
}

std::size_t ImaAdpcmDecoder::decodeBlock(const std::uint8_t *block,
                                        std::size_t bytes, unsigned channels,
                                        std::int16_t *output,
                                        std::size_t capacity) {
    const auto frames = framesPerBlock(bytes, channels);
    if (frames > std::numeric_limits<std::size_t>::max() / channels)
        throw std::length_error("IMA decoded sample count overflows");
    const auto samples = frames * channels;
    if (samples > std::numeric_limits<std::size_t>::max() / sizeof(std::int16_t) || capacity < samples)
        throw std::length_error("IMA output sample capacity is insufficient");
    if (!block || !output) throw std::invalid_argument("Null IMA input/output");
    const auto inputStart = reinterpret_cast<std::uintptr_t>(block);
    const auto outputStart = reinterpret_cast<std::uintptr_t>(output);
    const auto outputBytes = samples * sizeof(std::int16_t);
    if (bytes > std::numeric_limits<std::uintptr_t>::max() - inputStart ||
        outputBytes > std::numeric_limits<std::uintptr_t>::max() - outputStart)
        throw std::invalid_argument("IMA buffer address range overflows");
    if (inputStart < outputStart + outputBytes && outputStart < inputStart + bytes)
        throw std::invalid_argument("Overlapping IMA input/output");

    std::array<Channel,2> states{};
    for (unsigned channel = 0; channel < channels; ++channel) {
        const auto *header = block + 4 * channel;
        int predictor = int(header[0]) | (int(header[1]) << 8);
        if (predictor >= 32768) predictor -= 65536;
        if (header[2] > 88) throw std::invalid_argument("IMA header index outside0..88");
        states[channel] = {predictor,header[2]};
    }
    for (unsigned channel = 0; channel < channels; ++channel)
        output[channel] = static_cast<std::int16_t>(states[channel].predictor);

    std::size_t firstFrame = 1;
    for (std::size_t at = 4 * channels; at < bytes; at += 4 * channels, firstFrame += 8) {
        for (unsigned channel = 0; channel < channels; ++channel) {
            const auto *encoded = block + at + 4 * channel;
            for (unsigned byte = 0; byte < 4; ++byte) {
                output[(firstFrame + 2 * byte) * channels + channel] = nibble(states[channel], encoded[byte] & 15);
                output[(firstFrame + 2 * byte + 1) * channels + channel] = nibble(states[channel], encoded[byte] >> 4);
            }
        }
    }
    return frames;
}

} // namespace as6::audio
