SHELL := /bin/sh
.PHONY: all macos test ios
all: macos
macos:
	cd macOS && ./build.sh
test:
	python3 -m unittest discover -s macOS/BackendTests -v
	cd macOS && swift test
ios:
	$(MAKE) -C iOS package
