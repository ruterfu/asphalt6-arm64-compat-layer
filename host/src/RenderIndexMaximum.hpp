#pragma once

#include <algorithm>
#include <array>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

namespace as6_render_plan {

// Read-only host spans only. The caller keeps the bytes immutable until this
// operation returns; no worker is allowed to read GuestVM or issue GL calls.
class IndexMaximum {
    static constexpr unsigned MaximumWorkers=3;
    // Mac ARM64 measurements: worker wake/join cost dominates small scans.
    // Require 4 MiB of read-only work before dispatch; phone tuning is separate.
    static constexpr std::size_t ParallelThresholdBytes=4u<<20;
    std::mutex submissions_,mutex_;
    std::condition_variable work_,complete_;
    std::vector<std::thread> workers_;
    std::array<std::uint32_t,MaximumWorkers> partial_{};
    const std::uint8_t *data_=nullptr;
    std::size_t count_=0;
    unsigned width_=0,remaining_=0;
    std::uint64_t generation_=0;
    bool stopping_=false;

    template<class T>
    static std::uint32_t scan(const std::uint8_t *bytes,std::size_t count) noexcept {
        T value=0;
        for(std::size_t i=0;i<count;++i){
            T item;
            // The original renderer permits unaligned index buffers.
            std::memcpy(&item,bytes+i*sizeof(T),sizeof(T));
            value=std::max(value,item);
        }
        return value;
    }
    static std::uint32_t scan(const std::uint8_t *bytes,std::size_t count,unsigned width) noexcept {
        if(width==1)return scan<std::uint8_t>(bytes,count);
        if(width==2)return scan<std::uint16_t>(bytes,count);
        return scan<std::uint32_t>(bytes,count);
    }
    void worker(unsigned index) noexcept {
        std::uint64_t seen=0;
        std::unique_lock<std::mutex> lock(mutex_);
        for(;;){
            work_.wait(lock,[&]{return stopping_||generation_!=seen;});
            if(stopping_)return;
            seen=generation_;
            const unsigned parts=unsigned(workers_.size())+1;
            const std::size_t chunk=count_/parts;
            const std::size_t begin=chunk*index;
            const auto *bytes=data_+begin*width_;
            const unsigned width=width_;
            lock.unlock();
            const auto value=scan(bytes,chunk,width);
            lock.lock();
            partial_[index]=value;
            if(!--remaining_)complete_.notify_one();
        }
    }
    void start() {
        if(!workers_.empty())return;
        const unsigned hardware=std::thread::hardware_concurrency();
        const unsigned wanted=hardware>1?std::min(MaximumWorkers,hardware-1):0;
        workers_.reserve(wanted);
        // Workers cannot observe a partially constructed vector or a job until
        // this lock is released. A thread-creation failure leaves a smaller pool.
        std::lock_guard<std::mutex> lock(mutex_);
        for(unsigned i=0;i<wanted;++i){
            try {workers_.emplace_back([this,i]{worker(i);});}
            catch(...){break;}
        }
    }
public:
    struct Result {bool valid=false;std::uint32_t maximum=0;unsigned workers=0;};
    IndexMaximum()=default;
    IndexMaximum(const IndexMaximum &)=delete;
    IndexMaximum &operator=(const IndexMaximum &)=delete;
    ~IndexMaximum(){
        {std::lock_guard<std::mutex> lock(mutex_);stopping_=true;}
        work_.notify_all();
        for(auto &thread:workers_)thread.join();
    }
    static Result sequential(const void *data,std::size_t bytes,std::size_t count,unsigned width) noexcept {
        if((width!=1&&width!=2&&width!=4)||count>bytes/width||(!data&&count))return {};
        return {true,count?scan(static_cast<const std::uint8_t *>(data),count,width):0,0};
    }
    Result maximum(const void *data,std::size_t bytes,std::size_t count,unsigned width) {
        if((width!=1&&width!=2&&width!=4)||count>bytes/width||(!data&&count))return {};
        if(count*width<ParallelThresholdBytes)return sequential(data,bytes,count,width);
        // At most one immutable snapshot is in flight; the renderer already
        // serializes GL submissions. There is no unbounded work queue.
        std::lock_guard<std::mutex> submission(submissions_);
        try {start();}catch(...){return sequential(data,bytes,count,width);}
        if(workers_.empty())return sequential(data,bytes,count,width);
        const unsigned parts=unsigned(workers_.size())+1;
        const std::size_t chunk=count/parts;
        const std::size_t begin=chunk*(parts-1);
        {
            std::lock_guard<std::mutex> lock(mutex_);
            data_=static_cast<const std::uint8_t *>(data);count_=count;width_=width;
            remaining_=unsigned(workers_.size());++generation_;
        }
        work_.notify_all();
        std::uint32_t value=scan(static_cast<const std::uint8_t *>(data)+begin*width,count-begin,width);
        std::unique_lock<std::mutex> lock(mutex_);
        complete_.wait(lock,[&]{return remaining_==0;});
        for(unsigned i=0;i<workers_.size();++i)value=std::max(value,partial_[i]);
        data_=nullptr;count_=0;
        return {true,value,unsigned(workers_.size())};
    }
};

} // namespace as6_render_plan
