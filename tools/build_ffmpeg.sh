#!/usr/bin/env bash
# H.264 の **ソフトウェア decoder だけ**を持つ ffmpeg を焼く。
#
# 🔴 WHY 要るか（operator 確定 2026-09-22「他で再生できて本アプリで出来ないのは避けたい」）:
# **この端末の AVC decoder は 8 つとも High 10 を名乗らない**（ハードもソフトも）——
# ⛔ **MediaCodec では 10bit の H.264 に落とし先が無い**。VLC / nPlayer が再生できるのは
# 自前のソフト decoder を持っているからである（`docs/aims/runs-on-my-setup.md`）。
#
# 🔴 **共有ライブラリとして出す**（⛔ 静的に畳み込まない）—— ⚠ **LGPL は差し替えられることを求める**:
# `.so` で同梱していれば、利用者は libavcodec を自分のものへ入れ替えて再署名できる。
# ⛔ **GPL の部品は 1 つも入れない**（`--enable-gpl` を付けない ∴ x264 等は入らない）。
#
# ⚠ **版は固定する** —— ⛔ 「最新」を引くと、焼き直すたびに別のものが入る。
# ⚠ **sha256 を照合する** —— ⛔ 製品に載せる binary の出どころを運任せにしない。
#
# 使い方: tools/build_ffmpeg.sh
# 出力:   app/src/main/jniLibs/arm64-v8a/lib{avcodec,avutil,avformat}.so（個人用の build では libswscale.so も）
#         app/src/main/cpp/ffmpeg/include/**（ヘッダ）
set -euo pipefail

VERSION=8.1.3
# 🔴 **出どころを 2 つで縛る。**
# ⚠ **sha256 は毎回照合する**（⛔ 違えば止まる）。
# ⚠ **署名は gpg が在れば照合する** —— 🔴 **鍵の指紋は ffmpeg.org/download.html が公開しているもの**
#    （2026-09-22 に照合し、`Good signature` を得た）。⛔ **公式サイトが配る鍵だけを信じる形ではない**:
#    **指紋をここに焼き込んである** ∴ 配られた鍵が入れ替われば止まる。
SHA256=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3
KEY_FPR=FCF986EA15E6E293A5644F10B4322F04D67658D8
NDK="${ANDROID_NDK_HOME:-$HOME/Android/Sdk/ndk/27.3.13750724}"
# 🔴 **API 27 で焼く** —— `minSdk` と同じ（⛔ 上げると、下の端末で dlopen が落ちる）。
API=27
# 🔴 **3 つの ABI を焼く。**
# ⚠ **native を 1 つでも積むと、積んだ ABI の端末にしか入らなくなる**
#    （`INSTALL_FAILED_NO_MATCHING_ABIS`）∴ ⛔ **arm64 だけにすると、32bit の端末と
#    emulator（x86_64）から締め出すことになる。**
# ⚠ **AAB は ABI ごとに分けて配る** ∴ **利用者が取る量は 1 つぶんのままである。**
# ⚠ x86_64 は `nasm` が要る ∴ 無ければ asm を落として焼く（**emulator 用であり、速さは要らない**）。
ABIS="${ABIS:-arm64-v8a armeabi-v7a x86_64}"

# 🔴 **配るものに decoder は入れない**（operator 確定 2026-09-22・特許）——
# ⛔ **既定は空である。** ⚠ **この switch は *個人の端末用* であり、配布物ではない。**
#
# 🔴 WHY switch にしたか: **手で書き換えて戻す形だと、次に誰かが焼き直した瞬間に黙って消える。**
# ⚠ **同梱の断り（`third_party.txt`）は *既定の build* を述べている**
# ∴ ⛔ **これを立てて焼いたものは、断りと食い違う** —— **配ってはならない。**
#
#   使い方: VFV_PERSONAL_DECODERS=h264 ABIS=arm64-v8a bash tools/build_ffmpeg.sh
PERSONAL=""
# 🔴 **swscale は配る build に入れない**（operator 確定 2026-09-23「使わなければ落とす」）——
# ⚠ 使っていたのは decoder の画を RGBA へ均す 1 か所だけで、**配る build には decoder が無い** ∴ 1 度も呼ばれず 3 ABI で 3.3MB を占めていた。
# ⚠ 遠隔の EBML の 1 枚（`FrameGrab`）は端末の decoder が返す YUV を Kotlin で縮める ∴ ここでも要らない。
# ✅ **個人用の build だけは残す** —— decoder を足すなら、その画を出すのに要る（`vfvdec.c` は在るときだけ使う）。
LIBS="avcodec avutil avformat"
SWS="--disable-swscale"
if [ -n "${VFV_PERSONAL_DECODERS:-}" ]; then
  PERSONAL="--enable-decoder=$VFV_PERSONAL_DECODERS"
  LIBS="avcodec avutil swscale avformat"
  SWS=""
  echo "⚠ 個人用に decoder を足して焼く: $VFV_PERSONAL_DECODERS（⛔ 配らないこと）"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${FFMPEG_WORK:-$ROOT/.ffmpeg-build}"
INCLUDE="$ROOT/app/src/main/cpp/ffmpeg/include"

# ABI ごとの綴り。⚠ ffmpeg の `--arch` と NDK の triple は名前が揃っていない。
arch_of() { case "$1" in arm64-v8a) echo aarch64;; armeabi-v7a) echo arm;; x86_64) echo x86_64;; esac; }
triple_of() { case "$1" in
  arm64-v8a) echo aarch64-linux-android;;
  # ⚠ **compiler の名前だけ `armv7a-...-eabi`** —— ⛔ 揃っていると思って書くと見つからない。
  armeabi-v7a) echo armv7a-linux-androideabi;;
  x86_64) echo x86_64-linux-android;;
esac; }

[ -d "$NDK" ] || { echo "NDK が無い: $NDK（ANDROID_NDK_HOME で指せる）" >&2; exit 1; }
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
[ -d "$TOOLCHAIN" ] || { echo "toolchain が無い: $TOOLCHAIN" >&2; exit 1; }

mkdir -p "$WORK"
cd "$WORK"
TARBALL="ffmpeg-$VERSION.tar.xz"
if [ ! -f "$TARBALL" ]; then
  echo "取ってくる: $TARBALL"
  curl -sSLO "https://ffmpeg.org/releases/$TARBALL"
fi
echo "$SHA256  $TARBALL" | sha256sum -c - || { echo "⛔ sha256 が合わない" >&2; exit 1; }

if command -v gpg >/dev/null 2>&1; then
  [ -f "$TARBALL.asc" ] || curl -sSLO "https://ffmpeg.org/releases/$TARBALL.asc"
  [ -f ffmpeg-devel.asc ] || curl -sSL https://ffmpeg.org/ffmpeg-devel.asc -o ffmpeg-devel.asc
  ring="$(mktemp -d)"
  GNUPGHOME="$ring" gpg --batch --quiet --import ffmpeg-devel.asc
  GNUPGHOME="$ring" gpg --batch --with-colons --fingerprint 2>/dev/null \
    | grep -q "^fpr:::::::::$KEY_FPR:" || { echo "⛔ 配られた鍵の指紋が違う" >&2; exit 1; }
  GNUPGHOME="$ring" gpg --batch --quiet --verify "$TARBALL.asc" "$TARBALL" \
    || { echo "⛔ 署名が通らない" >&2; exit 1; }
  rm -rf "$ring"
  echo "署名: 通った（$KEY_FPR）"
else
  # ⚠ **止めない** —— sha256 は既に通っている。⛔ だが「照合していない」ことは述べる。
  echo "⚠ gpg が無い ∴ 署名は照合していない（sha256 だけ）"
fi

SRC="$WORK/ffmpeg-$VERSION"
[ -d "$SRC" ] || tar xf "$TARBALL"
cd "$SRC"

for ABI in $ABIS; do
echo
echo "───────── $ABI ─────────"
ARCH="$(arch_of "$ABI")"
TRIPLE="$(triple_of "$ABI")"
JNILIBS="$ROOT/app/src/main/jniLibs/$ABI"

# ⚠ **焼き直しは掃除してから** —— ⛔ 前回の config.mak が残ると、変えたつもりの flag が効かない。
[ -f ffbuild/config.mak ] && make distclean >/dev/null 2>&1 || true

# ⚠ x86 の asm は nasm が要る ∴ 無ければ落とす（⛔ 黙って落とさず、下で述べる）。
XASM=""
if [ "$ABI" = "x86_64" ] && ! command -v nasm >/dev/null 2>&1; then
  XASM="--disable-x86asm"
  echo "⚠ nasm が無い ∴ x86_64 は asm 無しで焼く（emulator 用）"
fi
# ⚠ armeabi-v7a は NEON を明示する（⛔ 既定では入らない端末向けの code になる）。
CPUFLAG=""
case "$ABI" in
  arm64-v8a) CPUFLAG="--cpu=armv8-a";;
  armeabi-v7a) CPUFLAG="--cpu=armv7-a --enable-neon";;
esac

# 🔴 **要るものだけを名指す。** ⛔ `--disable-everything` の後に、使うものだけを足す。
# ⚠ **decode**: h264 の decoder（**端末が High 10 を持っていない**）。
# 🔴 **demux**: **端末の読み取り器が倒れるファイルが在る**（operator の NAS で実測 2026-09-22・
#    `MMParserExtractor: FileSourceWrapper::New Init returned -1004` → **トラック 0 本**）∴
#    **`MediaExtractor` が読めなかったときの 2 本目の道として avformat を積む。**
#    ⚠ **matroska だけにしない** —— **倒れるのが mkv だけだと決まったわけではない。**
# 🔴 **bsf が要る** —— ⛔ **mkv / mp4 の H.264 は length 前置（AVCC）であり、`MediaCodec` は
#    start code（Annex-B）しか受けない**。⚠ **`MediaExtractor` はそこを黙って直していた** ∴
#    **自前で読むなら自前で直す**（`h264_mp4toannexb` / `hevc_mp4toannexb`）。
# ⚠ **swscale は配る build では落とす**（上の `SWS`）—— 🔴 **decoder の画を RGBA へ均すための物で、配る build に decoder は無い。**
# ⛔ **音の decoder は積まない** —— **音は今までどおり `MediaCodec` が鳴らす**（切り出すだけ）。
# ⚠ **`--enable-small` は付けない** —— **速さが要る**（1080p の 10bit を CPU で回す）。
# 🔴 **`max-page-size=16384`** —— ⛔ **Play は 16KB のページサイズに対応しない .so を製品版へ出させない**
#    （実測 2026-09-23・製品版のレビューで「このアプリは 16 KB メモリのページサイズをサポートしていません」がエラー。
#    内部テストでは通っていた）。**NDK r27 は既定で 4KB（`LOAD` の Align が 0x1000）** ∴ linker に名指す。
#    ⚠ **CMake で焼く `libvfvdec.so` の側は `build.gradle.kts` の `ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES` が受け持つ。**
./configure \
  --prefix="$SRC/out" \
  --target-os=android --arch="$ARCH" $CPUFLAG $XASM --enable-cross-compile \
  --sysroot="$TOOLCHAIN/sysroot" \
  --cc="$TOOLCHAIN/bin/$TRIPLE$API-clang" \
  --cxx="$TOOLCHAIN/bin/$TRIPLE$API-clang++" \
  --ar="$TOOLCHAIN/bin/llvm-ar" \
  --nm="$TOOLCHAIN/bin/llvm-nm" \
  --ranlib="$TOOLCHAIN/bin/llvm-ranlib" \
  --strip="$TOOLCHAIN/bin/llvm-strip" \
  --disable-everything \
  --disable-programs --disable-doc --disable-symver --disable-debug \
  --disable-avdevice --disable-avfilter \
  --disable-swresample $SWS \
  --disable-network --disable-iconv --disable-zlib --disable-bzlib --disable-lzma \
  --disable-static --enable-shared --enable-pic \
  --enable-demuxer=matroska,mov,avi,mpegts,flv \
  --enable-parser=h264,hevc,aac,ac3,mpegaudio,flac,opus,vorbis \
  --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,extract_extradata \
  --enable-protocol=file \
  --extra-ldflags="-Wl,-z,max-page-size=16384" \
  $PERSONAL

# 🔴 **版のついた名前を作らせない** —— ⛔ Android の packaging は `lib*.so` しか拾わず、
#    **`libavcodec.so.62` は APK に入っても dlopen で見つからない。**
make -j"$(nproc)" \
  SLIBNAME='$(SLIBPREF)$(FULLNAME)$(SLIBSUF)' \
  SLIBNAME_WITH_VERSION='$(SLIBNAME)' \
  SLIBNAME_WITH_MAJOR='$(SLIBNAME)' \
  SLIB_INSTALL_NAME='$(SLIBNAME)' \
  SLIB_INSTALL_LINKS='' \
  install

mkdir -p "$JNILIBS" "$INCLUDE"
# ⚠ **配る build では前回の libswscale.so を消す** —— ⛔ 残すと CMake が見つけて繋ぎ、断りとも食い違う。
[ -z "$SWS" ] || rm -f "$JNILIBS/libswscale.so"
for lib in $LIBS; do
  src="$SRC/out/lib/lib$lib.so"
  [ -f "$src" ] || { echo "焼けていない: $src" >&2; exit 1; }
  "$TOOLCHAIN/bin/llvm-strip" --strip-unneeded -o "$JNILIBS/lib$lib.so" "$src"
done
# ⚠ **ヘッダは 1 組でよい** —— ⛔ ABI ごとに違うのは `avconfig.h` くらいで、こちらは使わない。
rm -rf "$INCLUDE"/{libavcodec,libavutil,libswscale,libavformat}
for lib in $LIBS; do cp -r "$SRC/out/include/lib$lib" "$INCLUDE/"; done
echo "$ABI: $(du -sh "$JNILIBS" | cut -f1)"
rm -rf "$SRC/out"
done

echo
echo "できた:"
du -sh "$ROOT/app/src/main/jniLibs"/* 2>/dev/null
echo "合計 $(du -sh "$ROOT/app/src/main/jniLibs" | cut -f1)"
