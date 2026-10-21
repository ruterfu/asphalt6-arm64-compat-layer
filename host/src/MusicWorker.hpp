#pragma once
#include "MusicController.hpp"
#include <condition_variable>
#include <deque>
#include <exception>
#include <future>
#include <memory>
#include <mutex>
#include <thread>

namespace as6::audio {
// New platform architecture: UI/game callers send value commands; one worker
// exclusively owns both controller and backend. Audio output/decoding remains
// the native backend's responsibility, independent of graphics execution.
class MusicWorker {
public:
    MusicWorker(std::unique_ptr<MusicBackend> backend, MusicState initial);
    ~MusicWorker();
    MusicWorker(const MusicWorker &)=delete;
    MusicWorker &operator=(const MusicWorker &)=delete;
    bool post(MusicCommand command);
    // A queued fence for callers outside the audio worker: observes all commands
    // accepted before this call. Owner-thread requests return an error future.
    std::future<MusicState> stateAfterPendingCommands();
    // Drains accepted commands and destroys the backend on its owner thread.
    // Invoke from the service owner, never from a backend callback.
    void close();
    void rethrowFailure() const;
private:
    using Message=std::variant<MusicCommand,std::promise<MusicState>>;
    mutable std::mutex mutex_;
    std::condition_variable changed_;
    std::deque<Message> messages_;
    bool closing_=false;
    std::exception_ptr failure_;
    std::mutex joinMutex_;
    std::thread worker_;
    void run(std::unique_ptr<MusicBackend> backend, MusicState initial) noexcept;
};
}
