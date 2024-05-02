#define size_t long long

extern "C" {
  size_t write(int fd, const char *ptr, size_t len);
  void exit(size_t ret);

  // void __dso_handle(); // Dynamically linked by linker
}

const char init[] = "Init\n";
const size_t init_len = sizeof(init) - 1;
const char deinit[] = "Deinit\n";
const size_t deinit_len = sizeof(deinit) - 1;

struct Foo {
  Foo() {
    write(1, init, init_len);
  }

  ~Foo() {
    write(1, deinit, deinit_len);
  }
};

Foo foo;

extern "C" {
  int _start() {
    exit(0);
  }

  struct {} handle;

  void* __dso_handle = &handle;
}
