#pragma once
#include <cstddef>
#include <cstdint>
#include <limits>

// Physical raster coordinates only. Movie bounds, RT logical rectangles,
// projection matrices, texture UVs and the original driver caches stay intact.
namespace as6_flash_raster {
constexpr std::uint32_t PhysicalExtent = 4096;
inline bool logicalExtent(std::uint32_t value) {
    return value >= 128 && value <= 2048 && !(value & (value - 1));
}
struct Rect { std::int32_t x, y, width, height; };
inline bool equal(Rect a, Rect b) {
    return a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height;
}
inline bool narrow(std::int64_t value, std::int32_t &out) {
    if (value < std::numeric_limits<std::int32_t>::min() ||
        value > std::numeric_limits<std::int32_t>::max()) return false;
    out = std::int32_t(value); return true;
}
inline bool scale(Rect source, std::uint32_t logicalWidth, std::uint32_t logicalHeight, Rect &result) {
    if (source.width < 0 || source.height < 0 ||
        !logicalExtent(logicalWidth) || !logicalExtent(logicalHeight)) return false;
    const auto factorX = PhysicalExtent / logicalWidth, factorY = PhysicalExtent / logicalHeight;
    return narrow(std::int64_t(source.x) * factorX, result.x) &&
           narrow(std::int64_t(source.y) * factorY, result.y) &&
           narrow(std::int64_t(source.width) * factorX, result.width) &&
           narrow(std::int64_t(source.height) * factorY, result.height);
}
inline int driverRegister(bool scissor, std::uint32_t lr) {
    if (!scissor) return (lr == 0x4f6150u || lr == 0x5038b0u) ? 5 : -1;
    return (lr == 0x4f5a30u || lr == 0x50365cu || lr == 0x4fa668u ||
            lr == 0x5082b4u || lr == 0x4faeccu || lr == 0x50884cu) ? 4 : -1;
}
template<class Read> bool words(Read read, std::uint32_t base, std::uint32_t offset,
                                std::uint32_t *out, std::size_t count) {
    const auto address = std::uint64_t(base) + offset;
    if (!base || address + count * 4 > (std::uint64_t(1) << 32)) return false;
    return read(std::uint32_t(address), out, count * 4);
}
struct Target {
    std::uint32_t current = 0, root = 0, depth = 0, texture = 0, framebuffer = 0;
    std::uint32_t logicalWidth = 0, logicalHeight = 0;
    bool menu = false, logicalViewport = false, restoredViewport = false;
};
// The containing HLE state supplies the real VM/context identity and clears this
// bounded cache whenever either changes. FBO generation/deletion invalidates
// entries too, so recycled RT/texture addresses cannot inherit an old bitmap.
struct LogicalDomains {
    static constexpr unsigned Capacity = 16;
    struct Entry {
        std::uint32_t target = 0, texture = 0, framebuffer = 0, width = 0, height = 0;
    };
    Entry entries[Capacity]{};
    unsigned next = 0;
    void forgetFramebuffer(std::uint32_t framebuffer) {
        for (auto &entry : entries) if (entry.framebuffer == framebuffer) entry = {};
    }
    bool resolve(Target &target) {
        if (!target.menu || !target.current || !target.texture || !target.framebuffer) return false;
        Entry *found = nullptr;
        for (auto &entry : entries) {
            if (entry.target == target.current && entry.texture == target.texture &&
                entry.framebuffer == target.framebuffer) { found = &entry; break; }
        }
        if (target.logicalViewport && logicalExtent(target.logicalWidth) && logicalExtent(target.logicalHeight)) {
            if (!found) { found = &entries[next]; next = (next + 1) % Capacity; }
            *found = {target.current, target.texture, target.framebuffer, target.logicalWidth, target.logicalHeight};
            return true;
        }
        // Only EndDisplay's exact full physical rectangle may reuse the most
        // recent logical domain. Partial/unsupported rectangles never do.
        if (!target.restoredViewport || !found) return false;
        target.logicalWidth = found->width; target.logicalHeight = found->height;
        return true;
    }
};
template<class Read> bool target(Read read, std::uint32_t driver, Target &out) {
    out = {};
    std::uint32_t vtable, stack[2];
    if (!words(read, driver, 0, &vtable, 1) ||
        (vtable != 0x73f678u && vtable != 0x73fdc4u) ||
        !words(read, driver, 0xa4, stack, 2) || !stack[0] ||
        stack[1] <= stack[0] || (stack[1] - stack[0]) % 4 ||
        !words(read, stack[0], 0, &out.root, 1) ||
        !words(read, stack[1] - 4, 0, &out.current, 1) || !out.current) return false;
    out.depth = (stack[1] - stack[0]) / 4;
    if (out.depth <= 1) return true;
    std::uint32_t manager, targets[6], textures[6];
    if (!words(read, 0x70b1d4u, 0, &manager, 1)) return false;
    if (!manager) return true;
    if (!words(read, manager, 0x4c, targets, 6) ||
        !words(read, manager, 0x7c, textures, 6)) return false;
    int slot = -1;
    for (int i = 0; i < 6; ++i) if (targets[i] == out.current) { slot = i; break; }
    if (slot < 0) return true;
    std::uint32_t rt[9], extent[2], game, effects, shared;
    if (!words(read, out.current, 0xc, rt, 9)) return false;
    if (!rt[8] || rt[8] != textures[slot]) return true;
    if (!words(read, rt[8], 0xc, extent, 2) ||
        !words(read, 0x70b230u, 0, &game, 1) || !game ||
        !words(read, game, 0x1b0, &effects, 1) || !effects ||
        !words(read, effects, 0x5c, &shared, 1)) return false;
    if (rt[8] == shared || rt[0] != PhysicalExtent || rt[1] != PhysicalExtent ||
        extent[0] != PhysicalExtent || extent[1] != PhysicalExtent) return true;
    out.texture = rt[8]; out.framebuffer = rt[6]; out.menu = true;
    out.logicalViewport = rt[2] == 0 && rt[3] == 0 && logicalExtent(rt[4]) && logicalExtent(rt[5]);
    out.restoredViewport = rt[2] == 0 && rt[3] == 0 &&
                           rt[4] == PhysicalExtent && rt[5] == PhysicalExtent;
    if (out.logicalViewport) { out.logicalWidth = rt[4]; out.logicalHeight = rt[5]; }
    return true;
}
template<class Read> bool cachedRect(Read read, std::uint32_t driver, bool scissor,
                                    const Target &current, Rect &out) {
    // Both original setters store x0,y0,x1,y1 followed by orientation.
    std::uint32_t cached[5];
    if (!words(read, driver, scissor ? 0x210 : 0x224, cached, 5) || cached[4]) return false;
    const auto x0 = std::int32_t(cached[0]), y0 = std::int32_t(cached[1]);
    if (!narrow(std::int64_t(std::int32_t(cached[2])) - x0, out.width) ||
        !narrow(std::int64_t(std::int32_t(cached[3])) - y0, out.height) ||
        out.width < 0 || out.height < 0) return false;
    out.x = x0; out.y = y0;
    if (current.depth > 1) return true; // Original 4d0694: raw offscreen x/y.
    // A default-target orientation other than zero differs from the offscreen
    // cached orientation and therefore makes the original setter run. Zero is
    // the one possible cache hit: reproduce 51cefc + 4d0668 for that case only.
    std::uint32_t orientation, root[10];
    if (!words(read, driver, 0x11c, &orientation, 1) || orientation ||
        !words(read, current.root, 0xc, root, 10)) return false;
    const bool translated = root[8] || root[9]; // root + 2c/30.
    const auto tx = translated ? std::int32_t(root[6]) : 0; // +24/28.
    const auto ty = translated ? std::int32_t(root[7]) : 0;
    return narrow(std::int64_t(out.x) + tx, out.x) &&
           narrow(std::int64_t(std::int32_t(root[1])) + std::int32_t(root[9]) -
                  (std::int64_t(out.y) + ty) - out.height, out.y);
}
inline bool mappedRect(bool scissor, const Target &current, Rect source, Rect &out) {
    out = source;
    // EndDisplay restores the physical RT viewport before restoring scissor.
    // Its scissor remains in the original logical coordinate domain throughout.
    Rect scaled;
    if (!current.menu || (!scissor && !current.logicalViewport) ||
        !scale(source, current.logicalWidth, current.logicalHeight, scaled)) return false;
    out = scaled;
    return true;
}
} // namespace as6_flash_raster
