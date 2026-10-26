#include "ak_internal.hpp"

#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <thread>
#include <utility>

namespace ak {
namespace {

class EventSink {
 public:
  ~EventSink() { stop(); }

  void start() {
    std::lock_guard<std::mutex> lock(mtx_);
    if (running_) {
      return;
    }
    running_ = true;
    stopping_ = false;
    thread_ = std::thread([this] { run(); });
  }

  void stop() {
    log(LogLevel::info, "event sink stop begin");
    std::thread worker;
    {
      std::lock_guard<std::mutex> lock(mtx_);
      if (!running_) {
        log(LogLevel::info, "event sink stop: not running");
        return;
      }
      stopping_ = true;
      callback_ = nullptr;
      user_ = nullptr;
      queue_.clear();
      cv_.notify_all();
      worker = std::move(thread_);
    }
    if (worker.joinable()) {
      worker.join();
    }
    std::lock_guard<std::mutex> lock(mtx_);
    running_ = false;
    stopping_ = false;
    log(LogLevel::info, "event sink stop done");
  }

  int32_t set_callback(ak_event_cb cb, void* user) {
    std::lock_guard<std::mutex> lock(mtx_);
    callback_ = cb;
    user_ = user;
    return AK_OK;
  }

  void post(const std::string& json) {
    std::lock_guard<std::mutex> lock(mtx_);
    if (!running_ || stopping_) {
      return;
    }
    queue_.push_back(json);
    cv_.notify_one();
  }

 private:
  void run() {
    for (;;) {
      std::string json;
      ak_event_cb cb = nullptr;
      void* user = nullptr;
      {
        std::unique_lock<std::mutex> lock(mtx_);
        cv_.wait(lock, [this] { return stopping_ || !queue_.empty(); });
        if (stopping_) {
          return;
        }
        json = std::move(queue_.front());
        queue_.pop_front();
        cb = callback_;
        user = user_;
      }
      char* payload = static_cast<char*>(std::malloc(json.size() + 1));
      if (!payload) {
        continue;
      }
      std::memcpy(payload, json.data(), json.size());
      payload[json.size()] = '\0';
      if (cb) {
        cb(payload, user);
      } else {
        std::free(payload);
      }
    }
  }

  std::mutex mtx_;
  std::condition_variable cv_;
  std::deque<std::string> queue_;
  std::thread thread_;
  ak_event_cb callback_ = nullptr;
  void* user_ = nullptr;
  bool running_ = false;
  bool stopping_ = false;
};

EventSink& sink() {
  static EventSink instance;
  return instance;
}

}  // namespace

void event_start() { sink().start(); }

void event_stop() { sink().stop(); }

void event_post(const std::string& json) { sink().post(json); }

int32_t event_set_callback(ak_event_cb cb, void* user) {
  return sink().set_callback(cb, user);
}

}  // namespace ak

extern "C" void ak_event_free(const char* event_json) {
  std::free(const_cast<char*>(event_json));
}
