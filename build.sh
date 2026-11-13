#!/bin/bash
# ============================================================
#  XianYuPiggyHand —— 直接编译脚本（macOS + Xcode Command Line Tools）
#
#  不需要 Theos。产物是一个不依赖 substrate/ellekit 的独立 dylib，
#  可直接被 Sideloadly / ESign / Azule 等自签工具注入。
#
#  用法:
#     chmod +x build.sh && ./build.sh
#     MIN_IOS=16.0 ./build.sh
# ============================================================
set -euo pipefail

cd "$(dirname "$0")"

OUT="XianYuPiggyHand.dylib"
MIN_IOS="${MIN_IOS:-15.0}"
ARCH="arm64"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "!! 未找到 xcrun：这台机器不是 macOS，或未安装 Xcode Command Line Tools" >&2
  exit 1
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
if [ -z "${SDK}" ] || [ ! -d "${SDK}" ]; then
  echo "!! 找不到 iPhoneOS SDK。请安装 Xcode 并执行：sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

echo "==> macOS:  $(sw_vers -productVersion 2>/dev/null || echo '?')"
echo "==> Xcode:  $(xcodebuild -version 2>/dev/null | head -1 || echo '?')"
echo "==> SDK:    ${SDK}"
echo "==> 目标:   ${ARCH} / iOS ${MIN_IOS}+"

if ! xcrun --sdk iphoneos clang -target "${ARCH}-apple-ios${MIN_IOS}" -x c /dev/null -c -o /dev/null 2>/dev/null; then
  echo "!! 当前 SDK 不支持 iOS ${MIN_IOS} 部署目标，改用 16.0 重试" >&2
  MIN_IOS="16.0"
fi

rm -f "$OUT"

# 自动收集所有 .m，新增源文件不用改脚本
SRCS=$(ls *.m 2>/dev/null | tr '\n' ' ')
if [ -z "${SRCS}" ]; then
  echo "!! 当前目录没有 .m 源文件" >&2
  exit 1
fi
echo "==> 源文件: ${SRCS}"

clang \
  -target "${ARCH}-apple-ios${MIN_IOS}" \
  -isysroot "$SDK" \
  -dynamiclib \
  -fobjc-arc \
  -fobjc-exceptions \
  -O2 \
  -fvisibility=hidden \
  -install_name "@executable_path/Frameworks/${OUT}" \
  -framework Foundation \
  -framework UIKit \
  -framework CoreGraphics \
  -undefined dynamic_lookup \
  ${SRCS} \
  -o "$OUT"

if command -v ldid >/dev/null 2>&1; then
  ldid -S "$OUT" && echo "==> 已用 ldid 做 ad-hoc 签名"
fi

echo "==> 产物: $(pwd)/${OUT}"
ls -lh "$OUT"
file "$OUT"
otool -hv "$OUT" | tail -3
