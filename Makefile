# IntentsHelperQuiet v1.0.0
#   Block ONLY the full-scan surface of intents_helper.xpc
#   (schema discovery / intentDefinitionURLs / purgeExpiredImagesInEphemeralStore /
#    optional share suggestion). ALL image & avatar paths are left untouched so
#   WeChat / Soul notification extensions keep working (see 2026-11-22 crash proof).
# Pure objc-runtime hooks: no Logos, no substrate/ellekit, no Foundation/UIKit link
# (a launchd XPC service must not dlopen heavy frameworks -> silent no-inject).
export TARGET = iphone:clang:latest:16.0
export ARCHS = arm64e

THEOS_PACKAGE_SCHEME ?= roothide
export THEOS_PACKAGE_SCHEME
export _THEOS_PLATFORM_DPKG_DEB_COMPRESSION = gzip

TWEAK_NAME = IntentsHelperQuiet
IntentsHelperQuiet_FILES = Tweak.xm
IntentsHelperQuiet_CFLAGS = -Os -Wall -Wno-cast-function-type -Wno-unused-function
IntentsHelperQuiet_LDFLAGS = -Wl,-dead_strip_dylibs
IntentsHelperQuiet_LIBRARIES = objc
ERROR_ON_WARNINGS = 0

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
