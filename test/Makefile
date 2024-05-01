all: main

lib.so: lib.c
	gcc -nostdlib -shared -fno-plt -o lib.so ./lib.c

main: main.c lib.so
	gcc -nostdlib -fPIE -fno-plt -o main ./lib.so ./main.c 

clean:
	rm -f lib.so main

.PHONY: clean
