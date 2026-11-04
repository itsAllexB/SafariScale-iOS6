# SPDX-License-Identifier: GPL-3.0-or-later
# Dev-only: lets the test machine run JavaScript in Safari's visible page (Cycript can't attach to
# Safari while Web Port is installed). Not part of the SafariScale package. Remove it from the device
# when testing is done: dpkg -r com.itsallexb.safariscale.debug
TARGET := iphone:clang:9.3:6.0
ARCHS = armv7
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SafariScaleDebug
SafariScaleDebug_FILES = Tweak.x
SafariScaleDebug_FRAMEWORKS = UIKit
SafariScaleDebug_USE_MODULES = 0
SafariScaleDebug_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
