#
# LiqTab — Makefile (Theos, rootless-friendly)
#
# Builds a plain dynamic library (dylib), NOT a Substrate/Logos tweak.
# It uses only the Objective-C runtime, so no tweak injection runtime is
# required inside Douyin. Inject the resulting dylib with TrollFools/azule.
#
# Build locally:
#   make clean && make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
# Build via GitHub Actions: see .github/workflows/build.yml
#

THEOS_PACKAGE_SCHEME = rootless

TARGET = iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = LiqTab
# Explicit Sources/ prefix is the most reliable form for Theos + CI.
LiqTab_FILES = Sources/Tweak.m \
               Sources/LTPrefs.m \
               Sources/LTCustomGlassView.m \
               Sources/LTTabItemView.m \
               Sources/LTTabBarMirror.m \
               Sources/LTNativeGlassEnabler.m

LiqTab_CFLAGS = -fobjc-arc -w -I$(CURDIR)/Sources
LiqTab_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics
# No Logos, no Substrate, no CydiaSubstrate dependency.
LiqTab_LDFLAGS += -Wl,-rpath,@executable_path/Frameworks

include $(THEOS_MAKE_PATH)/library.mk
