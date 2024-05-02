all: main init

CCFLAGS=-fno-stack-protector -nostdlib -fPIE -fPIC -g -O0
CXXFLAGS=${CCFLAGS} -fno-exceptions -fno-rtti

lib.so: lib.c
	gcc ${CCFLAGS} -shared -o lib.so ./lib.c

main: main.c lib.so
	gcc ${CCFLAGS} -o main ./lib.so ./main.c 
	patchelf --set-interpreter $$(readlink -f ../zig-out/bin/ld.meow.so) ./main

init: init.cpp lib.so
	g++ ${CXXFLAGS} -o init ./lib.so ./init.cpp
	patchelf --set-interpreter $$(readlink -f ../zig-out/bin/ld.meow.so) ./init

clean:
	rm -f lib.so main init

.PHONY: clean
