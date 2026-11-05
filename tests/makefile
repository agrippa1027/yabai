.PHONY: clean build run all resize asan

BUILD_PATH ?= ./bin
TEST_FLAGS ?=
SANITIZER_FLAGS = -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer

all: clean build run resize

clean:
	rm -rf $(BUILD_PATH)

build:
	mkdir -p $(BUILD_PATH)
	clang ./src/tests.m -o $(BUILD_PATH)/tests -DTESTS -DPROFILE=1 $(TEST_FLAGS) -F/System/Library/PrivateFrameworks -framework Carbon -framework Cocoa -framework CoreServices -framework CoreVideo -framework SkyLight

run:
	$(BUILD_PATH)/tests

# Isolated CoreFoundation ownership test; does not access the desktop.
.PHONY: memory
memory:
	mkdir -p $(BUILD_PATH)
	clang ./src/ax_window_probe_test.m -o $(BUILD_PATH)/ax-window-probe -std=c11 -Wall -Wextra -Wno-unused-parameter -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer -framework ApplicationServices
	$(BUILD_PATH)/ax-window-probe

# Production writer/BSP/signals with modeled AX/display APIs; no window events posted.
resize:
	mkdir -p $(BUILD_PATH)
	clang ./src/mouse_resize_test.m -o $(BUILD_PATH)/mouse-resize -DTESTS -DPROFILE=1 $(TEST_FLAGS) -F/System/Library/PrivateFrameworks -framework Carbon -framework Cocoa -framework CoreServices -framework CoreVideo -framework SkyLight
	$(BUILD_PATH)/mouse-resize

asan:
	$(MAKE) BUILD_PATH=$(BUILD_PATH)-asan TEST_FLAGS="$(SANITIZER_FLAGS)" build run resize memory
