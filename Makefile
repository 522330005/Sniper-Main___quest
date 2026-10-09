THEOS_PACKAGE_SCHEME = rootless

TARGET = iphone:clang:latest:15.0
ARCHS = arm64

TWEAK_NAME = SniperCAMP
SniperCAMP_FILES = Tweak.xm
SniperCAMP_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-varargs -Wno-unused-function
SniperCAMP_LIBRARIES = substrate

# ★ 身份硬校验（解析阶段即生效，不依赖 CI）
#   control 的 Package 必须与本目录 TWEAK_NAME 对应；plist 必须同名存在。
#   任一条不满足 → make 直接失败，绝不会编出"包里装着别人代码"的对调 deb。
EXPECT_PKG := com.sniper.camp
PKG_ACTUAL := $(shell grep -m1 '^Package:' control 2>/dev/null | awk '{print $$2}')
ifneq ($(PKG_ACTUAL),$(EXPECT_PKG))
$(error 对调阻断: control 的 Package 是 '$(PKG_ACTUAL)'，但 TWEAK_NAME='SniperCAMP' 要求 '$(EXPECT_PKG)' —— 极可能是把别的仓库的 control 传到了这里)
endif
ifeq ($(wildcard SniperCAMP.plist),)
$(error 缺少 SniperCAMP.plist —— 本目录是【主线+特别行动】，TWEAK_NAME=SniperCAMP。若在其他仓库看到此报错，说明把别的目录的 Makefile 传错了)
endif

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS)/makefiles/master/rules.mk
