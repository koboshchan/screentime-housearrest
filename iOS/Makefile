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
ScreenTimeEditor_FILES = $(wildcard Core/*.swift App/*.swift)
ScreenTimeEditor_FRAMEWORKS = UIKit SwiftUI Foundation
ScreenTimeEditor_RESOURCE_FILES = App/Info.plist
ScreenTimeEditor_CODESIGN_FLAGS = -Sentitlements.plist
ScreenTimeEditor_SWIFT_VERSION = 5
ScreenTimeEditor_INSTALL_PATH = /Applications

TOOL_NAME = stehelper
stehelper_FILES = $(wildcard Core/*.swift Helper/*.swift Helper/*.c)
stehelper_SWIFTFLAGS = -D STE_CALLER_AUTH
stehelper_CFLAGS = -DSTE_APP_CDHASH=\"$(STE_APP_CDHASH)\"
stehelper_FRAMEWORKS = Foundation
stehelper_CODESIGN_FLAGS = -Shelper-entitlements.plist
stehelper_SWIFT_VERSION = 5
stehelper_INSTALL_PATH = /Applications/ScreenTimeEditor.app

include $(THEOS_MAKE_PATH)/application.mk
include $(THEOS_MAKE_PATH)/tool.mk

# Never enable setuid before a separately reviewed authenticated launch contract.
after-stage::
	chmod 0755 "$(THEOS_STAGING_DIR)/Applications/ScreenTimeEditor.app/stehelper"
