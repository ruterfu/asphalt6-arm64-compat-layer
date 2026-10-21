#pragma once
#include <algorithm>
#include <cmath>

// Private presentation geometry. The original game keeps its 320x480 logical
// surface and existing quarter-turn; UIKit performs the matching touch inverse.
namespace as6canvas {
struct Point { double x, y; };
struct Size { double width, height; };
struct Rect { double x, y, width, height; };
struct Insets { double top, left, bottom, right; };
struct Layout {
    bool valid = false;
    Rect source{}, destination{};
    Point center{};
    double b = 0, c = 0;
};

inline bool finite(Rect value) {
    return std::isfinite(value.x) && std::isfinite(value.y) &&
           std::isfinite(value.width) && std::isfinite(value.height);
}
inline bool positive(Rect value) {
    return finite(value) && value.width > 0 && value.height > 0 &&
           std::isfinite(value.x + value.width) && std::isfinite(value.y + value.height);
}
inline Rect intersection(Rect first, Rect second) {
    if (!positive(first) || !positive(second)) return {};
    const double x = std::max(first.x, second.x), y = std::max(first.y, second.y);
    const double right = std::min(first.x + first.width, second.x + second.width);
    const double bottom = std::min(first.y + first.height, second.y + second.height);
    return {x, y, std::max(0.0, right - x), std::max(0.0, bottom - y)};
}
inline Rect safeFrame(Rect bounds, Rect guide, Insets insets) {
    if (!positive(bounds) || !std::isfinite(insets.top) || !std::isfinite(insets.left) ||
        !std::isfinite(insets.bottom) || !std::isfinite(insets.right) ||
        insets.top < 0 || insets.left < 0 || insets.bottom < 0 || insets.right < 0) return {};
    Rect inset{bounds.x + insets.left, bounds.y + insets.top,
               bounds.width - insets.left - insets.right, bounds.height - insets.top - insets.bottom};
    if (!positive(inset)) return {};
    // Both values are already in UIWindow bounds coordinates. Intersecting
    // avoids exposing a newly unsafe edge while UIKit updates a layout guide.
    return positive(guide) ? intersection(inset, intersection(bounds, guide)) : inset;
}
inline Layout layout(Rect source, Rect safeInSuperview) {
    Layout value;
    if (!positive(source) || !positive(safeInSuperview)) return value;
    value.source = source;
    value.destination = safeInSuperview;
    value.center = {safeInSuperview.x + safeInSuperview.width / 2,
                    safeInSuperview.y + safeInSuperview.height / 2};
    value.b = -safeInSuperview.height / source.width;
    value.c = safeInSuperview.width / source.height;
    value.valid = std::isfinite(value.b) && value.b < 0 && std::isfinite(value.c) && value.c > 0 &&
                  std::isfinite(value.center.x) && std::isfinite(value.center.y);
    return value;
}
inline bool sourceToHost(const Layout &value, Point point, Point *out) {
    if (!value.valid || !out || !std::isfinite(point.x) || !std::isfinite(point.y)) return false;
    const double x = value.source.x + value.source.width / 2;
    const double y = value.source.y + value.source.height / 2;
    *out = {value.center.x + value.c * (point.y - y),
            value.center.y + value.b * (point.x - x)};
    return std::isfinite(out->x) && std::isfinite(out->y);
}
inline bool hostToSource(const Layout &value, Point point, Point *out) {
    if (!value.valid || !out || !std::isfinite(point.x) || !std::isfinite(point.y)) return false;
    *out = {value.source.x + value.source.width / 2 + (point.y - value.center.y) / value.b,
            value.source.y + value.source.height / 2 + (point.x - value.center.x) / value.c};
    return std::isfinite(out->x) && std::isfinite(out->y);
}
inline Rect topTrailingControl(Rect safe, Size requested, double top = 10, double trailing = 16) {
    if (!positive(safe) || !std::isfinite(requested.width) || !std::isfinite(requested.height) ||
        requested.width <= 0 || requested.height <= 0 || !std::isfinite(top) || !std::isfinite(trailing) ||
        top < 0 || trailing < 0) return {};
    const double width = std::min(requested.width, safe.width), height = std::min(requested.height, safe.height);
    const double rightGap = std::min(trailing, safe.width - width);
    const double topGap = std::min(top, safe.height - height);
    return {safe.x + safe.width - rightGap - width, safe.y + topGap, width, height};
}
}
