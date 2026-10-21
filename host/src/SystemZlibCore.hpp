#pragma once
#include <cstddef>
#include <cstdint>
#include <memory>

namespace as6port {
constexpr std::uint32_t DefaultZalloc = 0x342898u;
constexpr std::uint32_t DefaultZfree = 0x342884u;
struct ZStream32 {
    std::uint32_t next_in, avail_in, total_in;
    std::uint32_t next_out, avail_out, total_out;
    std::uint32_t msg, state, zalloc, zfree, opaque;
    std::int32_t data_type;
    std::uint32_t adler, reserved;
};
static_assert(sizeof(ZStream32)==56 && offsetof(ZStream32,state)==28 &&
              offsetof(ZStream32,zalloc)==32 && offsetof(ZStream32,adler)==48);
struct GuestServices {
    void *owner;
    bool (*read)(void *,std::uint32_t,void *,std::size_t);
    bool (*write)(void *,std::uint32_t,const void *,std::size_t);
    // Read-only complete interval preflight, in bounded scratch chunks.
    bool (*probe)(void *,std::uint32_t,std::size_t);
    std::uint32_t (*heap_alloc)(void *,std::size_t);
    bool (*heap_free)(void *,std::uint32_t);
    std::uint32_t (*call)(void *,std::uint32_t,const std::uint32_t *,int);
    bool (*stopped)(void *);
    std::uint32_t (*message)(void *,const char *);
};
enum class ZOperation { Init, Init2, Inflate, Reset, End };
struct ZResult { int code; bool memory_fault; bool callback_stopped; };
class SystemZlib {
    struct Impl;
    std::unique_ptr<Impl> impl_;
public:
    explicit SystemZlib(GuestServices);
    ~SystemZlib();
    SystemZlib(const SystemZlib&)=delete;
    SystemZlib& operator=(const SystemZlib&)=delete;
    ZResult invoke(ZOperation,std::uint32_t stream,int argument=0,
                   std::uint32_t version=0,std::uint32_t stream_size=56);
    std::size_t live_streams() const;
};
}
