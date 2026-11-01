#!/usr/bin/env bash
# iOS 版のための libsmb2（NAS の SMB に繋ぐ・LGPL 2.1+）を、動的 framework に焼いて xcframework にする。⚠ macOS でだけ走る（CI の macOS runner）。
#
# 🔴 WHY 動的 framework か: ffmpeg と同じ（配る形は Infuse に合わせた）。⚠ libsmb2 の Swift の皮 AMSMB2 も
#    "You **must** link this library dynamically to your app if you intend to distribute your app on App Store." と書いている。
# ⚠ framework の名は `smb2` —— libsmb2 の header は互いを `<smb2/…>` で読む ∴ その綴りのまま Headers から引けるように。
# ⚠ Kerberos / GSSAPI は切る（iOS に libkrb5 は無い・NAS は NTLM で繋ぐ）。
# 出力: ios/HiramieMedia/Frameworks/smb2.xcframework（iOS 実機 arm64 ／ シミュレータ arm64 ／ macOS arm64）
# 使い方: bash tools/build_libsmb2_apple.sh
set -euo pipefail

IOS_MIN=17.0
MAC_MIN=13.0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${SMB2_WORK:-$ROOT/.libsmb2-build-apple}"
OUTDIR="$ROOT/ios/HiramieMedia/Frameworks"
JOBS="$(sysctl -n hw.ncpu)"
# shellcheck source=apple_framework.sh
. "$ROOT/tools/apple_framework.sh"

mkdir -p "$WORK"
SRC="$(bash "$ROOT/tools/fetch_libsmb2.sh" "$WORK")"
VERSION="$(basename "$SRC" | sed -E "s/^libsmb2-libsmb2-//")"   # ⚠ fetch_libsmb2.sh の置き場の名（libsmb2-<TAG>）から

# 切れ端ごとの綴り: 名前 / CMake の system / SDK / Info.plist の platform
SLICES="ios-arm64:iOS:iphoneos:iPhoneOS
ios-arm64-simulator:iOS:iphonesimulator:iPhoneSimulator
macos-arm64:Darwin:macosx:MacOSX"

args=""
while IFS=: read -r NAME SYSTEM SDK PLATFORM; do
  echo
  echo "───────── $NAME ─────────"
  BUILD="$WORK/build/$NAME"
  PREFIX="$WORK/out/$NAME"
  FWS="$WORK/fw/$NAME"
  rm -rf "$BUILD" "$PREFIX" "$FWS"
  mkdir -p "$BUILD" "$FWS"
  if [ "$PLATFORM" = "MacOSX" ]; then minos="$MAC_MIN"; else minos="$IOS_MIN"; fi
  cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_SYSTEM_NAME="$SYSTEM" \
    -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$minos" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=ON -DENABLE_LIBKRB5=OFF -DENABLE_GSSAPI=OFF -DENABLE_EXAMPLES=OFF \
    >/dev/null
  cmake --build "$BUILD" -j "$JOBS" >/dev/null
  cmake --install "$BUILD" >/dev/null
  dylib="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$PREFIX/lib/libsmb2.dylib")"
  fw="$(wrap_framework smb2 "$dylib" "$PREFIX/include/smb2" "$VERSION" "$PLATFORM" "$minos" "$FWS" "")"
  if otool -L "$fw/smb2" | grep -q "$PREFIX"; then echo "⛔ $NAME/smb2 が焼いた場所を指したまま" >&2; otool -L "$fw/smb2" >&2; exit 1; fi
  args="$args -framework $fw"
  echo "$NAME/smb2: $VERSION $(du -hL "$fw/smb2" | cut -f1)"
done <<< "$SLICES"

mkdir -p "$OUTDIR"
rm -rf "$OUTDIR/smb2.xcframework"
# shellcheck disable=SC2086
xcodebuild -create-xcframework $args -output "$OUTDIR/smb2.xcframework" >/dev/null
echo
echo "できた: $(du -sh "$OUTDIR/smb2.xcframework")"
