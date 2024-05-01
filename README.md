# ld.meow.so

Toy ELF dynliker & interp

TODO:
- [ ] Map additional library
- [ ] VDSO
- [ ] Versioning
- [ ] TLS
- [ ] Other weird stuff
- [ ] Self-relocation

Goals:
- No global state, thus avoiding stage 1 of dyn linker.
  - Failed, in particular allocator requires global vtable
- No allocation.

Assumptions:
- Reasonably new Linux Kernel
- x86-64 platform, though add support for other 64-bit architectures should be trivial.
