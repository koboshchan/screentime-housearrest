SHELL := /bin/sh
.PHONY: all macos test ios ios-package audit
all: macos
macos:
	cd macOS && ./build.sh
test:
	python3 -m unittest discover -s macOS/BackendTests -v
	cd macOS && swift test
ios:
	bash iOS/build.sh
ios-package:
	python3 iOS/package.py --production
audit:
	python3 macOS/scripts/audit.py
