#pragma once
#include "OctreeLineQuery.hpp"

// A distinct 36-byte triangle format used by original 0x490eb4. No conversion,
// reinterpretation or temporary staging through the 56-byte TriangleSection.
namespace as6::collision36 {
using Vec3=as6::collision::Vec3;
using Bounds=as6::collision::Bounds;
using NodeId=as6::collision::NodeId;
using Node=as6::collision::Node;
using FloatMode=as6::collision::FloatMode;
using FloatEffects=as6::collision::FloatEffects;
using RoundingMode=as6::collision::RoundingMode;
using QueryStatus=as6::collision::QueryStatus;
constexpr NodeId NoNode=as6::collision::NoNode;

struct Triangle { std::array<Vec3,3> vertices{}; };
static_assert(sizeof(Triangle)==36);
struct Query {
    Vec3 start, end, unitDirection;
    float segmentLengthSquared=0;
    Bounds segmentBounds;
    // Exactly the original raw identityByte != 0 branch. The matrix is ignored
    // completely in this mode, even when its numeric entries are not identity.
    bool skipOutputTransform=true;
    // Column-major x*m0+y*m4+z*m8+m12; only rows 0,1,2 are evaluated.
    std::array<float,16> outputTransform{};
};

// One stable read transaction is owned by the caller. Nodes and triangle
// batches are read only when traversal reaches them. No map-wide snapshot.
class TreeSource {
public:
    virtual ~TreeSource()=default;
    virtual bool readNode(NodeId,Node &) const=0;
    virtual bool readTriangles(NodeId,std::uint32_t first,
                               Triangle *destination,std::size_t count) const=0;
};
struct QueryResult {
    QueryStatus status=QueryStatus::UnsupportedInput;
    std::uint32_t totalCount=0;
    std::vector<Triangle> appended;
    FloatEffects floatingPoint;
};

// Owned staging only: publish output/count solely on Complete. Reject original
// output/input address overlap in the adapter before typed reads. Supported
// domain: RNE, traps disabled, scalar FPSCR length/stride, finite normal-or-zero
// evaluated operands/intermediates, result below capacity. Skip-transform mode
// copies the original nine vertex words and never validates/evaluates matrix.
QueryResult collectOctreeLine(const TreeSource &,NodeId root,const Query &,
                             std::uint32_t capacity,std::uint32_t initialCount=0,
                             FloatMode mode={}) noexcept;
}
