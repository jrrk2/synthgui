#pragma once
#include <time.h>
static inline void busy_wait_us(unsigned us) { struct timespec t = {us / 1000000, (us % 1000000) * 1000L}; nanosleep(&t, 0); }
static inline void busy_wait(unsigned ms) { busy_wait_us(ms * 1000); }
