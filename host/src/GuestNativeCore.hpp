#pragma once

#include "GuestNativeProvider.hpp"
#include "HostAtomicAccess.hpp"
#include "native_state.hpp"
#include "GuestObjCMetadata.hpp"
#include <algorithm>
#include <cstring>
#include <memory>
#include <map>
#include <set>
#include <string>
#include <string_view>
#include <vector>

namespace as6native {
// Owns all 32-bit data storage. Native functions and every host bridge access
// it through the same AtomicAccess, so host writes invalidate reservations.
class Core {
    as6hostdata::ArmAtomicMemory memory_;
    as6hostdata::AtomicAccess access_;
    as6aot::NativeState state_;
    const Provider &provider_;
    std::vector<std::uint32_t> dynamic_pages_;
    std::vector<bool> bound_;
    // Definition keys stay owned by the map. A query is borrowed only for the
    // duration of find(), so mutable caller buffers never become cache keys.
    struct DefinitionNameLess {
        using is_transparent = void;
        bool operator()(const std::string &a, const std::string &b) const noexcept {
            return a < b;
        }
        bool operator()(const std::string &a, std::string_view b) const noexcept {
            return a.compare(b) < 0;
        }
        bool operator()(std::string_view a, const std::string &b) const noexcept {
            return b.compare(a) > 0;
        }
    };
    std::map<std::string,std::uint32_t,DefinitionNameLess> defined_targets_;
    bool attempted_=false,prepared_=false,ready_=false,writer_issued_=false;
    bool bind_slot(std::size_t index,std::uint32_t value,std::string &error) {
        if (!prepared_ || ready_ || index>=bound_.size() || bound_[index]) {error="binding writer phase/index/replay violation";return false;}
        const auto &b=provider_.data->bindings[index];
        if(b.kind==BindingKind::Unavailable){error="binding requires an unimplemented typed native adapter";return false;}
        if ((b.kind==BindingKind::StaticValue && value!=b.static_value) ||
            (b.kind!=BindingKind::StaticValue && !value)) {error="binding value lacks required explicit resolution";return false;}
        if (memory_.initialize_data(b.address,&value,4)!=as6hostdata::ArmAtomicMemory::Error::None) {error="cannot initialize declared binding slot";return false;}
        bound_[index]=true;return true;
    }
    bool finish_bindings(std::string &error) {
        if (!prepared_ || ready_ || std::find(bound_.begin(),bound_.end(),false)!=bound_.end()) {error="not all declared data bindings are resolved";return false;}
        if (!target(provider_.entry)) {error="entry has no compiled native target after binding";return false;}
        for (std::size_t i=0;i<provider_.data->initializer_count;++i)
            if (!target(provider_.data->initializers[i])) {error="initializer lacks compiled native target after binding";return false;}
        for (std::size_t i=0;i<provider_.data->section_count;++i)
            if (!section_readable(provider_.data->sections[i])) {error="section still contains unavailable bytes after binding";return false;}
        ready_=true;return true;
    }
public:
    // Only the host loader obtains this one-use authority. Native functions
    // receive DataAccess read/write callbacks, which cannot initialize holes.
    class BindingWriter {
        Core *core_;
        friend class Core;
        explicit BindingWriter(Core *core):core_(core) {}
    public:
        BindingWriter(const BindingWriter &)=delete;
        BindingWriter &operator=(const BindingWriter &)=delete;
        bool set(std::size_t index,std::uint32_t value,std::string &error) {return core_&&core_->bind_slot(index,value,error);}
        bool finish(std::string &error) {return core_&&core_->finish_bindings(error);}
    };
    explicit Core(const Provider &provider)
        : memory_(256ULL * 1024 * 1024), access_(memory_),
          state_(access_.access()), provider_(provider) {}
    Core(const Core &) = delete;
    Core &operator=(const Core &) = delete;
    as6aot::NativeState &state() { return state_; }
    const Provider &provider() const { return provider_; }
    // Only the bounded native execute call holds this lease. Host bridges and
    // scheduler handoffs run after its destruction with ordinary checked APIs.
    auto native_execution_lease() { return access_.execution_lease(); }
    // Direct page view for native code, published only under that lease.
    const as6aot::DirectMemory *native_direct_memory() const { return access_.direct_memory(); }
    bool nav_context_data_is_owned() const {return state_.context().data_access==&access_.access();}
    bool nav_monitor_snapshot(as6hostdata::ArmAtomicMemory::Snapshot &out) const {return access_.nav_monitor_snapshot(out);}
    std::uint64_t nav_epoch() const {return memory_.nav_epoch();}
#if defined(AS6_NAV_LEAF_FIXTURE)
    void nav_force_epoch_for_fixture(std::uint64_t value) {memory_.nav_force_epoch_for_fixture(value);}
#endif
    bool ready() const {return ready_;}
    std::size_t bound_count() const {return std::count(bound_.begin(),bound_.end(),true);}
    BindingWriter binding_writer() {
        if (!prepared_||ready_||writer_issued_)return BindingWriter(nullptr);
        writer_issued_=true;return BindingWriter(this);
    }
    bool section_readable(const Section &section) const {
        std::uint8_t bytes[4096];
        for (std::uint64_t offset=0;offset<section.size;) {
            const auto size=std::min<std::uint64_t>(sizeof(bytes),section.size-offset);
            if (!read(section.address+std::uint32_t(offset),bytes,std::size_t(size)))return false;
            offset+=size;
        }
        return section.size!=0;
    }
    const Section *declared_section(const char *name) const {
        if (!name)return nullptr;
        for(std::size_t i=0;i<provider_.data->section_count;++i)
            if(!std::strcmp(provider_.data->sections[i].name,name))return provider_.data->sections+i;
        return nullptr;
    }
    const Section *section(const char *name) const {
        const auto *result=declared_section(name);return result&&section_readable(*result)?result:nullptr;
    }
    bool read(std::uint32_t at, void *out, std::size_t size) const {
        return memory_.read(at, out, size) == as6hostdata::ArmAtomicMemory::Error::None;
    }
    bool nav_accessible(std::uint32_t at,std::uint64_t bytes,std::uint8_t permission) const {
        return memory_.nav_accessible(at,bytes,permission);
    }
    bool write(std::uint32_t at, const void *in, std::size_t size) {
        return memory_.write(at, in, size) == as6hostdata::ArmAtomicMemory::Error::None;
    }
    using WriteSpan = as6hostdata::ArmAtomicMemory::WriteSpan;
    bool write_batch(const WriteSpan *spans, std::size_t count) {
        return memory_.write_batch(spans, count) == as6hostdata::ArmAtomicMemory::Error::None;
    }
    static bool range(std::uint32_t at, std::uint64_t size) {
        return at >= 4096 && size && size <= 0x100000000ULL - at;
    }
    static std::uint64_t key(std::uint32_t at, bool thumb) {
        return (std::uint64_t(at) << 1) | thumb;
    }
    const Bridge *bridge(std::uint32_t pc, bool thumb) const {
        const auto wanted = key(pc, thumb);
        std::size_t lo = 0, hi = provider_.bridge_count;
        while (lo < hi) {
            const auto mid = lo + (hi - lo) / 2;
            if (key(provider_.bridges[mid].original_address, provider_.bridges[mid].thumb) < wanted) lo = mid + 1;
            else hi = mid;
        }
        return lo < provider_.bridge_count &&
            key(provider_.bridges[lo].original_address, provider_.bridges[lo].thumb) == wanted
            ? &provider_.bridges[lo] : nullptr;
    }
    const Bridge *bridge(const char *symbol) const {
        if (!symbol || !*symbol) return nullptr;
        for (std::size_t i = 0; i < provider_.bridge_count; ++i)
            if (!std::strcmp(provider_.bridges[i].symbol, symbol)) return provider_.bridges + i;
        return nullptr;
    }
    bool target(std::uint32_t encoded) const {
        const auto pc = encoded & ~1u;
        const bool thumb = encoded & 1u;
        return !ObjCMetadataWord(pc) && pc >= 4096 && !(pc & (thumb ? 1u : 3u)) &&
            (provider_.program->lookup(pc, thumb) || bridge(pc, thumb));
    }
    std::uint32_t native_definition(const char *symbol) const {
        if (!ready_ || !symbol) return 0;
        const auto found=defined_targets_.find(std::string_view(symbol));
        if (found==defined_targets_.end()) return 0;
        const auto encoded=found->second, pc=encoded&~1u;
        const bool thumb=encoded&1u;
        if (pc<4096 || pc==StopAddress || ObjCMetadataWord(pc) ||
            (pc&(thumb?1u:3u)) || bridge(pc,thumb) ||
            !provider_.program->lookup(pc,thumb)) return 0;
        return encoded;
    }
    bool initialize(std::string &error) {
        const auto reject = [&](const char *why) { error = why; return false; };
        if(attempted_)return reject("data loader preparation cannot be replayed");
        attempted_=true;
        if (!access_.valid() || provider_.version != ProviderVersion || !provider_.program ||
            !provider_.program->valid() || provider_.program->register_size() != as6aot::layout::Size ||
            !provider_.build_id || !*provider_.build_id)
            return reject("missing or incompatible static native program provider");
        if (provider_.program->lookup(StopAddress,false) || provider_.program->lookup(StopAddress,true))
            return reject("native function collides with the fixed host-call stop identity");
        if (provider_.bridge_count > 65536 || (provider_.bridge_count && !provider_.bridges))
            return reject("invalid fixed native bridge table");
        std::set<std::string> names;
        std::map<std::uint32_t,std::string> id_names;
        std::map<std::string,std::uint32_t> name_ids;
        for (std::size_t i = 0; i < provider_.bridge_count; ++i) {
            const auto &b = provider_.bridges[i];
            if (!b.symbol || !*b.symbol || !b.native_bridge_id || b.original_address < 4096 ||
                b.original_address == StopAddress || (b.original_address & (b.thumb ? 1u : 3u)) ||
                (i && key(provider_.bridges[i-1].original_address, provider_.bridges[i-1].thumb) >= key(b.original_address,b.thumb)) ||
                provider_.program->lookup(b.original_address,b.thumb))
                return reject("bridge addresses must be unique, sorted, aligned, and disjoint from native functions");
            // Multiple original import stubs may alias one host bridge. The
            // stable ID/name association must still be unambiguous.
            const auto id=id_names.emplace(b.native_bridge_id,b.symbol);
            const auto name=name_ids.emplace(b.symbol,b.native_bridge_id);
            if (id.first->second != b.symbol || name.first->second != b.native_bridge_id)
                return reject("bridge ID and symbol association is inconsistent");
        }
        if (provider_.entry<4096 || ((provider_.entry&~1u)&((provider_.entry&1u)?1u:3u)))return reject("invalid encoded native entry");
        const auto *m = provider_.data;
        if (!m || m->version != ProviderVersion || m->region_count > 65536 || m->span_count > 1000000 ||
            m->section_count > 65536 || m->initializer_count > 65536 ||
            (m->region_count && !m->regions) || (m->span_count && !m->spans) ||
            (m->section_count && !m->sections) || (m->initializer_count && !m->initializers) ||
            m->binding_count>1000000 || m->binding_source_count>1000000 ||
            (m->binding_count&&!m->bindings) || (m->binding_source_count&&!m->binding_sources))
            return reject("invalid data-only manifest");
        // Reject all metadata defects before creating data pages. Regions and
        // exact validity spans are sorted/disjoint; absent bytes remain holes.
        for (std::size_t i = 0; i < m->region_count; ++i) {
            const auto &r = m->regions[i];
            const auto end = std::uint64_t(r.address) + r.length;
            if (!range(r.address,r.length) || ObjCMetadataOverlap(r.address,r.length) || (r.address & 4095) || (r.length & 4095) ||
                !(r.permissions & 1) || (r.permissions & ~3u) ||
                (i && std::uint64_t(m->regions[i-1].address) + m->regions[i-1].length > r.address) ||
                end > 0x10000000u)
                return reject("data regions overlap reserved heap/stack space, request execute, or violate page bounds");
        }
        auto containing_region = [&](std::uint32_t at, std::uint64_t size) -> const DataRegion * {
            if (!range(at,size)) return nullptr;
            for (std::size_t i = 0; i < m->region_count; ++i)
                if (at >= m->regions[i].address && std::uint64_t(at) + size <= std::uint64_t(m->regions[i].address) + m->regions[i].length)
                    return m->regions + i;
            return nullptr;
        };
        for (std::size_t i = 0; i < m->span_count; ++i) {
            const auto &s = m->spans[i];
            const auto *r = containing_region(s.address,s.length);
            if (!r || (i && std::uint64_t(m->spans[i-1].address) + m->spans[i-1].length > s.address) ||
                (s.kind != DataKind::ReadOnlyBytes && s.kind != DataKind::WritableBytes && s.kind != DataKind::ZeroFill) ||
                (s.kind == DataKind::ZeroFill ? s.bytes != nullptr : !s.bytes) ||
                (s.kind == DataKind::WritableBytes && !(r->permissions & 2)) ||
                (s.kind == DataKind::ReadOnlyBytes && (r->permissions & 2)))
                return reject("invalid exact data span or payload kind");
        }
        std::vector<std::pair<std::uint64_t,std::uint64_t>> declared;
        for(std::size_t i=0;i<m->span_count;++i)declared.emplace_back(m->spans[i].address,std::uint64_t(m->spans[i].address)+m->spans[i].length);
        for(std::size_t i=0;i<m->binding_count;++i) {
            const auto &b=m->bindings[i];
            if((b.address&3)||!containing_region(b.address,4)||!b.symbol||!*b.symbol||
               (i&&m->bindings[i-1].address+4ULL>b.address)||std::uint32_t(b.kind)<1||std::uint32_t(b.kind)>7||
               !b.source_count||b.source_begin>m->binding_source_count||b.source_count>m->binding_source_count-b.source_begin)
                return reject("invalid exact binding slot or source metadata");
            for(std::size_t j=0;j<b.source_count;++j) {
                const auto &s=m->binding_sources[b.source_begin+j];
                if(s.address!=b.address||!s.symbol||std::strcmp(s.symbol,b.symbol)||s.addend!=b.addend||s.stream_kind<1||s.stream_kind>3)
                    return reject("coalesced binding sources disagree");
            }
            // These identities were fixed offline from original definitions.
            // Never infer a target from mutable guest memory or a host symbol.
            // Zero marks an ambiguous definition and cannot later be replaced.
            if(b.kind==BindingKind::StaticValue && !b.addend) {
                const auto result=defined_targets_.emplace(b.symbol,b.static_value);
                if(!result.second && result.first->second!=b.static_value)
                    result.first->second=0;
            }
            declared.emplace_back(b.address,std::uint64_t(b.address)+4);
        }
        std::sort(declared.begin(),declared.end());
        for(std::size_t i=1;i<declared.size();++i)if(declared[i-1].second>declared[i].first)return reject("binding slots overlap initialized data or each other");
        names.clear();
        for (std::size_t i = 0; i < m->section_count; ++i) {
            const auto &s = m->sections[i];
            if (!s.name || !*s.name || !std::strcmp(s.name,"__text") || !names.insert(s.name).second ||
                !containing_region(s.address,s.size)) return reject("invalid data section or executable text section");
            // Section queries must never advertise unavailable bytes as valid.
            std::uint64_t cursor = s.address, end = cursor + s.size;
            for (const auto &span:declared) {
                if(cursor==end||span.first>cursor)break;
                if(span.second>cursor)cursor=std::min(end,span.second);
            }
            if (cursor != end) return reject("section includes invalid data holes");
        }
        if ((m->initial_sp & 7u) || m->initial_sp < 0x3f7f8000u || m->initial_sp > 0x3ffef000u)
            return reject("initial stack pointer outside reserved native stack");
        for (std::size_t i = 0; i < m->region_count; ++i) {
            const auto &r = m->regions[i];
            if (memory_.map_partial_data(r.address,r.length,r.permissions) != as6hostdata::ArmAtomicMemory::Error::None)
                return reject("cannot allocate declared data regions");
        }
        const std::uint8_t zero[4096]{};
        for (std::size_t i = 0; i < m->span_count; ++i) {
            const auto &s = m->spans[i];
            for (std::size_t offset = 0; offset < s.length;) {
                const auto count = std::min<std::size_t>(4096,s.length-offset);
                const auto *bytes = s.kind == DataKind::ZeroFill ? zero : s.bytes + offset;
                if (memory_.initialize_data(s.address+std::uint32_t(offset),bytes,count) != as6hostdata::ArmAtomicMemory::Error::None)
                    return reject("cannot initialize declared data bytes");
                offset += count;
            }
        }
        if (!ensure_dynamic(0x3f7f0000u,0x800000u)) return reject("cannot allocate main data stack");
        state_.set_register(13,m->initial_sp);
        bound_.assign(m->binding_count,false);prepared_=true;
        return true;
    }
    // Only explicit dynamic data arenas can grow. A bad guest pointer cannot
    // map arbitrary image holes or produce executable storage.
    bool ensure_dynamic(std::uint32_t at, std::size_t size) {
        if (!range(at,size)) return false;
        const std::uint64_t end = std::uint64_t(at)+size;
        if (at < 0x20000000u || end > 0x3fff0000u) return false;
        const auto first = at & ~4095u;
        const auto last = (end+4095)&~4095ULL;
        std::vector<std::uint32_t> missing;
        try {
            for (std::uint64_t p=first;p<last;p+=4096)
                if (!std::binary_search(dynamic_pages_.begin(),dynamic_pages_.end(),std::uint32_t(p))) missing.push_back(std::uint32_t(p));
            dynamic_pages_.reserve(dynamic_pages_.size()+missing.size());
        } catch (const std::bad_alloc &) { return false; }
        std::size_t mapped = 0;
        for (auto p:missing) {
            if (memory_.map(p,4096,3) != as6hostdata::ArmAtomicMemory::Error::None) {
                for (std::size_t i=0;i<mapped;++i) memory_.unmap(missing[i],4096);
                return false;
            }
            ++mapped;
        }
        // Existing mappings already satisfy this request. Do not reorder the
        // complete page registry again for every allocation/zero-fill.
        if (missing.empty()) return true;
        // Both runs are sorted and disjoint. reserve() succeeded before any
        // mapping; resize within that capacity and merge backwards in place.
        // No allocation or throwing operation remains after maps commit.
        std::size_t old_count = dynamic_pages_.size();
        std::size_t added_count = missing.size();
        dynamic_pages_.resize(old_count + added_count);
        std::size_t output = dynamic_pages_.size();
        while (added_count) {
            if (old_count && dynamic_pages_[old_count-1] > missing[added_count-1])
                dynamic_pages_[--output] = dynamic_pages_[--old_count];
            else
                dynamic_pages_[--output] = missing[--added_count];
        }
        return true;
    }
};
} // namespace as6native
