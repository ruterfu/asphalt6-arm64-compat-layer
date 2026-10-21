#include "NativeGamePolicy.hpp"
#include "NativeStartupRecovery.hpp"
#include "register_layout.hpp"
#include "OriginalUIBoundary.hpp"
#include "NativeMusicBoundary.hpp"
#include "PostEffectsTargetSize.hpp"
#include <atomic>
#include <cerrno>
#include <cstdio>

namespace {
using namespace as6aot;
constexpr std::uint32_t LaunchGameloftLive = 0x280cu;
constexpr std::uint32_t CreateStoreInstance = 0x2baa38u;
constexpr std::uint32_t IsStoreEnabled = 0x2ba934u;
constexpr std::uint32_t StoreEnabledByte = 0x70e43cu;
constexpr std::uint32_t NativeGotoPopout = 0xfb37cu;
constexpr std::uint32_t BuyStore = 0x2ba98cu;
constexpr std::uint32_t SetCurrentMenu = 0x1935cu;
constexpr std::uint32_t OpenAppStoreLink = 0x9400u;
constexpr std::uint32_t EnterAppStore = 0x9ad4u;
constexpr std::uint32_t NativeBuyStarUnlock = 0xfed6cu;
constexpr std::uint32_t NativeItemID = 0xfc0e0u;
constexpr std::uint32_t BuyItem = 0x2b28ccu;
constexpr std::uint32_t ReturnStoreToForeground = 0x2b1d40u;
constexpr std::uint32_t CreateTexture = 0x50d098u;
constexpr std::uint32_t PostEffectsColorTextureReturn = 0x1d6abcu;
constexpr std::uint32_t PostEffectsScreenExtent = 0x749f20u;
constexpr std::uint32_t SetPostEffectsScreenRatio = 0x1d1454u;
constexpr std::uint32_t SpecialWidePostEffectsFlag = 0x70dd08u;
constexpr std::uint32_t FlashTargetChoice = 0x5bcf8u;
constexpr std::uint32_t GenericTexture = 0xb2254u;
constexpr std::uint32_t RatioUVStart = 0x1d15acu;
constexpr std::uint32_t RatioUVWidth = 0x1d15e0u;
constexpr std::uint32_t RatioUVHeight = 0x1d1608u;

bool SquareSurface(Context &ctx) {
    const auto width = load(ctx, Word(PostEffectsScreenExtent), 4);
    if (ctx.status != Returned) return false;
    const auto height = load(ctx, Word(PostEffectsScreenExtent + 4), 4);
    if (ctx.status != Returned) return false;
    if (!as6_post_effects::supersampledSurface({std::uint32_t(width), std::uint32_t(height)}))
        return false;
    const auto wide = load(ctx, Word(SpecialWidePostEffectsFlag), 1);
    return ctx.status == Returned && !wide;
}

Status SquareFlashTexture(Context &ctx, bool legacy, std::uint32_t stop, bool thumb) {
    const auto original = AS6NativeProgramWithStartupRecovery()->lookup(GenericTexture, false);
    if (!ctx.registers || ctx.register_size < layout::Size || ctx.isa_thumb || ctx.next_pc != GenericTexture)
        return ctx.status = InvalidState;
    if ((!legacy && ctx.next_pc == stop && ctx.isa_thumb == thumb) || !ctx.budget)
        return original(ctx, legacy, stop, thumb);
    // Only the original Flash own-target constructor call. Keep all movie,
    // stage, hit-test and authored bitmap dimensions at their original size.
    const auto bitmapExtent = [](Word value) {
        // The original scene-movie table includes narrow 256x512 panels as
        // well as 1024-square pages. Keep every original logical size intact;
        // only this exact own-target allocation receives a square raster.
        return value >= 128 && value <= 2048 && !(value & (value - 1));
    };
    if (read_bytes(ctx.registers, layout::lr, 4) == 0x5bf90u &&
        bitmapExtent(read_bytes(ctx.registers, layout::r1, 4)) &&
        bitmapExtent(read_bytes(ctx.registers, layout::r2, 4)) && SquareSurface(ctx)) {
        write_bytes(ctx.registers, layout::r1, 4, Word(as6_post_effects::UnifiedSquareSide));
        write_bytes(ctx.registers, layout::r2, 4, Word(as6_post_effects::UnifiedSquareSide));
    }
    if (ctx.status != Returned) return ctx.status;
    return original(ctx, legacy, stop, thumb);
}

Status SquarePostEffectsUV(Context &ctx, bool legacy, std::uint32_t stop, bool thumb) {
    const auto *base = AS6NativeProgramWithStartupRecovery();
    if (!ctx.registers || ctx.register_size < layout::Size || ctx.isa_thumb ||
        ctx.next_pc < RatioUVStart || ctx.next_pc > RatioUVHeight || (ctx.next_pc & 3u))
        return ctx.status = InvalidState;
    auto original = base->lookup(ctx.next_pc, false);
    if ((!legacy && ctx.next_pc == stop && ctx.isa_thumb == thumb) || !ctx.budget)
        return original(ctx, legacy, stop, thumb);
    const bool surface = SquareSurface(ctx);
    if (ctx.status != Returned) return ctx.status;
    if (!surface) return original(ctx, legacy, stop, thumb);
    // This straight-line original continuation follows the color mesh lock.
    // Validate the actual color texture, rather than assuming its allocation.
    const auto sp = std::uint32_t(read_bytes(ctx.registers, layout::sp, 4));
    if (sp > UINT32_MAX - 8u) return original(ctx, legacy, stop, thumb);
    const auto self = std::uint32_t(load(ctx, Word(sp + 8u), 4));
    if (ctx.status != Returned) return ctx.status;
    if (!self || self > UINT32_MAX - 0x5cu) return original(ctx, legacy, stop, thumb);
    const auto texture = std::uint32_t(load(ctx, Word(self + 0x5cu), 4));
    if (ctx.status != Returned) return ctx.status;
    if (!texture || texture > UINT32_MAX - 0x10u) return original(ctx, legacy, stop, thumb);
    const auto width = load(ctx, Word(texture + 0xcu), 4);
    if (ctx.status != Returned) return ctx.status;
    const auto height = load(ctx, Word(texture + 0x10u), 4);
    if (ctx.status != Returned) return ctx.status;
    if (width != as6_post_effects::UnifiedSquareSide || height != as6_post_effects::UnifiedSquareSide)
        return original(ctx, legacy, stop, thumb);
    // Run the unchanged native instructions to each VMOV boundary. Their
    // per-instruction stop/budget/fault checks remain authoritative. Cover every
    // PC in this slice in Lookup so a budget resume cannot miss either edit.
    const auto until = [&](std::uint32_t boundary) {
        const bool external = !legacy && !thumb && stop >= ctx.next_pc && stop <= boundary;
        const auto limit = external ? stop : boundary;
        for (;;) {
            const auto fn = base->lookup(ctx.next_pc, ctx.isa_thumb);
            if (!fn) return ctx.status = UnresolvedTarget;
            const auto status = fn(ctx, false, limit, false);
            if (status != Dispatch) return ctx.status = status;
        }
    };
    if (ctx.next_pc < RatioUVWidth) {
        const auto status = until(RatioUVWidth);
        if (status != Returned || (!legacy && ctx.next_pc == stop && ctx.isa_thumb == thumb)) return status;
    }
    if (ctx.next_pc == RatioUVWidth) {
        if (!ctx.budget) return ctx.status = BudgetExhausted;
        write_bytes(ctx.registers, layout::r2, 4, Word(as6_post_effects::UnifiedSquareSide));
    }
    if (ctx.next_pc < RatioUVHeight) {
        const auto status = until(RatioUVHeight);
        if (status != Returned || (!legacy && ctx.next_pc == stop && ctx.isa_thumb == thumb)) return status;
    }
    if (ctx.next_pc == RatioUVHeight) {
        if (!ctx.budget) return ctx.status = BudgetExhausted;
        write_bytes(ctx.registers, layout::r1, 4, Word(as6_post_effects::UnifiedSquareSide));
    }
    original = base->lookup(ctx.next_pc, false);
    return original(ctx, legacy, stop, thumb);
}

Status IndependentFlashRenderTarget(Context &ctx, bool legacy, std::uint32_t stop_pc, bool stop_thumb) {
    const auto original = AS6NativeProgramWithStartupRecovery()->lookup(FlashTargetChoice, false);
    if (!ctx.registers || ctx.register_size < layout::Size || ctx.isa_thumb ||
        ctx.next_pc != FlashTargetChoice) return ctx.status = InvalidState;
    if ((!legacy && ctx.next_pc == stop_pc && ctx.isa_thumb == stop_thumb) || !ctx.budget ||
        read_bytes(ctx.registers, layout::r0, 4) == 0)
        return original(ctx, legacy, stop_pc, stop_thumb);
    // This is the exact return from the constructor's node-name comparison,
    // immediately before its original CMP/BEQ. Only the enlarged shared-target
    // case selects the existing per-node, independently sized texture path.
    as6_post_effects::Extent screen{};
    screen.width = std::uint32_t(load(ctx, Word(PostEffectsScreenExtent), 4));
    if (ctx.status != Returned) return ctx.status;
    screen.height = std::uint32_t(load(ctx, Word(PostEffectsScreenExtent + 4), 4));
    if (ctx.status != Returned) return ctx.status;
    if (!as6_post_effects::supersampledSurface(screen))
        return original(ctx, legacy, stop_pc, stop_thumb);
    const auto wide = load(ctx, Word(SpecialWidePostEffectsFlag), 1);
    if (ctx.status != Returned) return ctx.status;
    if (wide) return original(ctx, legacy, stop_pc, stop_thumb);
    const auto device = load(ctx, Word(0x70dcc8u), 4);
    if (ctx.status != Returned) return ctx.status;
    const auto sharing = load(ctx, Word(0x70d42cu), 4);
    if (ctx.status != Returned) return ctx.status;
    if (device == 11 || sharing != 1) return original(ctx, legacy, stop_pc, stop_thumb);
    const auto game = std::uint32_t(load(ctx, Word(0x70b230u), 4));
    if (ctx.status != Returned) return ctx.status;
    if (!game || game > UINT32_MAX - 0x1b0u) return original(ctx, legacy, stop_pc, stop_thumb);
    const auto effects = std::uint32_t(load(ctx, Word(game + 0x1b0u), 4));
    if (ctx.status != Returned) return ctx.status;
    if (!effects || effects > UINT32_MAX - 0x5cu) return original(ctx, legacy, stop_pc, stop_thumb);
    const auto texture = std::uint32_t(load(ctx, Word(effects + 0x5cu), 4));
    if (ctx.status != Returned) return ctx.status;
    if (!texture || texture > UINT32_MAX - 0x10u) return original(ctx, legacy, stop_pc, stop_thumb);
    const auto width = std::uint32_t(load(ctx, Word(texture + 0xcu), 4));
    if (ctx.status != Returned) return ctx.status;
    const auto height = std::uint32_t(load(ctx, Word(texture + 0x10u), 4));
    if (ctx.status != Returned) return ctx.status;
    const auto enlarged = as6_post_effects::targetExtent(screen, {1024, 1024});
    if (width == enlarged.width && height == enlarged.height) {
        // Original 5bf48 obtains the Flash handler's own bitmap extent, calls
        // SceneHelper::GetGenericTexture with its plane name, creates a matching
        // RT and assigns it through the existing intrusive-pointer lifecycle.
        // Keep movie bounds, authored mesh UVs and raycast/hit dimensions intact.
        write_bytes(ctx.registers, layout::r0, 4, Word(0));
        static std::atomic<unsigned> logs{0};
        if (logs.fetch_add(1, std::memory_order_relaxed) < 8) {
            const int savedErrno = errno;
        std::fprintf(stderr, "[flash-render-target] independent square bitmap target; shared-post-effects=%ux%u\n", width, height);
            errno = savedErrno;
        }
    }
    return original(ctx, legacy, stop_pc, stop_thumb);
}

Status FixedPostEffectsScreenRatio(Context &ctx, bool legacy, std::uint32_t stop_pc, bool stop_thumb) {
    const auto original = AS6NativeProgramWithStartupRecovery()->lookup(SetPostEffectsScreenRatio, false);
    if (!ctx.registers || ctx.register_size < layout::Size || ctx.isa_thumb ||
        ctx.next_pc != SetPostEffectsScreenRatio) return ctx.status = InvalidState;
    if ((!legacy && ctx.next_pc == stop_pc && ctx.isa_thumb == stop_thumb) || !ctx.budget)
        return original(ctx, legacy, stop_pc, stop_thumb);
    const auto caller = std::uint32_t(read_bytes(ctx.registers, layout::lr, 4));
    // Four PreDraw branches plus the constructor's final initialization.
    // Keep all original effects and camera work; only their resolution request
    // is fixed. The original armv7 soft-float ABI carries the ratio in r1.
    if (caller == 0x1d2400u || caller == 0x1d2478u || caller == 0x1d2558u ||
        caller == 0x1d260cu || caller == 0x1d7498u) {
        as6_post_effects::Extent screen{};
        screen.width = std::uint32_t(load(ctx, Word(PostEffectsScreenExtent), 4));
        if (ctx.status != Returned) return ctx.status;
        screen.height = std::uint32_t(load(ctx, Word(PostEffectsScreenExtent + 4), 4));
        if (ctx.status != Returned) return ctx.status;
        const bool specialWide = bool(load(ctx, Word(SpecialWidePostEffectsFlag), 1));
        if (ctx.status != Returned) return ctx.status;
        if (!specialWide && as6_post_effects::supersampledSurface(screen))
            write_bytes(ctx.registers, layout::r1, 4, Word(0x3f800000u)); // 1.0f
    }
    return original(ctx, legacy, stop_pc, stop_thumb);
}

Status PostEffectsTextureSize(Context &ctx, bool legacy, std::uint32_t stop_pc, bool stop_thumb) {
    const auto original = AS6NativeProgramWithStartupRecovery()->lookup(CreateTexture, false);
    if (!ctx.registers || ctx.register_size < layout::Size || ctx.isa_thumb ||
        ctx.next_pc != CreateTexture) return ctx.status = InvalidState;
    // Preserve the original stop/budget boundary before any policy write.
    if ((!legacy && ctx.next_pc == stop_pc && ctx.isa_thumb == stop_thumb) || !ctx.budget)
        return original(ctx, legacy, stop_pc, stop_thumb);
    const auto caller = std::uint32_t(read_bytes(ctx.registers, layout::lr, 4));
    const auto size = std::uint32_t(read_bytes(ctx.registers, layout::r2, 4));
    const auto sp = std::uint32_t(read_bytes(ctx.registers, layout::sp, 4));
    // This exact constructor call stores its common color/depth/target size
    // on the original stack. Other textures, bloom targets and callers pass
    // through unchanged. The original allocator still owns all GL objects.
    if (caller == PostEffectsColorTextureReturn && sp <= 0xfffffcecu && size == sp + 0x30cu) {
        as6_post_effects::Extent screen{};
        screen.width = std::uint32_t(load(ctx, Word(PostEffectsScreenExtent), 4));
        if (ctx.status != Returned) return ctx.status;
        screen.height = std::uint32_t(load(ctx, Word(PostEffectsScreenExtent + 4), 4));
        if (ctx.status != Returned) return ctx.status;
        // The dormant wide-viewport mode uses different viewport/UV math.
        // Its frozen flag is zero; do not apply ordinary-screen sizing to it.
        const bool specialWide = bool(load(ctx, Word(SpecialWidePostEffectsFlag), 1));
        if (ctx.status != Returned) return ctx.status;
        if (specialWide) return original(ctx, legacy, stop_pc, stop_thumb);
        as6_post_effects::Extent before{};
        before.width = std::uint32_t(load(ctx, Word(size), 4));
        if (ctx.status != Returned) return ctx.status;
        before.height = std::uint32_t(load(ctx, Word(size + 4), 4));
        if (ctx.status != Returned) return ctx.status;
        const auto after = as6_post_effects::targetExtent(screen, before);
        if (after.width != before.width || after.height != before.height) {
            // One bounded data-service write validates the complete extent
            // before modifying either component.
            store(ctx, Word(size), 8, Word(after.width) | (Word(after.height) << 32));
            if (ctx.status != Returned) return ctx.status;
        }
    }
    return original(ctx, legacy, stop_pc, stop_thumb);
}

bool IsStoreMenu(std::uint32_t menu) {
    // Original sMenuData -> sFlashConfig -> eFlashFiles tables map precisely
    // these eleven menu modes to AStore, Stars, Stars_PopOut and Cash movies.
    return menu >= 22u && menu <= 32u;
}

Status DisabledStore(Context &ctx, bool legacy, std::uint32_t stop_pc, bool stop_thumb) {
    if (!ctx.registers || ctx.register_size < layout::Size || ctx.isa_thumb ||
        (ctx.next_pc != CreateStoreInstance && ctx.next_pc != IsStoreEnabled &&
         ctx.next_pc != NativeGotoPopout && ctx.next_pc != BuyStore &&
         ctx.next_pc != SetCurrentMenu && ctx.next_pc != OpenAppStoreLink &&
         ctx.next_pc != EnterAppStore && ctx.next_pc != NativeBuyStarUnlock &&
         ctx.next_pc != NativeItemID && ctx.next_pc != BuyItem &&
         ctx.next_pc != ReturnStoreToForeground && ctx.next_pc != LaunchGameloftLive))
        return ctx.status = InvalidState;
    if (!legacy && ctx.next_pc == stop_pc && ctx.isa_thumb == stop_thumb)
        return ctx.status = Returned;
    if (!ctx.budget) return ctx.status = BudgetExhausted;
    --ctx.budget;
    if (ctx.next_pc == CreateStoreInstance) {
        // The original constructor sets this byte only after allocating the
        // StoreKit facade/transaction observer. Keep its disabled initial state
        // without making either object or calling a purchase API.
        store(ctx, Word(StoreEnabledByte), 1, Word(0));
        if (ctx.status != Returned) return ctx.status;
    } else if (ctx.next_pc == IsStoreEnabled) {
        write_bytes(ctx.registers, layout::r0, 4, Word(0));
    }
    // Disabled commerce and Gameloft Live entry points return without side effects. The
    // foreground callback must not dereference the unconstructed Store facade.
    const auto return_address = std::uint32_t(read_bytes(ctx.registers, layout::lr, 4));
    const bool thumb = bool(return_address & 1u);
    const auto next_pc = return_address & ~1u;
    if (next_pc & (thumb ? 1u : 3u)) return ctx.status = InvalidState;
    write_bytes(ctx.registers, layout::TB, 1, Word(thumb));
    ctx.isa_thumb = thumb;
    ctx.next_pc = next_pc;
    write_bytes(ctx.registers, layout::pc, 4, Word(next_pc));
    ctx.status = Returned;
    return legacy ? Returned : Dispatch;
}

Status StoreMenuNavigation(Context &ctx, bool legacy, std::uint32_t stop_pc, bool stop_thumb) {
    if (!ctx.registers || ctx.register_size < layout::Size || ctx.isa_thumb ||
        ctx.next_pc != SetCurrentMenu) return ctx.status = InvalidState;
    const auto menu = std::uint32_t(read_bytes(ctx.registers, layout::r0, 4));
    if (IsStoreMenu(menu)) return DisabledStore(ctx, legacy, stop_pc, stop_thumb);
    return AS6NativeProgramWithStartupRecovery()->lookup(SetCurrentMenu, false)
        (ctx, legacy, stop_pc, stop_thumb);
}

NativeFunction Lookup(std::uint32_t pc, bool thumb) {
    if (as6_original_ui::isBoundary(pc,thumb)) return as6_original_ui::boundary;
    if (!thumb && pc == FlashTargetChoice) return IndependentFlashRenderTarget;
    if (!thumb && pc == GenericTexture) return SquareFlashTexture;
    if (!thumb && pc >= RatioUVStart && pc <= RatioUVHeight && !(pc & 3u)) return SquarePostEffectsUV;
    if (!thumb && pc == CreateTexture) return PostEffectsTextureSize;
    if (!thumb && pc == SetPostEffectsScreenRatio) return FixedPostEffectsScreenRatio;
    if (!thumb && pc == SetCurrentMenu) return StoreMenuNavigation;
    if (!thumb && (pc == CreateStoreInstance || pc == IsStoreEnabled ||
                   pc == NativeGotoPopout || pc == BuyStore || pc == OpenAppStoreLink ||
                   pc == EnterAppStore || pc == NativeBuyStarUnlock ||
                   pc == NativeItemID || pc == BuyItem ||
                   pc == ReturnStoreToForeground || pc == LaunchGameloftLive)) return DisabledStore;
    if (const auto music=as6_music_boundary::lookup(pc,thumb)) return music;
    return AS6NativeProgramWithStartupRecovery()->lookup(pc, thumb);
}
bool Validate() {
    const auto *base = AS6NativeProgramWithStartupRecovery();
    return base && base->valid() && base->register_size() == layout::Size &&
        base->lookup(LaunchGameloftLive, false) &&
        base->lookup(CreateStoreInstance, false) && base->lookup(IsStoreEnabled, false) &&
        base->lookup(NativeGotoPopout, false) && base->lookup(BuyStore, false) &&
        base->lookup(SetCurrentMenu, false) && base->lookup(OpenAppStoreLink, false) &&
        base->lookup(EnterAppStore, false) && base->lookup(NativeBuyStarUnlock, false) &&
        base->lookup(NativeItemID, false) && base->lookup(BuyItem, false) &&
        base->lookup(ReturnStoreToForeground, false) && base->lookup(CreateTexture, false) &&
        base->lookup(SetPostEffectsScreenRatio, false) && base->lookup(FlashTargetChoice, false) &&
        base->lookup(GenericTexture, false) && base->lookup(RatioUVStart, false) &&
        base->lookup(RatioUVWidth, false) && base->lookup(RatioUVHeight, false);
}
const NativeModule Modules[] = {{0, 0x1ffffffffULL, Lookup}};
const NativeProgram Program(Modules, 1, layout::Size, layout::pc);
} // namespace

extern "C" const as6aot::NativeProgram *AS6NativeProgramWithGamePolicy() {
    static const bool valid = Validate();
    return valid && Program.valid() ? &Program : nullptr;
}
