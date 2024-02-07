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
- No allocation.
