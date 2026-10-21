#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace as6::collision {
struct Vec3 { float x=0, y=0, z=0; };
struct Bounds { Vec3 minimum, maximum; };
struct TriangleSection {
    std::array<Vec3,3> vertices{};
    std::array<std::uint8_t,20> metadata{};
};
static_assert(sizeof(Vec3)==12);
static_assert(sizeof(TriangleSection)==56);

using NodeId=std::uint64_t; // Opaque identity; never interpreted as a pointer.
constexpr NodeId NoNode=0;
struct Node {
    Bounds bounds;
    std::array<NodeId,8> children{};
    std::uint32_t triangleCount=0;
};
struct Query {
    Vec3 start, end, unitDirection;
    float segmentLengthSquared=0;
    Bounds segmentBounds;
    // Original column-major layout: x*m0+y*m4+z*m8+m12, etc.
    std::array<float,16> outputTransform{};
};

// The caller owns one stable read transaction for the whole query. Callbacks
// read typed data only; they must not change the tree, call Host bridges or
// wait on a foreign thread requiring that same transaction. Failed reads may
// modify their temporary destination, never the original game's output.
class TreeSource {
public:
    virtual ~TreeSource()=default;
    virtual bool readNode(NodeId,Node &) const=0;
    virtual bool readTriangles(NodeId,std::uint32_t first,
                               TriangleSection *destination,std::size_t count) const=0;
};

enum class RoundingMode : std::uint8_t { Nearest, PlusInfinity, MinusInfinity, TowardZero };
struct FloatMode {
    RoundingMode rounding=RoundingMode::Nearest;
    bool flushToZero=false, defaultNaN=false;
    std::uint8_t exceptionEnables=0, vectorLength=0, vectorStride=0;
};
struct FloatEffects {
    // ARM FPSCR cumulative exception positions(0..4,7) newly raised by this
    // query. The adapter preserves incoming sticky flags/control bits.
    std::uint32_t exceptionBits=0;
    std::uint32_t nzcv=0; // Last original FP comparison, bits31..28.
    bool compared=false;
};
enum class QueryStatus : std::uint8_t {
    Complete, UnsupportedFloatMode, UnsupportedInput, UnsupportedArithmetic,
    UnsupportedCapacity, InvalidTree, SourceFailure, ResourceLimit
};
struct QueryResult {
    QueryStatus status=QueryStatus::UnsupportedInput;
    std::uint32_t totalCount=0;
    std::vector<TriangleSection> appended;
    FloatEffects floatingPoint;
};

// All output is owned staging. Only Complete authorizes publication of the
// appended triangles and totalCount. Other statuses leave game data untouched.
// The adapter must reject overlap between original output and original inputs
// before snapshotting: typed staging cannot establish original-address aliasing.
// The initial supported domain requires nearest rounding, disabled traps and
// scalar FPSCR length/stride, finite normal-or-zero operands/intermediates, and
// a result that does not reach capacity. Metadata remains opaque raw bytes.
QueryResult collectOctreeLine(const TreeSource &,NodeId root,const Query &,
                             std::uint32_t capacity,std::uint32_t initialCount=0,
                             FloatMode mode={}) noexcept;
}
