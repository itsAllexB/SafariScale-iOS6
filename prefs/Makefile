# SPDX-License-Identifier: GPL-3.0-or-later
TARGET := iphone:clang:9.3:6.0
ARCHS = armv7 arm64

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = PageScalePrefs
PageScalePrefs_FILES = PGSRootListController.m
PageScalePrefs_FRAMEWORKS = UIKit
PageScalePrefs_PRIVATE_FRAMEWORKS = Preferences
PageScalePrefs_INSTALL_PATH = /Library/PreferenceBundles
PageScalePrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
