# ld.meow.so

Toy ELF dynliker & interp

Require Zig 0.12.0

TODO:
- [x] Map additional library
- [x] vDSO
- [x] Init
  - Finalize requires libc cooperation, so we skip those.
- [ ] dlopen
- [ ] TLS
  - Looking for a free-standing threading library
- [x] Self-relocation

Assumptions:
- Reasonably new Linux Kernel
- x86-64 platform, though add support for other 64-bit architectures should be trivial.

## Open source dependencies

- Zig stdlib
- [Nanoprintf](https://github.com/charlesnicholson/nanoprintf) for building test elfs
