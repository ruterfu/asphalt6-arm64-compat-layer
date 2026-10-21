#pragma once
#include "VertexTransform.hpp"
#include <algorithm>
#include <array>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <limits>
#include <thread>
#include <vector>

namespace as6::geometry::vertex {
// Pure host spans only. The caller keeps source immutable and retains both
// buffers until return. Workers never borrow GuestVM, Core, GL or registers.
class VertexJobs {
    static constexpr unsigned MaximumWorkers=3;
    struct Job {SourceSpan source;ScratchSpan scratch;std::uint16_t count=0;Affine3x4 matrix;LoopInput input;};
    std::uint32_t threshold_;
    unsigned limit_;
    std::mutex submissions_,mutex_;
    std::condition_variable work_,complete_;
    std::vector<std::thread> workers_;
    std::vector<std::uint8_t> staging_;
    std::array<Job,MaximumWorkers+1> jobs_{};
    std::array<Result,MaximumWorkers> results_{};
    std::uint64_t generation_=0;
    unsigned remaining_=0;
    bool stopping_=false;
    static Result execute(const Job &job) noexcept {
        return vertex::transform(job.source,job.scratch,job.count,job.count,job.matrix,job.input);
    }
    void worker(unsigned index) noexcept {
        std::uint64_t seen=0;std::unique_lock<std::mutex> lock(mutex_);
        for(;;){
            work_.wait(lock,[&]{return stopping_||seen!=generation_;});if(stopping_)return;
            seen=generation_;const auto job=jobs_[index];lock.unlock();const auto result=execute(job);lock.lock();
            results_[index]=result;if(!--remaining_)complete_.notify_one();
        }
    }
    void start(){
        if(!workers_.empty()||!limit_)return;
        const auto hardware=std::thread::hardware_concurrency();const auto wanted=hardware>1?std::min(limit_,hardware-1):0;
        workers_.reserve(wanted);std::lock_guard<std::mutex> lock(mutex_);
        for(unsigned i=0;i<wanted;++i){try{workers_.emplace_back([this,i]{worker(i);});}catch(...){break;}}
    }
    bool eligible(const SourceSpan &source,const ScratchSpan &scratch,std::uint16_t count,
                  std::uint16_t iterations,const LoopInput &input) const noexcept {
        if(iterations<threshold_||iterations>count||source.stride<12||scratch.stride!=12||
           !source.bytes||!scratch.bytes||std::size_t(iterations)>std::numeric_limits<std::size_t>::max()/source.stride||
           scratch.size<std::size_t(iterations)*12||
           (input.fpscr&(0x9f00u|(7u<<16)|(3u<<20))))return false;
        for(auto bits:input.oddS)if(bits)return false;
        const auto a=reinterpret_cast<std::uintptr_t>(source.bytes),b=reinterpret_cast<std::uintptr_t>(scratch.bytes),n=std::size_t(iterations)*12;
        const auto sourceExtent=std::size_t(iterations-1)*source.stride+12;
        return sourceExtent<=source.size&&sourceExtent<=UINTPTR_MAX-a&&n<=UINTPTR_MAX-b&&!(a<b+n&&b<a+sourceExtent);
    }
public:
    static constexpr unsigned MinimumParallelVertices=8192,MaximumParallelVertices=16384;
    struct Output {Result result;unsigned workers=0;bool parallelUsed=false,replayed=false;};
    // Threshold is a measurable policy, independent of correctness. A worker
    // limit of zero retains exactly the ordinary single-thread transform path.
    explicit VertexJobs(std::uint32_t threshold=MinimumParallelVertices,unsigned workerLimit=3)
        :threshold_(std::max(threshold,4u)),limit_(std::min(workerLimit,MaximumWorkers)){}
    VertexJobs(const VertexJobs&)=delete;VertexJobs&operator=(const VertexJobs&)=delete;
    ~VertexJobs(){
        {std::lock_guard<std::mutex> lock(mutex_);stopping_=true;}work_.notify_all();
        for(auto &thread:workers_)thread.join();
    }
    Output transform(const SourceSpan &source,const ScratchSpan &scratch,std::uint16_t count,
                     std::uint16_t iterations,const Affine3x4 &matrix,const LoopInput &input){
        const auto serial=[&]{return vertex::transform(source,scratch,count,iterations,matrix,input);};
        if(!eligible(source,scratch,count,iterations,input)||!limit_)return {serial()};
        std::lock_guard<std::mutex> submission(submissions_);
        try{staging_.resize(std::size_t(iterations)*12);start();}catch(...){return {serial()};}
        if(workers_.empty())return {serial()};
        const auto background=unsigned(workers_.size()),parts=background+1,chunk=unsigned(iterations)/parts;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            for(unsigned i=0;i<parts;++i){const auto begin=chunk*i,n=i+1==parts?iterations-begin:chunk;
                jobs_[i]={{source.bytes+std::size_t(begin)*source.stride,std::size_t(n-1)*source.stride+12,source.stride},
                    {staging_.data()+begin*12,std::size_t(n)*12,12},std::uint16_t(n),matrix,input};}
            remaining_=background;++generation_;
        }
        work_.notify_all();auto result=execute(jobs_[background]);
        {
            std::unique_lock<std::mutex> lock(mutex_);complete_.wait(lock,[&]{return !remaining_;});
            bool complete=result.status==Status::Complete;
            for(unsigned i=0;i<background;++i){complete=complete&&results_[i].status==Status::Complete;
                result.fpscr|=results_[i].fpscr;result.vectorizedVertices+=results_[i].vectorizedVertices;}
            if(!complete){
                // No worker ever wrote caller output. A whole serial replay
                // preserves the exact partial-output/failure behavior as well.
                return {serial(),background,false,true};
            }
        }
        std::memcpy(scratch.bytes,staging_.data(),std::size_t(iterations)*12);
        result.written=iterations;result.remaining=count-iterations;result.r3=result.remaining;
        result.sourceAdvance=std::size_t(iterations)*source.stride;result.destinationAdvance=std::size_t(iterations)*12;
        result.nzcv=result.remaining?0x20000000u:0x60000000u;
        return {result,background,true,false};
    }
};
} // namespace as6::geometry::vertex
