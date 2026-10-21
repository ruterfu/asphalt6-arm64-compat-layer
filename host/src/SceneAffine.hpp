#pragma once
#include <array>
#include <cstddef>
#include <cstdint>

namespace as6::scene::affine {
// The source layout is a column-major 4x4 matrix. This affine branch reads
// only the first three words of each column (through byte59), and publishes
// all64 matrix bytes plus the identity byte at64.
struct ReadMatrix { const std::uint8_t *bytes=nullptr;std::size_t size=0; };
struct WriteMatrix { std::uint8_t *bytes=nullptr;std::size_t size=0; };
// Full two-lane mathematical carry, including the otherwise unused high lanes.
// These correspond to the original middle coefficient, accumulator and term.
struct Carry {
    std::uint64_t middle=0,accumulator=0,term=0;
    std::uint32_t fpscr=0;
};
enum class AccessKind:std::uint8_t {Read,Write};
struct Access {
    AccessKind kind=AccessKind::Read;
    std::uintptr_t address=0;
    std::uint32_t value=0,fpscr=0;
    std::uint8_t size=0;
};
// Optional owned diagnostic storage. No callback executes inside the kernel.
// Must not overlap any matrix interval.
struct Trace { std::array<Access,92> accesses{};std::size_t count=0; };
enum class Status:std::uint8_t {InvalidViews,UnsupportedEnvironment,InvalidTrace,Complete,BackendFailure};
struct Result {
    Status status=Status::InvalidViews;
    Carry carry{};
    std::uint32_t structuralWord=0,reads=0,writes=0,nativeOperations=0,softwareOperations=0;
};
// In-place and partial matrix overlaps are supported, including unaligned
// byte offsets. Inputs are reread after every intervening original store.
// The caller owns valid stable storage for the entire invocation. There is no
// guest-memory, callback, allocation, owner, scheduling or runtime admission API.
// Identity flags were checked by the enclosing method before this branch;
// its published identity byte is zero. Parent/local/output spans may alias.
// Invalid admission has no writes. BackendFailure is terminal after possible
// partial writes and never authorizes replay; the pinned exact backend is total
// for admitted environments and all IEEE32 bit patterns.
Result compose(ReadMatrix parent,ReadMatrix local,WriteMatrix destination,
               Carry incoming={},bool nativeFast=true,Trace *trace=nullptr) noexcept;
}
