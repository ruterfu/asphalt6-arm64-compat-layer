#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>
namespace as6_background {
// Owns immutable, opaque top-first sRGB BGRA pixels decoded from one pinned
// JPEG. Only the decoder can establish its source/legacy identity contract.
class DecodedArtwork {
public:
    const std::uint8_t *data() const { return pixels_.data(); }
    std::size_t size() const { return pixels_.size(); }
    unsigned width() const { return width_; }
    unsigned height() const { return height_; }
    bool matchesLegacy(const char *sha, unsigned width, unsigned height) const {
        return authenticated_ && sha && legacy_identity_ == sha && width_ == width && height_ == height &&
            pixels_.size() == std::size_t(width) * height * 4;
    }
    const std::string &legacyIdentity() const { return legacy_identity_; }
    const std::string &cacheIdentity() const { return cache_identity_; }
private:
    std::vector<std::uint8_t> pixels_;
    std::string legacy_identity_, cache_identity_;
    unsigned width_ = 0, height_ = 0;
    bool authenticated_ = false;
    friend bool DecodeArtworkJpeg(const char *, const std::uint8_t *, std::size_t,
                                 DecodedArtwork &, std::string &);
};
// Resource basename selects an exact compiled SHA/size/dimension pin. Failure
// preserves result. A successful object owns all decoded bytes independently.
bool DecodeArtworkJpeg(const char *resource_name, const std::uint8_t *jpeg,
                      std::size_t bytes, DecodedArtwork &result, std::string &error);
}
