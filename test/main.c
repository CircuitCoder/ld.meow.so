#include <time.h>
#include "nanoprintf.h"

void print(const char *string);
void exit(size_t ret);
extern int clock_gettime(clockid_t clk_id, struct timespec *tp) __attribute__((weak_import, weak));

const char hw[] = "Hello, world!\n";

int _start() {
  print(hw);
  struct timespec time;
  clock_gettime(CLOCK_REALTIME, &time);
  const char format_buffer[100];

  int secs = time.tv_sec % 60;
  int mins = (time.tv_sec / 60) % 60;
  int hrs = (time.tv_sec / 60 / 60) % 24;

  npf_snprintf(format_buffer, 100, "%d:%d:%dZ\n", hrs, mins, secs);
  print(format_buffer);
  exit(0);
}
