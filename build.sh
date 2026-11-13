#!/bin/bash
# ============================================================
#  XianYuPiggyHand —— 直接编译脚本（macOS + Xcode Command Line Tools）
#
#  不需要 Theos。产物是一个不依赖 substrate/ellekit 的独立 dylib，
#  可直接被 Sideloadly / ESign / Azule 等自签工具注入。
#
#  用法:
#     chmod +x build.sh && ./build.sh
# ============================================================
set -euo pipefail

cd "$(dirname "$0")"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
OUT="XianYuPiggyHand.dylib"
MIN_IOS="13.0"

echo "==> SDK: $SDK"
echo "==> 目标: arm64 / iOS ${MIN_IOS}+"

rm -f "$OUT"

clang \
  -arch arm64 \
  -mios-version-min="${MIN_IOS}" \
  -isysroot "$SDK" \
  -dynamiclib \
  -fobjc-arc \
  -O2 \
  -fvisibility=hidden \
  -fobjc-exceptions \
  -install_name "@executable_path/Frameworks/${OUT}" \
  -framework Foundation \
  -framework UIKit \
  -framework CoreGraphics \
  -undefined dynamic_lookup \
  PHCompat.m PHMtop.m PHEngine.m PHHUD.m PHMain.m \
  -o "$OUT"

echo "==> 产物: $(pwd)/${OUT}"
ls -lh "$OUT"
/usr/bin/otool -L "$OUT" | head -20
