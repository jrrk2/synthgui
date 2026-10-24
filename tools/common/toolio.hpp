// How the built-in tools (tools/) talk to the outside, so the same code runs as `synthgui --tool NAME` on a terminal and
// inside the GUI, in a worker thread, with its output going to the step's log:
//   toolio::out / err   printf for stdout / stderr, to the calling thread's sink if one is set
//   toolio::write       the same for raw bytes
//   toolio::Exit        thrown where a stand-alone program would call exit(): the caller turns it into the step's result
#pragma once
#include <cstdarg>
#include <cstdio>
#include <string>

namespace toolio {

struct Sink {
    virtual ~Sink() {}
    virtual void write(bool is_err, const char* data, size_t n) = 0;
};
inline thread_local Sink* sink = nullptr;                      // none: the process's own stdout / stderr

struct Exit { int code; };

inline void write(bool is_err, const char* d, size_t n) {
    if (sink) sink->write(is_err, d, n);
    else fwrite(d, 1, n, is_err ? stderr : stdout);
}

inline void vprint(bool is_err, const char* fmt, va_list ap) {
    char buf[1024];
    va_list again;
    va_copy(again, ap);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    if (n >= 0) {
        if ((size_t)n < sizeof buf) write(is_err, buf, (size_t)n);
        else {
            std::string big((size_t)n + 1, '\0');
            vsnprintf(&big[0], big.size(), fmt, again);
            write(is_err, big.data(), (size_t)n);
        }
    }
    va_end(again);
}
__attribute__((format(printf, 1, 2))) inline void out(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt); vprint(false, fmt, ap); va_end(ap);
}
__attribute__((format(printf, 1, 2))) inline void err(const char* fmt, ...) {
    va_list ap; va_start(ap, fmt); vprint(true, fmt, ap); va_end(ap);
}

}  // namespace toolio
