#import "HLE.h"

#import <os/lock.h>
#import <atomic>
#import <string.h>
#import <string>
#import <unordered_map>

#import "GuestVM.h"

static std::unordered_map<std::string, HLEImpl> g_impls;
// The current import's name. Every value set is a string that outlives its
// use (the static bridge table, or a caller's saved value it restores).
static thread_local const char *g_currentSymbol = "";
static std::unordered_map<std::string, NSUInteger> g_needed;
static os_unfair_lock g_lock = OS_UNFAIR_LOCK_INIT;
static std::atomic<uint64_t> g_generation{0};

void HLESetCurrentSymbol(const char *symbol) {
    g_currentSymbol = symbol ? symbol : "";
}
const char *HLECurrentSymbol(void) { return g_currentSymbol; }

void HLERegister(const char *symbol, HLEImpl impl) {
    os_unfair_lock_lock(&g_lock);
    g_impls[symbol] = impl;
    g_generation.fetch_add(1, std::memory_order_release);
    os_unfair_lock_unlock(&g_lock);
}

uint64_t HLEGeneration(void) { return g_generation.load(std::memory_order_acquire); }

HLEImpl HLELookup(const char *symbol) {
    os_unfair_lock_lock(&g_lock);
    auto it = g_impls.find(symbol);
    HLEImpl impl = (it == g_impls.end()) ? nullptr : it->second;
    os_unfair_lock_unlock(&g_lock);
    return impl;
}

void HLERecordNeeded(NSString *symbol) {
    if (symbol.length == 0) return;
    os_unfair_lock_lock(&g_lock);
    g_needed[symbol.UTF8String] += 1;
    os_unfair_lock_unlock(&g_lock);
}

NSUInteger HLENeededCount(void) {
    os_unfair_lock_lock(&g_lock);
    NSUInteger n = g_needed.size();
    os_unfair_lock_unlock(&g_lock);
    return n;
}

NSUInteger HLEImplementedCount(void) {
    os_unfair_lock_lock(&g_lock);
    NSUInteger n = 0;
    for (const auto &kv : g_needed) {
        if (g_impls.count(kv.first)) ++n;
    }
    os_unfair_lock_unlock(&g_lock);
    return n;
}

NSArray<NSString *> *HLEMissingSymbols(void) {
    os_unfair_lock_lock(&g_lock);
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (const auto &kv : g_needed) {
        if (!g_impls.count(kv.first)) {
            [out addObject:[NSString stringWithUTF8String:kv.first.c_str()]];
        }
    }
    os_unfair_lock_unlock(&g_lock);
    return out;
}
