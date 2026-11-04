# SPDX-License-Identifier: GPL-3.0-or-later
TARGET := iphone:clang:9.3:6.0
ARCHS = armv7 arm64

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SafariScalePrefs
SafariScalePrefs_FILES = SSCRootListController.m
SafariScalePrefs_FRAMEWORKS = UIKit
SafariScalePrefs_PRIVATE_FRAMEWORKS = Preferences
SafariScalePrefs_INSTALL_PATH = /Library/PreferenceBundles
SafariScalePrefs_CFLAGS = -fobjc-arc -fno-modules

include $(THEOS_MAKE_PATH)/bundle.mk
