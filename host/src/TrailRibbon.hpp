#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace as6::geometry::trail {
struct Vec2 {float x=0,y=0;};
struct Vec3 {float x=0,y=0,z=0;};
// Original ribbon stream, unrelated to the36B collision triangle format.
struct Vertex36 {
    Vec3 position;
    Vec2 uv;
    Vec3 normal;
    std::array<std::uint8_t,4> colorBytes{};
};
static_assert(sizeof(Vertex36)==36);
static_assert(offsetof(Vertex36,position)==0&&offsetof(Vertex36,uv)==12&&
              offsetof(Vertex36,normal)==20&&offsetof(Vertex36,colorBytes)==32);
struct Pose {
    // Original node fields+10/+20/+30, each xyz, and translation+40.
    std::array<Vec3,3> axes{};
    Vec3 position;
};
struct Config {
    std::uint16_t baseVertex=0,indexCapacity=0,vertexCapacity=0;
    float width=0,minimumDistance=0,uvStep=0;
    std::array<float,2> uEndpoints{}; // Original+128,+12c.
    std::array<std::uint8_t,4> colorBytes{}; // Original+11c..11f.
    bool flipU=false,fadeTail=false,smoothJoin=false;
    bool widthUsesAlpha=false,premultiplyColor=false;
};
struct State {
    float v=0;
    Vec3 lastPosition;
    std::uint16_t usedIndices=0,indexCursor=0,vertexCursor=0;
    std::uint8_t lastAlpha=0;
    bool first=true,lastEnded=false;
};
enum class Rounding:std::uint8_t {Nearest,PlusInfinity,MinusInfinity,TowardZero};
struct FloatMode {
    Rounding rounding=Rounding::Nearest;
    bool flushToZero=false,defaultNaN=false;
    std::uint8_t exceptionEnables=0,vectorLength=0,vectorStride=0;
};
struct FloatEffects {std::uint32_t exceptionBits=0,nzcv=0;bool compared=false;};
class IndexSource {
public:
    virtual ~IndexSource()=default;
    // Only initial index compaction reads existing storage: first=6 and
    // count=indexCapacity-6. A zero count never invokes this callback.
    virtual bool readIndices(std::uint32_t first,std::uint16_t *destination,
                             std::size_t count) const=0;
};
struct BytePatch {std::size_t offset=0;std::vector<std::uint8_t> bytes;};
enum StateField:std::uint32_t {
    V=1u<<0,LastPosition=1u<<1,UsedIndices=1u<<2,IndexCursor=1u<<3,
    VertexCursor=1u<<4,LastAlpha=1u<<5,First=1u<<6,LastEnded=1u<<7
};
enum class Status:std::uint8_t {
    Complete,UnsupportedEnvironment,UnsupportedInput,UnsupportedArithmetic,
    InvalidState,ResourceLimit,SourceFailure
};
struct Result {
    Status status=Status::InvalidState;
    State state;
    // Owned, sorted, disjoint byte patches merge adjacent/overlapping writes,
    // with later-write precedence. Every originally written byte is retained,
    // including equal-value writes; a tail color touches only its four bytes.
    std::vector<BytePatch> vertexWrites,indexWrites;
    std::uint32_t stateWrites=0;
    FloatEffects floatingPoint;
};
// Pure per-frame ribbon state/geometry update for original TrailSceneNode::Update.
// No explicit dt is consumed: upstream has already prepared uvStep and pose.
// No old vertex input is needed. Caller supplies a stable index source and
// rejects original-address alias before publishing the owned patches.
// Only Complete authorizes atomic publication; otherwise discard all staging.
// Initial domain: RNE, disabled traps/scalar vector controls, normal-or-zero
// semantic floats/intermediates, even vertex capacity/cursor, six-aligned index
// capacity/cursor and valid nonnegative signed16 counters, all<=32766.
Result update(const Pose &,const Config &,const State &,const IndexSource &,FloatMode={}) noexcept;
}
