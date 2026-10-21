#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace as6_background {
class DecodedArtwork;
enum class Profile { Title269Phone45, Blue670Phone659Experimental, Title786ChinesePhone45 };
struct Crop { double x, y, width, height; };
struct Result {
  Crop art_crop{};
  double physical_aspect = 0;
  std::string cache_key;
  std::vector<uint8_t> original_layout_tga;
};
// Art is pinned, opaque, top-first BGRA decoded from the retained AI PNG.
// physical_width/height are the final landscape Host window dimensions, never
// the guest's fixed 320x480 UIScreen. No file, GL, guest-memory or UI access.
// Failure leaves result unmodified. Originals are never mutated.
bool Materialize(Profile profile, const uint8_t* original, size_t original_size,
                 const uint8_t* art_bgra, size_t art_size,
                 double physical_width, double physical_height,
                 bool allow_experimental_blue, Result& result, std::string& error);
// Authenticated JPEG decode; legacy raw-BGRA entry above stays SHA-pinned.
bool MaterializeDecoded(Profile, const uint8_t* original, size_t original_size,
                 const DecodedArtwork&, double physical_width, double physical_height,
                 bool allow_experimental_blue, Result&, std::string& error);
std::string Sha256(const uint8_t* data, size_t size);
}
