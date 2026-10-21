#pragma once

#include "native_program.hpp"
#include "register_layout.hpp"
#include <cstddef>
#include <cstdint>

// Offline-generated, immutable descriptors. These are data records and native
// function pointers, never a container for the original executable image.
namespace as6native {
constexpr std::uint32_t ProviderVersion = 2;
constexpr std::uint32_t StopAddress = 0x10fff000u;
struct Bridge {
    std::uint32_t original_address;
    std::uint32_t native_bridge_id;
    const char *symbol;
    bool thumb;
    bool requires_registered = false; // No untyped auto fallback for fixed system functions.
};
enum class DataKind : std::uint32_t {
    ReadOnlyBytes = 1, WritableBytes = 2, ZeroFill = 3,
};
struct DataRegion {
    std::uint32_t address;
    std::uint64_t length;
    std::uint32_t permissions; // Read=1, Write=2; no executable permission.
};
struct DataSpan {
    std::uint32_t address;
    std::size_t length;
    const std::uint8_t *bytes; // nullptr only for an explicitly declared ZeroFill.
    DataKind kind;
};
struct Section {
    const char *name;
    std::uint32_t address;
    std::uint32_t size;
};
enum class BindingKind : std::uint32_t {
    StaticValue=1, ObjectConstant=2, DataAddress=3,
    ObjCClass=4, ObjCMetaclass=5, SystemData=6, Unavailable=7,
};
struct BindingSource {
    std::uint32_t address;
    const char *symbol;
    std::int64_t addend;
    std::int32_t ordinal;
    std::uint32_t flags;
    std::uint32_t stream_kind; // 1=bind, 2=weak_bind, 3=lazy_bind.
};
struct DataBinding {
    std::uint32_t address; // Exactly one initially invalid 4-byte slot.
    BindingKind kind;
    const char *symbol;
    std::uint32_t original_word;
    std::uint32_t static_value; // Already includes addend, only StaticValue.
    std::int64_t addend;
    std::size_t source_begin, source_count;
};
struct DataManifest {
    std::uint32_t version;
    const DataRegion *regions;
    std::size_t region_count;
    const DataSpan *spans;
    std::size_t span_count;
    const Section *sections;
    std::size_t section_count;
    const std::uint32_t *initializers;
    std::size_t initializer_count;
    std::uint32_t initial_sp;
    const DataBinding *bindings = nullptr;
    std::size_t binding_count = 0;
    const BindingSource *binding_sources = nullptr;
    std::size_t binding_source_count = 0;
};
struct Provider {
    std::uint32_t version;
    const as6aot::NativeProgram *program;
    const Bridge *bridges; // sorted by (original_address << 1 | thumb).
    std::size_t bridge_count;
    const DataManifest *data;
    std::uint32_t entry; // encoded original identity; low bit selects Thumb.
    const char *build_id;
};
} // namespace as6native

// Required link-time integration point, intentionally NOT weak and NOT defined
// by this candidate. A game build must supply its actual generated static
// modules, fixed bridge table, and separately extracted data-only descriptors.
extern "C" const as6native::Provider *AS6LinkedNativeProvider();
