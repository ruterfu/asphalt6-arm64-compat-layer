// Direct page view equivalence: every load/store through Context::direct must
// leave the same bytes, faults, epoch and exclusive-monitor results as the
// DataAccess callback path. Build (macOS arm64):
//   clang++ -std=c++17 -O2 -Iaot/runtime -Ihost/src host/tests/direct_memory.cpp
#include "HostAtomicAccess.hpp"
#include <cstdio>
#include <random>

namespace {
using as6hostdata::ArmAtomicMemory;
using as6hostdata::AtomicAccess;
using as6hostdata::DataMemory;
constexpr std::uint32_t Base = 0x10000, Pages = 8;

struct Machine {
    ArmAtomicMemory memory;
    AtomicAccess access{memory};
    as6aot::Context ctx{};
    bool direct;
    explicit Machine(bool useDirect) : direct(useDirect) {
        ctx.data_access = &access.access();
        // Page 0-3 RW, 4 read-only, 5 unmapped hole, 6 partial (half valid), 7 RW.
        memory.map(Base, 4 * DataMemory::PageSize, DataMemory::Read | DataMemory::Write);
        memory.map(Base + 4 * DataMemory::PageSize, DataMemory::PageSize, DataMemory::Read);
        memory.map_partial_data(Base + 6 * DataMemory::PageSize, DataMemory::PageSize, DataMemory::Read | DataMemory::Write);
        std::uint8_t half[DataMemory::PageSize / 2];
        for (std::size_t i = 0; i < sizeof(half); ++i) half[i] = std::uint8_t(i * 7);
        memory.initialize_data(Base + 6 * DataMemory::PageSize, half, sizeof(half));
        memory.map(Base + 7 * DataMemory::PageSize, DataMemory::PageSize, DataMemory::Read | DataMemory::Write);
    }
    // Each operation runs as its own leased slice, like GuestEmulate.
    template <class F> auto slice(F &&f) {
        auto lease = memory.execution_lease();
        ctx.direct = direct ? memory.direct_memory() : nullptr;
        ctx.status = as6aot::Returned;
        ctx.fault_address = 0;
        auto result = f(ctx);
        ctx.direct = nullptr;
        return result;
    }
};

int failures = 0;
void expect(bool ok, const char *what, unsigned step) {
    if (!ok && failures++ < 20) std::fprintf(stderr, "step %u: %s differs\n", step, what);
}
} // namespace

int main() {
    Machine slow(false), fast(true);
    std::mt19937 rng(12345);
    const unsigned widths[] = {1, 2, 4, 8, 16};
    std::uint64_t directLoads = 0, directStores = 0, strexSuccesses = 0, strexFailures = 0;
    for (unsigned step = 0; step < 400000; ++step) {
        const unsigned op = rng() % 10;
        const unsigned bytes = widths[rng() % 5];
        // Mostly in range, with page edges, the hole, and out-of-range values.
        std::uint64_t address = Base + rng() % (Pages * DataMemory::PageSize + 64) - 32;
        if (rng() % 16 == 0) address = (address & ~std::uint64_t(DataMemory::PageSize - 1)) + DataMemory::PageSize - bytes + rng() % 3;
        if (rng() % 64 == 0) address = 0xfffffffcull + rng() % 8;
        // Often hit the few granules that exclusive operations reserve.
        if (rng() % 4 == 0) address = Base + 64 * (rng() % 4) + rng() % 48;
        if (op < 5) {
            auto run = [&](Machine &m) {
                return m.slice([&](as6aot::Context &c) {
                    const auto value = as6aot::load(c, address, bytes);
                    return std::make_pair(value, std::make_pair(c.status, c.fault_address));
                });
            };
            const auto a = run(slow), b = run(fast);
            expect(a == b, "load", step);
            directLoads += b.second.first == as6aot::Returned;
        } else if (op < 9) {
            as6aot::Word value = (as6aot::Word(rng()) << 96) | (as6aot::Word(rng()) << 64) |
                                 (as6aot::Word(rng()) << 32) | rng();
            if (bytes < 16) value &= (as6aot::Word(1) << (bytes * 8)) - 1;
            auto run = [&](Machine &m) {
                return m.slice([&](as6aot::Context &c) {
                    as6aot::store(c, address, bytes, value);
                    return std::make_pair(c.status, c.fault_address);
                });
            };
            const auto a = run(slow), b = run(fast);
            expect(a == b, "store", step);
            directStores += b.first == as6aot::Returned;
        } else {
            // Arm or try to complete a reservation in the RW pages; a direct
            // store into its granule must still break it.
            const std::uint32_t at = Base + 64 * (rng() % 4) + 4 * (rng() % 2);
            const bool arm = rng() % 2;
            auto run = [&](Machine &m) {
                return m.slice([&](as6aot::Context &c) {
                    std::uint64_t value = 0;
                    std::uint32_t status = 2;
                    as6aot::Status result;
                    if (arm) result = c.data_access->load_exclusive(c.data_access->state, at, 4, &value);
                    else result = c.data_access->store_exclusive(c.data_access->state, at, 4, step, &status);
                    return std::make_pair(std::make_pair(unsigned(result), status), value);
                });
            };
            const auto a = run(slow), b = run(fast);
            expect(a == b, "exclusive", step);
            strexSuccesses += !arm && a.first.first == as6aot::Returned && a.first.second == 0;
            strexFailures += !arm && a.first.first == as6aot::Returned && a.first.second == 1;
        }
        if (step % 4096 == 0) expect(slow.memory.nav_epoch() == fast.memory.nav_epoch(), "epoch", step);
    }
    expect(slow.memory.nav_epoch() == fast.memory.nav_epoch(), "final epoch", 0);
    for (std::uint32_t at = Base; at < Base + Pages * DataMemory::PageSize; at += 16) {
        std::uint8_t a[16]{}, b[16]{};
        const auto ea = slow.memory.read(at, a, 16), eb = fast.memory.read(at, b, 16);
        expect(ea == eb && !std::memcmp(a, b, 16), "final bytes", at);
    }
    std::printf("{\"passed\":%s,\"failures\":%d,\"successful_loads\":%llu,\"successful_stores\":%llu,\"epoch\":%llu,\"strex_ok\":%llu,\"strex_fail\":%llu}\n",
                failures ? "false" : "true", failures, (unsigned long long)directLoads,
                (unsigned long long)directStores, (unsigned long long)fast.memory.nav_epoch(), (unsigned long long)strexSuccesses,
                (unsigned long long)strexFailures);
    return failures ? 1 : 0;
}
