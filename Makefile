# TARGET = simulator:clang::14.0
# ARCHS = x86_64 

TARGET := iphone:clang:16.5:14.0
ARCHS = arm64
# INSTALL_TARGET_PROCESSES = Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ZImmortalizerJailed

ZImmortalizerJailed_FILES = main.m CustomToastView.m FloatingButtonWindow.m ImmortalizerLog.m
ZImmortalizerJailed_CFLAGS = -fobjc-arc -fcommon -Wno-error
include $(THEOS_MAKE_PATH)/tweak.mk
