#pragma once
#include "BackgroundAspect.hpp"
namespace as6_loading_background {
enum class Profile {
 Loading000032Phone736=32, Loading000120Phone736=120,
 Loading000235Phone736=235, Loading000298Phone736=298,
 Loading000307Phone736=307, Loading000334Phone736=334,
 Loading000472Phone736=472, Loading000523Phone736=523,
 Loading000663Phone736=663, Loading000671Phone736=671,
 Loading000771Phone736=771, Loading000807Phone736=807
};
using Result=as6_background::Result;
// Whole-file original layout output; photo-only sampling. The input Art is
// pinned top-first BGRA with its exact source dimensions.
// Native final Host window dimensions, not guest UIScreen, are required.
// Tight original flag raster and every byte outside the approved photo mask
// are retained. New transparent AI header replaces the inseparable baked old
// photo/header composite. Failure leaves Result intact. New profiles require
// their exact art/source pins; an enum alone does not admit an unavailable art.
bool Materialize(Profile,const uint8_t* original,size_t original_size,
 const uint8_t* art_bgra,size_t art_size,double physical_width,double physical_height,
 Result&,std::string& error);
bool MaterializeDecoded(Profile, const uint8_t* original, size_t original_size,
 const as6_background::DecodedArtwork&, double physical_width, double physical_height,
 Result&, std::string& error);
}
