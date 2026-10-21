#pragma once
#include <cmath>
#include <cstdint>

namespace as6motion {
struct Sample { double x=0,y=0,z=0,timestamp=0; uint64_t epoch=0; uintptr_t owner=0; };
// Caller serializes access. Device axes and G units pass through unchanged.
class InputState {
    uintptr_t owner_=0;
    uint64_t epoch_=1;
    bool delegate_=false, foreground_=false, queued_=false, valid_=false;
    double interval_=1.0/60.0, delivered_=-1;
    Sample latest_{};
    void invalidate() { ++epoch_; queued_=valid_=false; delivered_=-1; }
public:
    uint64_t epoch() const { return epoch_; }
    uintptr_t owner() const { return owner_; }
    double interval() const { return interval_; }
    bool running() const { return owner_ && delegate_ && foreground_; }
    void attach(uintptr_t owner) { if(owner_!=owner){owner_=owner;delegate_=false;invalidate();} }
    void delegateChanged(bool present) { delegate_=present; invalidate(); }
    void foreground(bool active) { if(foreground_!=active){foreground_=active;invalidate();} }
    bool interval(double value) {
        if(!std::isfinite(value)||value<=0)return false;
        if(interval_!=value){interval_=value;invalidate();}
        return true;
    }
    bool store(uint64_t epoch,double x,double y,double z,double timestamp) {
        if(epoch!=epoch_||!running()||!std::isfinite(x)||!std::isfinite(y)||!std::isfinite(z)||
           !std::isfinite(timestamp)||timestamp<0||timestamp<=delivered_||
           (valid_&&timestamp<=latest_.timestamp))return false;
        latest_={x,y,z,timestamp,epoch_,owner_};valid_=true;
        if(queued_)return false;
        queued_=true;return true;
    }
    bool take(uint64_t epoch,Sample &sample) {
        if(epoch!=epoch_)return false; // An old drain cannot clear a new queue.
        queued_=false;
        if(!running()||!valid_)return false;
        sample=latest_;valid_=false;delivered_=sample.timestamp;return true;
    }
    bool current(const Sample &sample) const {
        return running()&&sample.epoch==epoch_&&sample.owner==owner_;
    }
};
}
