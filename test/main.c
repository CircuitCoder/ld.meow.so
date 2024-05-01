#define size_t long long

size_t write(int fd, char *ptr, size_t len);
void exit(size_t ret);

const char hw[] = "Hello, world!\n";
const size_t hw_len = sizeof(hw) - 1;

int _start() {
  write(1, hw, hw_len);
  exit(0);
}
