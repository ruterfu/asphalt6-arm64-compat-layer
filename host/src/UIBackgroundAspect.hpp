#pragma once
#include "BackgroundAspect.hpp"
namespace as6_ui_background {
enum class Profile {
 Quickrace000019=19, Info000082=82, Multiplayer000117=117,
 Options000423=423, Career000534=534, Unlocks000630=630,
 NextEvents000683=683, MultiplayerB000745=745,
 Quickrace000871Retina=871, Info000296Retina=296,
 Multiplayer000063Retina=63, Options000273Retina=273,
 Career000859Retina=859, Unlocks000316Retina=316,
 NextEvents000184Retina=184, MultiplayerB000804Retina=804
};
enum class ArtKind { Info=0, Unlocks=1, Multiplayer=2, Map=3, Options=4 };
struct ArtView { ArtKind kind; const uint8_t* top_bgra=nullptr; size_t bytes=0; const as6_background::DecodedArtwork* decoded=nullptr; };
using Result=as6_background::Result;
// Pure metadata lookup. Returns0 for unknown profile, otherwise1 or2. A null
// destination can be used to query count. No art is read by this lookup.
size_t RequiredArts(Profile,ArtKind destination[2]) noexcept;
// Whole-file encoded TGA output. Keep each backing art buffer alive throughout
// this call (e.g. strong NSData owners in the private file bridge). Exactly the
// required1/2 distinct kinds must be supplied; every used source is SHA-pinned.
// Final Host landscape window width/height, never GuestUIScreen dimensions.
// No guest access, GL, UIKit, file operation or production/UI logic mutation.
// Failure leaves Result unchanged. Art_crop describes the first required art.
bool Materialize(Profile,const uint8_t* original,size_t original_size,
 const ArtView* art,size_t art_count,double physical_width,double physical_height,
 Result&,std::string& error);
}
