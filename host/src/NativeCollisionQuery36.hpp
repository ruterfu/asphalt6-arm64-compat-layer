#pragma once
#include "NativeCollisionQuery.hpp"
#include "OctreeTriangleQuery36.hpp"

namespace as6_collision36 {
// Same stable storage/publication contract as the existing collision adapter;
// this path reads and writes the distinct 36-byte triangle layout directly.
as6_collision::Result query(const as6_collision::Storage &,std::uint32_t selector,
                           std::uint32_t root,std::uint32_t fpscr) noexcept;
}
