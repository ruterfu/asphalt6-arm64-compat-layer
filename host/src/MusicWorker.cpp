#include "MusicWorker.hpp"
#include <stdexcept>

namespace as6::audio {
namespace {
thread_local const MusicWorker *currentWorker=nullptr;
struct WorkerOwner {
    const MusicWorker *previous;
    explicit WorkerOwner(const MusicWorker *owner):previous(currentWorker) { currentWorker=owner; }
    ~WorkerOwner() { currentWorker=previous; }
};
}
MusicWorker::MusicWorker(std::unique_ptr<MusicBackend> backend, MusicState initial) {
    if (!backend) throw std::invalid_argument("MusicWorker requires an audio backend");
    worker_=std::thread([this,backend=std::move(backend),initial]() mutable {
        WorkerOwner owner(this);
        run(std::move(backend),initial);
    });
}
MusicWorker::~MusicWorker() { close(); }

bool MusicWorker::post(MusicCommand command) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (closing_) return false;
        messages_.emplace_back(std::move(command));
    }
    changed_.notify_one();
    return true;
}

std::future<MusicState> MusicWorker::stateAfterPendingCommands() {
    std::promise<MusicState> reply;
    auto result=reply.get_future();
    if (currentWorker==this) {
        reply.set_exception(std::make_exception_ptr(
            std::logic_error("MusicWorker cannot fence itself")));
        return result;
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (closing_) {
            reply.set_exception(failure_?failure_:
                std::make_exception_ptr(std::runtime_error("MusicWorker is closed")));
            return result;
        }
        messages_.emplace_back(std::move(reply));
    }
    changed_.notify_one();
    return result;
}

void MusicWorker::close() {
    // Check before the join mutex: an external closer may already hold it
    // while waiting for this backend callback to finish.
    if (currentWorker==this) throw std::logic_error("MusicWorker cannot close itself");
    std::lock_guard<std::mutex> join(joinMutex_);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        closing_=true;
    }
    changed_.notify_one();
    if (worker_.joinable()) worker_.join();
}

void MusicWorker::rethrowFailure() const {
    std::exception_ptr failure;
    { std::lock_guard<std::mutex> lock(mutex_); failure=failure_; }
    if (failure) std::rethrow_exception(failure);
}

void MusicWorker::run(std::unique_ptr<MusicBackend> backend, MusicState initial) noexcept {
    MusicController controller(*backend,initial);
    Message current;
    try {
        for (;;) {
            {
                std::unique_lock<std::mutex> lock(mutex_);
                changed_.wait(lock,[this]{return closing_ || !messages_.empty();});
                if (messages_.empty()) break;
                current=std::move(messages_.front());
                messages_.pop_front();
            }
            if (auto *command=std::get_if<MusicCommand>(&current)) controller.apply(*command);
            else std::get<std::promise<MusicState>>(current).set_value(controller.state());
        }
    } catch (...) {
        const auto failure=std::current_exception();
        if (auto *reply=std::get_if<std::promise<MusicState>>(&current)) {
            try { reply->set_exception(failure); } catch (...) {}
        }
        std::deque<Message> pending;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            closing_=true; failure_=failure;
            pending.swap(messages_);
        }
        for (auto &message:pending)
            if (auto *reply=std::get_if<std::promise<MusicState>>(&message)) {
                try { reply->set_exception(failure); } catch (...) {}
            }
    }
}
}
