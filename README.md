# hiramie-oss

Source code and build scripts for the open-source libraries that **Hiramie** (a VR video player for iPhone and Android) ships.
Both libraries are licensed under the **GNU Lesser General Public License, version 2.1 or later (LGPL-2.1-or-later)**.
They are included **unmodified**. This repository lets you rebuild them and swap them for your own builds.

> 日本語: アプリ「Hiramie」が配っている LGPL のライブラリ（FFmpeg・libsmb2）の、ソースと焼き方の置き場です。
> どちらも手を入れていません。ここのスクリプトで焼き直し、アプリの中のものと差し替えられます。

## What is included

| Library | Version | Used on | Upstream | Pinned by |
|---|---|---|---|---|
| FFmpeg (`libavutil`, `libavcodec`, `libavformat`) | 8.1.3 | iOS, Android | https://ffmpeg.org/ | sha256 `7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3` |
| libsmb2 (the `lib` and `include` directories) | libsmb2-6.3 | iOS | https://github.com/sahlberg/libsmb2 | git commit `2bcb014b23a8c8cccf534eea8bda2fe5df453cfd` |

- `sources/` holds the exact source archives the app was built from. `SHA256SUMS` lists their checksums.
  - `ffmpeg-8.1.3.tar.xz` is the release tarball from ffmpeg.org, byte for byte.
  - `libsmb2-libsmb2-6.3.tar.gz` is `git archive` of the commit above.
- `tools/` holds the build scripts the app is built with, copied verbatim. The comments in them are in Japanese.
- `LICENSES/` holds the license texts that ship with each library.

### FFmpeg is built without decoders and without GPL parts

- Only the parts that read video files are built: the demuxers, parsers and bitstream filters named in the `./configure` line of each script.
- **No decoder is built.** The device decodes the video (VideoToolbox on iOS, MediaCodec on Android).
- `--enable-gpl`, `--enable-version3` and `--enable-nonfree` are never used.

### Android also ships jcifs-ng

The Android app also uses **jcifs-ng 2.1.10** (LGPL-2.1-or-later), unmodified, as published on Maven Central (`eu.agno3.jcifs:jcifs-ng:2.1.10`).
Its source is at https://github.com/AgNO3/jcifs-ng (tag `jcifs-ng-2.1.10`). It is a Java library, so it is not rebuilt here.

## How the libraries are shipped

- **iOS:** as dynamic frameworks inside the app bundle:
  `Hiramie.app/Frameworks/libavutil.framework`, `libavcodec.framework`, `libavformat.framework` and `smb2.framework`.
  Each one holds a dynamic library (`Mach-O 64-bit dynamically linked shared library arm64`).
- **Android:** as shared libraries inside the app: `libavutil.so`, `libavcodec.so` and `libavformat.so`.

## Rebuilding

### iOS (needs macOS with Xcode)

```sh
bash tools/build_ffmpeg_apple.sh     # → ios/HiramieMedia/Frameworks/libav*.xcframework
bash tools/build_libsmb2_apple.sh    # → ios/HiramieMedia/Frameworks/smb2.xcframework
```

- The scripts download the sources themselves and stop if they do not match the pinned sha256 or commit.
- To use the FFmpeg tarball in `sources/` instead of downloading it, copy `ffmpeg-8.1.3.tar.xz` into `.ffmpeg-build-apple/` first.
- libsmb2 is fetched with `git clone` (`tools/fetch_libsmb2.sh`). The tree is the same as `libsmb2-libsmb2-6.3.tar.gz`.
- Each script builds three slices (iOS device arm64, iOS simulator arm64, macOS arm64) and wraps each library as a framework.
  The install name is `@rpath/<name>.framework/<name>`.
  Wrapping changes only the install names, `Info.plist` and the ad-hoc signature. The library code is not changed.

### Android (needs the Android NDK)

```sh
bash tools/build_ffmpeg.sh           # → app/src/main/jniLibs/<ABI>/lib{avutil,avcodec,avformat}.so
```

## Replacing a library in the app

- **iOS:**
  1. Build your own version of the framework, with the same name and a compatible ABI (same major version).
  2. Copy its binary over `Hiramie.app/Frameworks/<name>.framework/<name>`.
  3. Re-sign the app with your own signing identity (`codesign --force --deep --sign <identity> Hiramie.app`) and install it on your device.
- **Android:**
  1. Replace the `.so` files inside the APK.
  2. Re-sign the APK with your own key.

## License

- FFmpeg: LGPL-2.1-or-later. See `LICENSES/FFmpeg-COPYING.LGPLv2.1` and `LICENSES/FFmpeg-LICENSE.md`.
- libsmb2: LGPL-2.1-or-later for the library. See `LICENSES/libsmb2-COPYING` and `LICENSES/libsmb2-LICENCE-LGPL-2.1.txt`.
  Its examples are BSD-licensed and are not built.
- The build scripts in `tools/` are released under the same license as the library they build (LGPL-2.1-or-later).
