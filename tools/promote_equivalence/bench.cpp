// Rough CPU cost of original vs promoted code for one module: flat memory,
// identical random starts, instructions retired per second for each version.
#include "native_program.hpp"
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <random>
#include <vector>

extern "C" as6aot::NativeFunction orig_lookup(std::uint32_t, bool);
extern "C" as6aot::NativeFunction prom_lookup(std::uint32_t, bool);

int main(int argc, char **argv) {
    std::vector<std::uint64_t> keys;
    std::ifstream input(argv[1]);
    for (std::uint64_t key; input >> std::hex >> key;) keys.push_back(key);
    std::vector<std::uint8_t> memory(16u << 20);
    std::mt19937_64 seed(7);
    for (auto &byte : memory) byte = std::uint8_t(seed() % 3 ? 0 : seed());
    struct Start { std::uint8_t registers[1024]; std::uint32_t pc; bool thumb; };
    std::vector<Start> starts;
    for (int i = 0; i < 4000; ++i) {
        Start s{}; const auto key = keys[seed() % keys.size()];
        s.pc = std::uint32_t(key >> 1); s.thumb = key & 1;
        for (auto &byte : s.registers) byte = std::uint8_t(seed());
        for (int r = 0; r < 16; ++r) { const std::uint32_t v = 0x10000 + std::uint32_t(seed() % 0x300000) * 4; std::memcpy(s.registers + 32 + 4 * r, &v, 4); }
        for (int f = 96; f < 111; ++f) s.registers[f] &= 1;
        std::memset(s.registers + 180, 0, 4);
        starts.push_back(s);
    }
    // Same direct page view the device publishes under the execution lease.
    std::vector<std::uintptr_t> pages(1u << 20);
    for (std::size_t i = 0; i < memory.size() / 4096; ++i)
        pages[i] = reinterpret_cast<std::uintptr_t>(memory.data() + i * 4096) | 3;
    pages[0] = 0;
    std::uint64_t epoch = 0; std::size_t reserved = 0; std::uint32_t granules[1] = {};
    const as6aot::DirectMemory direct{pages.data(), &epoch, granules, &reserved};
    const bool use_direct = argc > 2;
    for (auto lookup : {orig_lookup, prom_lookup, orig_lookup, prom_lookup}) {
        std::uint64_t retired = 0;
        const auto begin = std::chrono::steady_clock::now();
        for (int round = 0; round < 20; ++round)
            for (const auto &s : starts) {
                std::uint8_t registers[1024]; std::memcpy(registers, s.registers, sizeof(registers));
                as6aot::Context ctx{}; ctx.registers = registers; ctx.register_size = 1024;
                ctx.memory = memory.data(); ctx.memory_base = 0; ctx.memory_size = memory.size();
                if (use_direct) ctx.direct = &direct;
                ctx.budget = 5000; ctx.next_pc = s.pc; ctx.isa_thumb = s.thumb; ctx.status = as6aot::Returned;
                for (int hops = 0; hops < 64; ++hops) {
                    const auto f = lookup(ctx.next_pc, ctx.isa_thumb);
                    if (!f) break;
                    as6aot::write_bytes(ctx.registers, 92, 4, as6aot::Word(ctx.next_pc));
                    if (f(ctx, false, 0, false) != as6aot::Dispatch) break;
                }
                retired += 5000 - ctx.budget;
            }
        const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count();
        std::printf("%s %.1f M instructions/s (%llu in %.3fs)\n", lookup == orig_lookup ? "original" : "promoted",
                    retired / seconds / 1e6, (unsigned long long)retired, seconds);
    }
}
