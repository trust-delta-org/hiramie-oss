#!/usr/bin/env bash
# iOS 版のための ffmpeg（libavutil / libavcodec / libavformat）を、動的 framework に焼いて xcframework にする。⚠ macOS でだけ走る（CI の macOS runner）。
#
# 🔴 中身は Android（tools/build_ffmpeg.sh）と同じにする —— 版・sha256・名指す demuxer / parser / bsf。
#    ⛔ decoder は 1 つも入れない（operator 確定 2026-09-22・特許）。画を解くのは端末（VideoToolbox）。
#
# 🔴 WHY 動的 framework か（2026-11-01）: 配る形は Infuse に合わせる（operator の基準「他の iOS の動画プレイヤーに合わせる」→
#    公開物から追えたのは Infuse だけ ＝ ffmpeg を shared（framework）で焼き、ソースを公開している）。Android も共有ライブラリで配っている。
#    ⚠ 「framework の形」と「動的」は別物（中が静的な .a の framework も在る）∴ 末尾で中身が dylib であることを確かめ、違えば止まる。
#
# 出力: ios/HiramieMedia/Frameworks/{libavutil,libavcodec,libavformat}.xcframework
#       （iOS 実機 arm64 ／ iOS シミュレータ arm64 ／ macOS arm64 —— macOS は `swift test` を simulator 無しで回すためだけ）
# 使い方: bash tools/build_ffmpeg_apple.sh
set -euo pipefail

VERSION=8.1.3
SHA256=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3
IOS_MIN=17.0
MAC_MIN=13.0
# ⚠ 並びは依存の向き（avformat → avcodec → avutil）。
LIBS="avutil avcodec avformat"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${FFMPEG_WORK:-$ROOT/.ffmpeg-build-apple}"
OUTDIR="$ROOT/ios/HiramieMedia/Frameworks"
JOBS="$(sysctl -n hw.ncpu)"

mkdir -p "$WORK"
cd "$WORK"
TARBALL="ffmpeg-$VERSION.tar.xz"
[ -f "$TARBALL" ] || curl -sSLO "https://ffmpeg.org/releases/$TARBALL"
# ⚠ macOS には sha256sum が無いことがある ∴ shasum で照合する。⛔ 違えば止まる。
echo "$SHA256  $TARBALL" | shasum -a 256 -c - || { echo "⛔ sha256 が合わない" >&2; exit 1; }
SRC="$WORK/ffmpeg-$VERSION"
[ -d "$SRC" ] || tar xf "$TARBALL"

# 包む手順（Info.plist・名乗りの付け替え・dylib であることの確かめ）は libsmb2 と共通。
# shellcheck source=apple_framework.sh
. "$ROOT/tools/apple_framework.sh"

# 切れ端ごとの綴り: 名前 / SDK / 対象の三つ組 / Info.plist の platform
SLICES="ios-arm64:iphoneos:arm64-apple-ios$IOS_MIN:iPhoneOS
ios-arm64-simulator:iphonesimulator:arm64-apple-ios$IOS_MIN-simulator:iPhoneSimulator
macos-arm64:macosx:arm64-apple-macos$MAC_MIN:MacOSX"

# ⚠ macOS の標準の bash は 3.2 ∴ 連想配列を使わず、「名:framework の在り処」を並べて後で拾う。
FRAMEWORKS=""
while IFS=: read -r NAME SDK TARGET PLATFORM; do
  echo
  echo "───────── $NAME ─────────"
  SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
  CC="$(xcrun --sdk "$SDK" -f clang)"
  PREFIX="$WORK/out/$NAME"
  BUILD="$WORK/build/$NAME"
  FWS="$WORK/fw/$NAME"
  rm -rf "$PREFIX" "$BUILD" "$FWS"
  mkdir -p "$BUILD" "$FWS"
  cd "$BUILD"
  # 🔴 要るものだけを名指す（Android と同じ並び）。⚠ `--disable-autodetect` —— VideoToolbox 等を黙って拾わせない。
  "$SRC/configure" \
    --prefix="$PREFIX" \
    --enable-cross-compile --target-os=darwin --arch=arm64 \
    --cc="$CC" --sysroot="$SYSROOT" \
    --extra-cflags="-target $TARGET" --extra-ldflags="-target $TARGET" \
    --disable-autodetect \
    --disable-everything \
    --disable-programs --disable-doc --disable-debug \
    --disable-avdevice --disable-avfilter --disable-swresample --disable-swscale \
    --disable-network --disable-iconv --disable-zlib --disable-bzlib --disable-lzma \
    --disable-static --enable-shared --enable-pic \
    --enable-demuxer=matroska,mov,avi,mpegts,flv \
    --enable-parser=h264,hevc,aac,ac3,mpegaudio,flac,opus,vorbis \
    --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,extract_extradata \
    --enable-protocol=file \
    >/dev/null
  make -j"$JOBS" install >/dev/null

  for lib in $LIBS; do
    name="lib$lib"
    # libavutil.dylib → libavutil.60.dylib → libavutil.60.x.y.dylib の実体（⚠ 古い macOS の readlink は -f を持たない ∴ python で辿る）
    dylib="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$PREFIX/lib/$name.dylib")"
    version="$(basename "$dylib" | sed -E "s/^$name\.([0-9.]+)\.dylib$/\1/")"
    deps=""
    for dep in $LIBS; do deps="$deps /lib$dep\.[0-9]+\.dylib\$:lib$dep"; done
    if [ "$PLATFORM" = "MacOSX" ]; then minos="$MAC_MIN"; else minos="$IOS_MIN"; fi
    fw="$(wrap_framework "$name" "$dylib" "$PREFIX/include/$name" "$version" "$PLATFORM" "$minos" "$FWS" "$deps")"
    if otool -L "$fw/$name" | grep -q "$PREFIX"; then echo "⛔ $NAME/$name が焼いた場所を指したまま" >&2; otool -L "$fw/$name" >&2; exit 1; fi
    FRAMEWORKS="$FRAMEWORKS $lib:$fw"
    echo "$NAME/$name: $version $(du -hL "$fw/$name" | cut -f1)"
  done
done <<< "$SLICES"

mkdir -p "$OUTDIR"
for lib in $LIBS; do
  # ⚠ 自分の xcframework だけを消す —— ⛔ 置き場を丸ごと消すと、同じ所に置く libsmb2 まで消える。
  rm -rf "$OUTDIR/lib$lib.xcframework"
  args=""
  for entry in $FRAMEWORKS; do
    [ "${entry%%:*}" = "$lib" ] && args="$args -framework ${entry#*:}"
  done
  # shellcheck disable=SC2086
  xcodebuild -create-xcframework $args -output "$OUTDIR/lib$lib.xcframework" >/dev/null
done
echo
echo "できた:"
du -sh "$OUTDIR"/libav*.xcframework
