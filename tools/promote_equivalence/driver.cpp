// Differential check for tools/promote_registers.py. One binary links the same
// module twice: the original (lookup renamed orig_lookup) and the promoted copy
// (prom_lookup). Every entry is run from identical random register files,
// budgets, stop targets and deterministic memory; all architectural results and
// the complete data-access trace must match.
#include "native_program.hpp"
#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <random>
#include <vector>

extern "C" as6aot::NativeFunction orig_lookup(std::uint32_t, bool);
extern "C" as6aot::NativeFunction prom_lookup(std::uint32_t, bool);

namespace {
struct Memory {
    std::map<std::uint32_t, std::vector<std::uint8_t>> pages;
    std::vector<std::uint64_t> trace;  // kind, address, length, data hash
    std::uint64_t seed;
    std::uint64_t exclusive_address = ~0ull;

    std::uint8_t *page(std::uint32_t address) {
        const auto base = address & ~0xfffu;
        auto found = pages.find(base);
        if (found != pages.end()) return found->second.data();
        std::vector<std::uint8_t> bytes(4096);
        std::mt19937_64 rng(seed ^ (std::uint64_t(base) * 0x9e3779b97f4a7c15ull));
        for (auto &byte : bytes) byte = std::uint8_t(rng());
        // Small values near zero make pointers and counters stay plausible.
        for (std::size_t i = 0; i < bytes.size(); i += 4) if (rng() % 3 == 0) bytes[i + 1] = bytes[i + 2] = bytes[i + 3] = 0;
        return pages.emplace(base, std::move(bytes)).first->second.data();
    }
    static bool mapped(std::uint32_t address, std::size_t length) {
        const std::uint64_t end = std::uint64_t(address) + length;
        return address >= 0x1000 && end <= 0xf0000000ull;
    }
    void record(std::uint64_t kind, std::uint32_t address, std::size_t length, const void *data) {
        std::uint64_t hash = 1469598103934665603ull;
        for (std::size_t i = 0; i < length; ++i) hash = (hash ^ static_cast<const std::uint8_t *>(data)[i]) * 1099511628211ull;
        trace.insert(trace.end(), {kind, address, length, hash});
    }
    bool read(std::uint32_t address, void *out, std::size_t length) {
        if (!mapped(address, length)) { record(9, address, length, nullptr); return false; }
        for (std::size_t i = 0; i < length; ++i) static_cast<std::uint8_t *>(out)[i] = page(address + i)[(address + i) & 0xfff];
        record(1, address, length, out);
        return true;
    }
    bool write(std::uint32_t address, const void *in, std::size_t length) {
        if (!mapped(address, length)) { record(8, address, length, nullptr); return false; }
        for (std::size_t i = 0; i < length; ++i) page(address + i)[(address + i) & 0xfff] = static_cast<const std::uint8_t *>(in)[i];
        record(2, address, length, in);
        return true;
    }
};

as6aot::DataAccess access_for(Memory &memory) {
    as6aot::DataAccess access{&memory,
        [](void *m, std::uint32_t a, void *o, std::size_t n) { return static_cast<Memory *>(m)->read(a, o, n); },
        [](void *m, std::uint32_t a, const void *i, std::size_t n) { return static_cast<Memory *>(m)->write(a, i, n); }};
    access.load_exclusive = [](void *raw, std::uint32_t a, unsigned w, std::uint64_t *v) {
        auto &m = *static_cast<Memory *>(raw); *v = 0;
        if (!m.read(a, v, w)) return as6aot::MemoryFault;
        m.exclusive_address = a; return as6aot::Returned; };
    access.store_exclusive = [](void *raw, std::uint32_t a, unsigned w, std::uint64_t v, std::uint32_t *s) {
        auto &m = *static_cast<Memory *>(raw);
        *s = m.exclusive_address == a ? 0 : 1; m.exclusive_address = ~0ull;
        if (*s) return as6aot::Returned;
        return m.write(a, &v, w) ? as6aot::Returned : as6aot::MemoryFault; };
    access.clear_exclusive = [](void *raw) { static_cast<Memory *>(raw)->exclusive_address = ~0ull; return as6aot::Returned; };
    access.barrier = [](void *raw, unsigned option) { static_cast<Memory *>(raw)->trace.push_back(100 + option); return as6aot::Returned; };
    access.swap = [](void *raw, std::uint32_t a, unsigned w, std::uint64_t v, std::uint64_t *old) {
        auto &m = *static_cast<Memory *>(raw); *old = 0;
        if (!m.read(a, old, w) || !m.write(a, &v, w)) return as6aot::MemoryFault;
        return as6aot::Returned; };
    return access;
}

struct Outcome {
    std::uint32_t status, next_pc, fault;
    std::uint64_t budget;
    bool thumb;
    std::uint8_t registers[1024];
    std::vector<std::uint64_t> trace;
    bool operator==(const Outcome &o) const {
        return status == o.status && next_pc == o.next_pc && fault == o.fault && budget == o.budget &&
               thumb == o.thumb && !std::memcmp(registers, o.registers, sizeof(registers)) && trace == o.trace;
    }
};

Outcome run(as6aot::NativeLookup lookup, const std::uint8_t *registers, std::uint32_t pc, bool thumb,
            std::uint64_t budget, bool legacy, std::uint32_t stop, bool stop_thumb, std::uint64_t seed) {
    Memory memory; memory.seed = seed;
    const auto access = access_for(memory);
    Outcome out{};
    std::memcpy(out.registers, registers, sizeof(out.registers));
    as6aot::Context ctx{};
    ctx.registers = out.registers; ctx.register_size = sizeof(out.registers);
    ctx.data_access = &access; ctx.budget = budget; ctx.next_pc = pc; ctx.isa_thumb = thumb;
    ctx.status = as6aot::Returned;
    // Follow in-module Dispatch the way NativeProgram::execute does, bounded;
    // leaving the module ends the run with Dispatch.
    as6aot::Status status = as6aot::Dispatch;
    for (int hops = 0; hops < 64 && status == as6aot::Dispatch; ++hops) {
        const auto function = lookup(ctx.next_pc, ctx.isa_thumb);
        if (!function) break;
        as6aot::write_bytes(ctx.registers, 92, 4, as6aot::Word(ctx.next_pc));
        status = function(ctx, legacy, stop, stop_thumb);
    }
    out.status = status; out.next_pc = ctx.next_pc; out.fault = ctx.fault_address;
    out.budget = ctx.budget; out.thumb = ctx.isa_thumb; out.trace = std::move(memory.trace);
    return out;
}
} // namespace

int main(int argc, char **argv) {
    if (argc < 3) { std::fprintf(stderr, "usage: driver KEYS_FILE TRIALS\n"); return 2; }
    std::vector<std::uint64_t> keys;
    std::ifstream input(argv[1]);
    for (std::uint64_t key; input >> std::hex >> key;) keys.push_back(key);
    const int trials = std::atoi(argv[2]);
    std::mt19937_64 rng(0x5eed ^ keys.size());
    std::uint64_t runs = 0, mismatches = 0, steps = 0;
    std::map<std::uint32_t, std::uint64_t> statuses;
    for (const auto key : keys) {
        const auto pc = std::uint32_t(key >> 1);
        const bool thumb = key & 1;
        if (!orig_lookup(pc, thumb) || !prom_lookup(pc, thumb)) { std::fprintf(stderr, "missing entry %#" PRIx64 "\n", key); return 1; }
        for (int trial = 0; trial < trials; ++trial) {
            std::uint8_t registers[1024];
            for (auto &byte : registers) byte = std::uint8_t(rng());
            // Plausible pointers/flags: some registers point into mapped data,
            // flags are booleans, FPSCR is mostly the iOS default.
            for (int r = 0; r < 16; ++r) if (rng() % 2) {
                const std::uint32_t value = 0x10000 + std::uint32_t(rng() % 0x100000) * 4;
                std::memcpy(registers + 32 + 4 * r, &value, 4);
            }
            for (int f = 96; f < 111; ++f) registers[f] &= 1;
            if (rng() % 4) { const std::uint32_t fpscr = rng() % 2 ? 0x03000000u : 0; std::memcpy(registers + 180, &fpscr, 4); }
            const std::uint64_t budget = rng() % 4 == 0 ? rng() % 8 : rng() % 4000;
            const bool legacy = rng() % 8 == 0;
            const auto stop_key = rng() % 3 == 0 ? keys[rng() % keys.size()] : rng();
            const auto seed = rng();
            const auto a = run(orig_lookup, registers, pc, thumb, budget, legacy, std::uint32_t(stop_key >> 1), stop_key & 1, seed);
            const auto b = run(prom_lookup, registers, pc, thumb, budget, legacy, std::uint32_t(stop_key >> 1), stop_key & 1, seed);
            ++runs; ++statuses[a.status]; steps += budget - a.budget;
            if (!(a == b) && mismatches++ < 5)
                std::fprintf(stderr, "MISMATCH entry=%#" PRIx64 " trial=%d status %u/%u pc %#x/%#x budget %" PRIu64 "/%" PRIu64 "\n",
                             key, trial, a.status, b.status, a.next_pc, b.next_pc, a.budget, b.budget);
        }
    }
    std::printf("{\"entries\":%zu,\"runs\":%" PRIu64 ",\"mismatches\":%" PRIu64 ",\"instructions\":%" PRIu64 ",\"statuses\":{",
                keys.size(), runs, mismatches, steps);
    bool first = true;
    for (const auto &[status, count] : statuses) { std::printf("%s\"%u\":%" PRIu64, first ? "" : ",", status, count); first = false; }
    std::printf("}}\n");
    return mismatches ? 1 : 0;
}
