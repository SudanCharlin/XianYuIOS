#
#  XianYuPiggyHand —— Theos 工程（可选）
#
#  本插件不链接 substrate / ellekit，走纯 ObjC Runtime swizzle，
#  这样在【非越狱 · 自签】环境下也能工作。
#

ARCHS = arm64
TARGET = iphone:clang:latest:13.0
INSTALL_TARGET_PROCESSES = 闲鱼

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XianYuPiggyHand
XianYuPiggyHand_FILES = PHCompat.m PHMtop.m PHEngine.m PHHUD.m PHMain.m
XianYuPiggyHand_FRAMEWORKS = UIKit Foundation CoreGraphics
XianYuPiggyHand_CFLAGS = -fobjc-arc
XianYuPiggyHand_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
