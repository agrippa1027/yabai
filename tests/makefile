.PHONY: clean build run all

all: clean build run

clean:
	rm -rf ./bin

build:
	mkdir -p ./bin
	clang ./src/tests.m -o ./bin/tests -DTESTS -DPROFILE=1 -F/System/Library/PrivateFrameworks -framework Carbon -framework Cocoa -framework CoreServices -framework CoreVideo -framework SkyLight

run:
	./bin/tests

# Isolated CoreFoundation ownership test; does not access the desktop.
.PHONY: memory
memory:
	mkdir -p ./bin
	clang ./src/ax_window_probe_test.m -o ./bin/ax-window-probe -std=c11 -Wall -Wextra -Wno-unused-parameter -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer -framework ApplicationServices
	./bin/ax-window-probe
