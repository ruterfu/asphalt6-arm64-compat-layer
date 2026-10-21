// CoreGraphics, translated between two CGFloat widths.
//
// The 2011 binary was built for armv7 where CGFloat is a float; the arm64 host
// is LP64 where CGFloat is a double.  Every CoreGraphics entry point the game
// imports therefore disagrees with the host about both the size of each argument
// and the size of every returned struct, and the two exported constants
// (CGAffineTransformIdentity, CGRectZero) are float-layout aggregates the guest
// reads as 24 and 16 raw bytes.  Forwarding them unchanged hands the driver
// doubles where it wrote floats and makes it write doubles into guest memory --
// the SIGSEGV at a guest stack address in -[UIView initWithFrame::].
//
// The guest's own convention is a flat stream of 32-bit words: r0-r3 then the
// stack, with struct fields occupying consecutive slots and a hidden return
// buffer in r0 when the result does not fit in one word.  Each shim below reads
// that stream, does the arithmetic in the host's own types, and writes the
// result back as floats.

#import "HLE.h"
#import "GuestVM.h"
#import "GuestObjC.h"

#import <CoreGraphics/CoreGraphics.h>
#import <string.h>
#import <vector>

// --- reading the guest's flat word stream -----------------------------------
static double Gd(GuestVM *vm, int i) { return (double)GuestArgF(vm, i); }

// Read `n` consecutive float fields starting at argument slot `first`.
static void GStruct(GuestVM *vm, int first, float *out, int n) {
    for (int i = 0; i < n; i++) out[i] = GuestArgF(vm, first + i);
}

// Write a float-layout aggregate into the guest's hidden return buffer.
static void GReturn(GuestVM *vm, const float *values, int n) {
    gva_t dst = GuestArg(vm, 0);
    if (!dst) return;
    GuestWrite(vm, dst, values, (size_t)n * sizeof(float));
}

static void AffineToGuest(const CGAffineTransform &t, float *o) {
    o[0] = (float)t.a;  o[1] = (float)t.b;  o[2] = (float)t.c;
    o[3] = (float)t.d;  o[4] = (float)t.tx; o[5] = (float)t.ty;
}
static void RectToGuest(const CGRect &r, float *o) {
    o[0] = (float)r.origin.x; o[1] = (float)r.origin.y;
    o[2] = (float)r.size.width; o[3] = (float)r.size.height;
}
static CGRect RectFromGuest(GuestVM *vm, int first) {
    float f[4];
    GStruct(vm, first, f, 4);
    return CGRectMake(f[0], f[1], f[2], f[3]);
}
static CGAffineTransform AffineFromGuest(GuestVM *vm, int first) {
    float f[6];
    GStruct(vm, first, f, 6);
    return CGAffineTransformMake(f[0], f[1], f[2], f[3], f[4], f[5]);
}

// CG references are host objects behind 32-bit handles, never guest virtual
// addresses. Some Foundation/UIKit bridges also return toll-free CG objects
// through the object table, so accept that representation without retaining it.
static void *GRef(GuestVM *vm, int argument) {
    uint32_t word = GuestArg(vm, argument);
    void *pointer = HLEUnwrapOpaque(vm, word);
    if (!pointer && GuestIsHostObject(word))
        pointer = (__bridge void *)GuestObjCUnwrap(vm, word);
    if (!pointer && word) {
        static unsigned errors = 0;
        if (errors++ < 32) {
            char line[192];
            snprintf(line, sizeof(line), "[cg] %s argument %d has no host reference for %#x",
                     HLECurrentSymbol() ?: "?", argument, word);
            GuestRawLog(line);
        }
    }
    return pointer;
}

static CGContextRef GContext(GuestVM *vm) { return (CGContextRef)GRef(vm, 0); }

// Create owns one Core Foundation reference; the opaque table does not add a
// retain. The matching guest CGColorSpaceRelease balances the actual Create.
HLE_DEFINE(hle_cg_colour_space_rgb) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    GuestSetRet(vm, HLEWrapOpaque(vm, (void *)space));
}
HLE_DEFINE(hle_cg_colour_space_release) {
    CGColorSpaceRef space = (CGColorSpaceRef)GRef(vm, 0);
    if (space) CGColorSpaceRelease(space);
}
HLE_DEFINE(hle_cg_image_width) {
    CGImageRef image = (CGImageRef)GRef(vm, 0);
    GuestSetRet(vm, image ? (uint32_t)CGImageGetWidth(image) : 0);
}
HLE_DEFINE(hle_cg_image_height) {
    CGImageRef image = (CGImageRef)GRef(vm, 0);
    GuestSetRet(vm, image ? (uint32_t)CGImageGetHeight(image) : 0);
}

// --- affine transforms ------------------------------------------------------
HLE_DEFINE(hle_affine_rotate) {
    CGAffineTransform t = AffineFromGuest(vm, 1);
    float out[6];
    AffineToGuest(CGAffineTransformRotate(t, Gd(vm, 7)), out);
    GReturn(vm, out, 6);
}
HLE_DEFINE(hle_affine_scale) {
    CGAffineTransform t = AffineFromGuest(vm, 1);
    float out[6];
    AffineToGuest(CGAffineTransformScale(t, Gd(vm, 7), Gd(vm, 8)), out);
    GReturn(vm, out, 6);
}
HLE_DEFINE(hle_affine_make_rotation) {
    float out[6];
    AffineToGuest(CGAffineTransformMakeRotation(Gd(vm, 1)), out);
    GReturn(vm, out, 6);
}

// --- rectangles -------------------------------------------------------------
HLE_DEFINE(hle_rect_inset) {
    CGRect r = RectFromGuest(vm, 1);
    float out[4];
    RectToGuest(CGRectInset(r, Gd(vm, 5), Gd(vm, 6)), out);
    GReturn(vm, out, 4);
}
HLE_DEFINE(hle_rect_offset) {
    CGRect r = RectFromGuest(vm, 1);
    float out[4];
    RectToGuest(CGRectOffset(r, Gd(vm, 5), Gd(vm, 6)), out);
    GReturn(vm, out, 4);
}
HLE_DEFINE(hle_rect_get_min_x) { GuestSetRetF(vm, (float)RectFromGuest(vm, 0).origin.x); }
HLE_DEFINE(hle_rect_get_min_y) { GuestSetRetF(vm, (float)RectFromGuest(vm, 0).origin.y); }
HLE_DEFINE(hle_rect_get_width) { GuestSetRetF(vm, (float)RectFromGuest(vm, 0).size.width); }
HLE_DEFINE(hle_rect_get_height) { GuestSetRetF(vm, (float)RectFromGuest(vm, 0).size.height); }
HLE_DEFINE(hle_rect_is_empty) {
    CGRect r = RectFromGuest(vm, 0);
    GuestSetRet(vm, (r.size.width <= 0 || r.size.height <= 0) ? 1 : 0);
}

// --- context entry points with CGFloat arguments ----------------------------
HLE_DEFINE(hle_ctx_add_rect) {
    CGContextRef c = GContext(vm);
    if (c) CGContextAddRect(c, RectFromGuest(vm, 1));
}
HLE_DEFINE(hle_ctx_fill_rect) {
    CGContextRef c = GContext(vm);
    if (c) CGContextFillRect(c, RectFromGuest(vm, 1));
}
HLE_DEFINE(hle_ctx_draw_image) {
    CGContextRef c = GContext(vm);
    CGImageRef image = (CGImageRef)GRef(vm, 5);
    if (c && image) CGContextDrawImage(c, RectFromGuest(vm, 1), image);
}
HLE_DEFINE(hle_ctx_move_to_point) {
    CGContextRef c = GContext(vm);
    if (c) CGContextMoveToPoint(c, Gd(vm, 1), Gd(vm, 2));
}
HLE_DEFINE(hle_ctx_add_arc_to_point) {
    CGContextRef c = GContext(vm);
    if (c) CGContextAddArcToPoint(c, Gd(vm, 1), Gd(vm, 2), Gd(vm, 3), Gd(vm, 4), Gd(vm, 5));
}
HLE_DEFINE(hle_ctx_scale_ctm) {
    CGContextRef c = GContext(vm);
    if (c) CGContextScaleCTM(c, Gd(vm, 1), Gd(vm, 2));
}
HLE_DEFINE(hle_ctx_translate_ctm) {
    CGContextRef c = GContext(vm);
    if (c) CGContextTranslateCTM(c, Gd(vm, 1), Gd(vm, 2));
}
HLE_DEFINE(hle_ctx_set_line_width) {
    CGContextRef c = GContext(vm);
    if (c) CGContextSetLineWidth(c, Gd(vm, 1));
}

HLE_DEFINE(hle_ctx_begin_path) { CGContextRef c = GContext(vm); if (c) CGContextBeginPath(c); }
HLE_DEFINE(hle_ctx_close_path) { CGContextRef c = GContext(vm); if (c) CGContextClosePath(c); }
HLE_DEFINE(hle_ctx_fill_path) { CGContextRef c = GContext(vm); if (c) CGContextFillPath(c); }
HLE_DEFINE(hle_ctx_save_state) { CGContextRef c = GContext(vm); if (c) CGContextSaveGState(c); }
HLE_DEFINE(hle_ctx_restore_state) { CGContextRef c = GContext(vm); if (c) CGContextRestoreGState(c); }
HLE_DEFINE(hle_ctx_set_stroke_space) {
    CGContextRef c = GContext(vm);
    CGColorSpaceRef space = (CGColorSpaceRef)GRef(vm, 1);
    if (c && space) CGContextSetStrokeColorSpace(c, space);
}

// The original imports only CGColorSpaceCreateDeviceRGB; its component arrays
// are RGB plus alpha. CGFloat is 4 bytes in the guest and 8 in the host.
static void SetColourFromGuest(GuestVM *vm, BOOL stroke) {
    CGContextRef c = GContext(vm);
    if (!c) return;
    float input[4];
    if (!GuestRead(vm, GuestArg(vm, 1), input, sizeof(input))) return;
    CGFloat colour[4];
    for (size_t i = 0; i < 4; i++) colour[i] = input[i];
    if (stroke) CGContextSetStrokeColor(c, colour);
    else CGContextSetFillColor(c, colour);
}

HLE_DEFINE(hle_ctx_set_fill_colour) {
    SetColourFromGuest(vm, NO);
}
HLE_DEFINE(hle_ctx_set_stroke_colour) {
    SetColourFromGuest(vm, YES);
}
HLE_DEFINE(hle_ctx_stroke_line_segments) {
    CGContextRef c = GContext(vm);
    gva_t pts = GuestArg(vm, 1);
    size_t count = GuestArg(vm, 2);
    if (!c || !pts || !count || count > UINT32_MAX / (2 * sizeof(float)) ||
        (uint64_t)pts + count * 2 * sizeof(float) > (UINT64_C(1) << 32)) return;
    try {
        std::vector<float> input(count * 2);
        std::vector<CGPoint> points(count);
        if (!GuestRead(vm, pts, input.data(), input.size() * sizeof(float))) return;
        for (size_t i = 0; i < count; i++) points[i] = CGPointMake(input[2 * i], input[2 * i + 1]);
        CGContextStrokeLineSegments(c, points.data(), count);
    } catch (...) { GuestRawLog("[cg] failed to allocate converted line-segment points"); }
}

HLE_BIND("_CGAffineTransformRotate", hle_affine_rotate)
HLE_BIND("_CGAffineTransformScale", hle_affine_scale)
HLE_BIND("_CGAffineTransformMakeRotation", hle_affine_make_rotation)
HLE_BIND("_CGRectInset", hle_rect_inset)
HLE_BIND("_CGRectOffset", hle_rect_offset)
HLE_BIND("_CGRectGetMinX", hle_rect_get_min_x)
HLE_BIND("_CGRectGetMinY", hle_rect_get_min_y)
HLE_BIND("_CGRectGetWidth", hle_rect_get_width)
HLE_BIND("_CGRectGetHeight", hle_rect_get_height)
HLE_BIND("_CGRectIsEmpty", hle_rect_is_empty)
HLE_BIND("_CGColorSpaceCreateDeviceRGB", hle_cg_colour_space_rgb)
HLE_BIND("_CGColorSpaceRelease", hle_cg_colour_space_release)
HLE_BIND("_CGImageGetWidth", hle_cg_image_width)
HLE_BIND("_CGImageGetHeight", hle_cg_image_height)
HLE_BIND("_CGContextAddRect", hle_ctx_add_rect)
HLE_BIND("_CGContextFillRect", hle_ctx_fill_rect)
HLE_BIND("_CGContextDrawImage", hle_ctx_draw_image)
HLE_BIND("_CGContextMoveToPoint", hle_ctx_move_to_point)
HLE_BIND("_CGContextAddArcToPoint", hle_ctx_add_arc_to_point)
HLE_BIND("_CGContextScaleCTM", hle_ctx_scale_ctm)
HLE_BIND("_CGContextTranslateCTM", hle_ctx_translate_ctm)
HLE_BIND("_CGContextSetLineWidth", hle_ctx_set_line_width)
HLE_BIND("_CGContextBeginPath", hle_ctx_begin_path)
HLE_BIND("_CGContextClosePath", hle_ctx_close_path)
HLE_BIND("_CGContextFillPath", hle_ctx_fill_path)
HLE_BIND("_CGContextSaveGState", hle_ctx_save_state)
HLE_BIND("_CGContextRestoreGState", hle_ctx_restore_state)
HLE_BIND("_CGContextSetStrokeColorSpace", hle_ctx_set_stroke_space)
HLE_BIND("_CGContextSetFillColor", hle_ctx_set_fill_colour)
HLE_BIND("_CGContextSetStrokeColor", hle_ctx_set_stroke_colour)
HLE_BIND("_CGContextStrokeLineSegments", hle_ctx_stroke_line_segments)

// --- the two exported aggregates --------------------------------------------
// dyld would have pointed these slots at the dylib's own float-layout structs;
// the host copies hold doubles, so the guest gets its own copies instead.
BOOL GuestCgDataValue(GuestVM *vm, const char *symbol, uint32_t *out) {
    if (!strcmp(symbol, "_CGAffineTransformIdentity")) {
        static const float id6[6] = {1, 0, 0, 1, 0, 0};
        gva_t g = GuestAlloc(vm, sizeof(id6));
        if (!g) return NO;
        GuestWrite(vm, g, id6, sizeof(id6));
        *out = g;
        return YES;
    }
    if (!strcmp(symbol, "_CGRectZero")) {
        static const float zero4[4] = {0, 0, 0, 0};
        gva_t g = GuestAlloc(vm, sizeof(zero4));
        if (!g) return NO;
        GuestWrite(vm, g, zero4, sizeof(zero4));
        *out = g;
        return YES;
    }
    return NO;
}
