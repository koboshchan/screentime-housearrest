THEOS = $(HOME)/theos-roothide
THEOS_PACKAGE_SCHEME = roothide
TARGET = iphone:clang:latest:18.0
ARCHS = arm64
FINALPACKAGE = 1
DEBUG = 0
PACKAGE_VERSION = 0.1.0
override _THEOS_PLATFORM_DPKG_DEB := $(CURDIR)/packaging/dpkg-deb-root
override _THEOS_PLATFORM_DPKG_DEB_COMPRESSION = xz
include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = ScreenTimeEditor
ScreenTimeEditor_BUNDLE_NAME = Surface
ScreenTimeEditor_FILES = $(wildcard Core/*.swift App/*.swift)
ScreenTimeEditor_FRAMEWORKS = UIKit SwiftUI Foundation CryptoKit
ScreenTimeEditor_LIBRARIES = sqlite3 z
ScreenTimeEditor_RESOURCE_FILES = App/Info.plist
ScreenTimeEditor_RESOURCE_DIRS = build/icon-resources
ScreenTimeEditor_CODESIGN_FLAGS = -Sentitlements.plist
ScreenTimeEditor_SWIFT_VERSION = 5
ScreenTimeEditor_INSTALL_PATH = /Applications

TOOL_NAME = stehelper
stehelper_FILES = $(wildcard Core/*.swift Helper/*.swift Helper/*.c)
stehelper_SWIFTFLAGS = -D STE_CALLER_AUTH
stehelper_CFLAGS = -DSTE_APP_CDHASH=\"$(STE_APP_CDHASH)\"
stehelper_FRAMEWORKS = Foundation CryptoKit
stehelper_LIBRARIES = sqlite3 z
stehelper_CODESIGN_FLAGS = -Shelper-entitlements.plist
stehelper_SWIFT_VERSION = 5
stehelper_INSTALL_PATH = /Applications/Surface.app

include $(THEOS_MAKE_PATH)/application.mk
include $(THEOS_MAKE_PATH)/tool.mk

before-all::
	bash ../macOS/scripts/compile-icon.sh iphoneos build/icon-resources

# Explicitly authorized fixed helper only; archive ownership is numeric root:wheel.
after-stage::
	chmod 4755 "$(THEOS_STAGING_DIR)/Applications/Surface.app/stehelper"
