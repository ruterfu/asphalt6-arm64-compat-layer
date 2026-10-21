#include "DecodedArtwork.hpp"
#include "BackgroundAspect.hpp"
#include <cstring>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <algorithm>
#include <new>

namespace as6_background {
namespace {
struct ArtworkPin { const char *name, *legacy_sha, *jpeg_sha; std::size_t jpeg_bytes; unsigned width, height; };
#include "jpeg_art_pins.hpp"
template<class T> struct OwnedCF {
    T value;
    explicit OwnedCF(T v) : value(v) {}
    ~OwnedCF() { if (value) CFRelease(value); }
    OwnedCF(const OwnedCF &) = delete;
    OwnedCF &operator=(const OwnedCF &) = delete;
};
bool Dimension(CFDictionaryRef properties, CFStringRef key, unsigned expected) {
    const auto value = CFDictionaryGetValue(properties, key);
    std::int64_t number = 0;
    return value && CFGetTypeID(value) == CFNumberGetTypeID() &&
        CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberSInt64Type, &number) &&
        number == expected;
}
}
bool DecodeArtworkJpeg(const char *resource_name, const std::uint8_t *jpeg, std::size_t bytes,
                       DecodedArtwork &result, std::string &error) {
    error.clear();
    const ArtworkPin *pin = nullptr;
    for (const auto &candidate : kArtworkPins)
        if (resource_name && !std::strcmp(resource_name, candidate.name)) { pin = &candidate; break; }
    if (!pin || !jpeg || bytes != pin->jpeg_bytes ||
        Sha256(jpeg, bytes) != pin->jpeg_sha) {
        error = "artwork JPEG source SHA/size mismatch"; return false;
    }
    try {
        OwnedCF<CFDataRef> data(CFDataCreate(kCFAllocatorDefault, jpeg, CFIndex(bytes)));
        if (!data.value) { error = "JPEG source allocation failed"; return false; }
        OwnedCF<CGImageSourceRef> source(CGImageSourceCreateWithData(data.value, nullptr));
        if (!source.value || CGImageSourceGetCount(source.value) != 1 ||
            !CGImageSourceGetType(source.value) ||
            !CFEqual(CGImageSourceGetType(source.value), CFSTR("public.jpeg"))) {
            error = "unsupported artwork JPEG source"; return false;
        }
        OwnedCF<CFDictionaryRef> properties(CGImageSourceCopyPropertiesAtIndex(source.value, 0, nullptr));
        if (!properties.value ||
            !Dimension(properties.value, kCGImagePropertyPixelWidth, pin->width) ||
            !Dimension(properties.value, kCGImagePropertyPixelHeight, pin->height)) {
            error = "artwork JPEG dimensions mismatch"; return false;
        }
        const auto orientation = CFDictionaryGetValue(properties.value, kCGImagePropertyOrientation);
        if (orientation && !Dimension(properties.value, kCGImagePropertyOrientation, 1)) {
            error = "unsupported artwork JPEG orientation"; return false;
        }
        OwnedCF<CGImageRef> image(CGImageSourceCreateImageAtIndex(source.value, 0, nullptr));
        if (!image.value || CGImageGetWidth(image.value) != pin->width ||
            CGImageGetHeight(image.value) != pin->height ||
            CGImageGetBitsPerComponent(image.value) != 8 ||
            !CGImageGetColorSpace(image.value) ||
            CGColorSpaceGetModel(CGImageGetColorSpace(image.value)) != kCGColorSpaceModelRGB ||
            (CGImageGetAlphaInfo(image.value) != kCGImageAlphaNone &&
             CGImageGetAlphaInfo(image.value) != kCGImageAlphaNoneSkipFirst &&
             CGImageGetAlphaInfo(image.value) != kCGImageAlphaNoneSkipLast)) {
            error = "artwork JPEG decoded-image contract mismatch"; return false;
        }
        DecodedArtwork next;
        next.pixels_.assign(std::size_t(pin->width) * pin->height * 4, 0);
        OwnedCF<CGColorSpaceRef> color(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
        OwnedCF<CGContextRef> context(color.value ? CGBitmapContextCreate(next.pixels_.data(),
            pin->width, pin->height, 8, pin->width * 4,
            color.value, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst) : nullptr);
        if (!context.value) { error = "artwork JPEG BGRA context failed"; return false; }
        CGContextSetBlendMode(context.value, kCGBlendModeCopy);
        CGContextDrawImage(context.value,
            CGRectMake(0, 0, pin->width, pin->height), image.value);
        // The source is opaque JPEG. Define the fourth byte explicitly even
        // if a platform decoder changes its internal alpha representation.
        for (std::size_t i = 3; i < next.pixels_.size(); i += 4) next.pixels_[i] = 255;
        next.cache_identity_ = std::string("artwork-jpeg-srgb-bgra-v1:") + pin->jpeg_sha +
            ":" + std::to_string(pin->width) + "/" + std::to_string(pin->height) +
            ":" + Sha256(next.pixels_.data(), next.pixels_.size());
        next.legacy_identity_ = pin->legacy_sha;
        next.width_ = pin->width; next.height_ = pin->height;
        next.authenticated_ = true;
        result = std::move(next); return true;
    } catch (const std::bad_alloc &) { error = "artwork JPEG allocation failed"; return false; }
}
}
