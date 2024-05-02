#define NANOPRINTF_IMPLEMENTATION
#include "nanoprintf.h"

size_t syscall(size_t op, size_t arg1, size_t arg2, size_t arg3) {
  register size_t rax __asm__ ("rax") = op;
  register size_t rdi __asm__ ("rdi") = arg1;
  register size_t rsi __asm__ ("rsi") = arg2;
  register size_t rdx __asm__ ("rdx") = arg3;

  __asm__ __volatile__ (
      "syscall"
      : "+r" (rax)
      : "r" (rdi), "r" (rsi), "r" (rdx)
      : "rcx", "r11", "memory"
      );
  return rax;
}

size_t write(int fd, char *ptr, size_t len) {
  return syscall(1, fd, ptr, len);
}

void exit(size_t ret) {
  syscall(60, ret, 0, 0);
  __builtin_unreachable();
}

void print(const char *string) {
  int len = 0;
  for(; string[len]; ++len) ;
  write(1, string, len);
}

int __cxa_atexit ( void (*f)(void *), void *p, void *d ) {
  print("At exit called");
}
