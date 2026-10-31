# Makefile — Theos | FFCheat dylib | ARM64 iOS 14+

export THEOS          ?= $(HOME)/theos
export TARGET          = iphone:clang:latest:14.0
export ARCHS           = arm64
export DEBUG           = 0

INSTALL_TARGET_PROCESSES = com.dena.a12122643

include $(THEOS)/makefiles/common.mk

TWEAK_NAME            = FFCheat
FFCheat_FILES         = Tweak.mm
FFCheat_CFLAGS        = -fobjc-arc -O2 -fvisibility=hidden
FFCheat_CCFLAGS       = $(FFCheat_CFLAGS)
FFCheat_FRAMEWORKS    = UIKit CoreGraphics Foundation
FFCheat_LIBRARIES     = substrate

include $(THEOS)/makefiles/tweak.mk

# after build, grab the dylib from .theos/obj/
after-stage::
	@echo "[+] dylib → $(THEOS_STAGING_DIR)"
