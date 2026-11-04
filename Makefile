# SPDX-License-Identifier: GPL-3.0-or-later
# iOS 6 and 7: armv7 (iPhone 4S/5/5c, iPad 2-4, iPad mini) and arm64 (iPhone 5s, iPad Air, iPad mini 2/3).
# The iOS 9.3 SDK is the newest one in theos/sdks that still has armv7.
TARGET := iphone:clang:9.3:6.0
ARCHS = armv7 arm64
INSTALL_TARGET_PROCESSES = MobileSafari
# Cydia's dpkg on iOS 6 handles gzip; newer formats aren't a safe bet.
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SafariScale
SafariScale_FILES = Tweak.x
SafariScale_FRAMEWORKS = UIKit
# The iOS 9.3 SDK ships old module.map files that current clang rejects, so no clang modules.
SafariScale_USE_MODULES = 0
SafariScale_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
