THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:latest:15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES := Walllive

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := WalliveUnlock

WalliveUnlock_FILES := Tweak.xm
WalliveUnlock_CFLAGS := -fobjc-arc -O2 -Wall
WalliveUnlock_FRAMEWORKS := Foundation CoreFoundation UIKit Security AVFoundation CoreMedia CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk
