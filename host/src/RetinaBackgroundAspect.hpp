#pragma once
#include "BackgroundAspect.hpp"

namespace as6_retina_background {
enum class Profile : unsigned {
 Title000719=719, TitleChinese000494=494, Endrace000629=629,
 Loading000272=272, Loading000765=765, Loading000847=847,
 Loading000695=695, Loading000285=285, Loading000676=676,
 Loading000754=754, Loading000883=883, Loading000620=620,
 Loading000641=641, Loading000464=464, Loading000234=234
};
struct NominalBitmap {unsigned width, height;};
using Result=as6_background::Result;
// Pure raster materialization for the exact original HD inputs and qualified
// phone SWFs45/736/659. The caller supplies that SWF's fixed nominal bitmap
// dimensions, not the actual HD texture size. No guest/GL/file/UI access.
// Both nominal-contract and full-source SHA gates must pass. Every byte outside
// the approved HD background mask remains original; failure preserves result.
bool Materialize(Profile, const uint8_t* original, size_t original_size,
 const uint8_t* top_bgra, size_t art_size, NominalBitmap,
 double physical_width, double physical_height, Result&, std::string& error);
bool MaterializeDecoded(Profile, const uint8_t* original, size_t original_size,
 const as6_background::DecodedArtwork&, NominalBitmap,
 double physical_width, double physical_height, Result&, std::string& error);
}
