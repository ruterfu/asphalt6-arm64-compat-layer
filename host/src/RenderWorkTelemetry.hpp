#pragma once
#include <atomic>
#include <chrono>
#include <cstdint>
namespace as6_render_plan {
// Cumulative diagnostic counters only. Readers may see different concurrent
// completion instants; snapshots neither wait on workers nor access GuestVM/GL.
class RenderWorkTelemetry {
    std::atomic<std::uint64_t> scans_{0},bytes_{0},parallel_{0},workerTasks_{0},
        maximumBytes_{0},maximumWorkers_{0},largeWallNs_{0},
        cacheLookups_{0},cacheHits_{0},cacheSavedBytes_{0};
    static void maximum(std::atomic<std::uint64_t> &value,std::uint64_t n) noexcept {
        auto old=value.load(std::memory_order_relaxed);
        while(old<n&&!value.compare_exchange_weak(old,n,std::memory_order_relaxed)){}
    }
public:
    struct Snapshot {std::uint64_t scans,bytes,parallel,workerTasks,maximumBytes,maximumWorkers,largeWallNs,cacheLookups,cacheHits,cacheSavedBytes;};
    void record(std::uint64_t bytes,unsigned workers,std::uint64_t largeWallNs) noexcept {
        scans_.fetch_add(1,std::memory_order_relaxed);bytes_.fetch_add(bytes,std::memory_order_relaxed);
        maximum(maximumBytes_,bytes);maximum(maximumWorkers_,workers);
        if(workers){parallel_.fetch_add(1,std::memory_order_relaxed);workerTasks_.fetch_add(workers,std::memory_order_relaxed);}
        if(largeWallNs)largeWallNs_.fetch_add(largeWallNs,std::memory_order_relaxed);
    }
    void recordIndexCacheQuery(std::uint64_t bytes,bool hit) noexcept {
        cacheLookups_.fetch_add(1,std::memory_order_relaxed);
        if(hit){cacheHits_.fetch_add(1,std::memory_order_relaxed);cacheSavedBytes_.fetch_add(bytes,std::memory_order_relaxed);}
    }
    Snapshot snapshot() const noexcept {
        return {scans_.load(std::memory_order_relaxed),bytes_.load(std::memory_order_relaxed),
            parallel_.load(std::memory_order_relaxed),workerTasks_.load(std::memory_order_relaxed),
            maximumBytes_.load(std::memory_order_relaxed),maximumWorkers_.load(std::memory_order_relaxed),
            largeWallNs_.load(std::memory_order_relaxed),cacheLookups_.load(std::memory_order_relaxed),
            cacheHits_.load(std::memory_order_relaxed),cacheSavedBytes_.load(std::memory_order_relaxed)};
    }
};
inline RenderWorkTelemetry renderWorkTelemetry;
} // namespace as6_render_plan
