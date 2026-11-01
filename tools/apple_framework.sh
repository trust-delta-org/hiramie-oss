# 焼いた dylib を、iOS / macOS の動的 framework に包む —— build_ffmpeg_apple.sh と build_libsmb2_apple.sh が source する。⚠ macOS でだけ動く。
#
# 🔴 WHY 動的 framework か: 配る形は Infuse に合わせた（LGPL の部品 ＝ ffmpeg・libsmb2 を差し替えられる形で載せる）。
# ⚠ 「framework の形」と「動的」は別物 ∴ 包んだ後に中身が dylib であることを確かめ、違えば止まる。

# framework の Info.plist。⚠ iOS は MinimumOSVersion が無いと App Store の検証で弾かれる。
#   $1=名 $2=版 $3=platform（iPhoneOS / iPhoneSimulator / MacOSX）$4=出力 $5=最低の OS の版
framework_plist() {
  local minkey="MinimumOSVersion"
  [ "$3" = "MacOSX" ] && minkey="LSMinimumSystemVersion"
  cat > "$4" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$1</string>
  <key>CFBundleIdentifier</key><string>app.hiramie.oss.$1</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$1</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$2</string>
  <key>CFBundleVersion</key><string>$2</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$3</string></array>
  <key>$minkey</key><string>$5</string>
</dict>
</plist>
EOF
}

# dylib を framework に包み、名乗りと依存を `@rpath/<名>.framework/<名>` に直す。包んだ framework の在り処を 1 行で返す。
#   $1=framework の名 $2=dylib（実体）$3=header の dir（中身を Headers へ写す）$4=版 $5=platform $6=最低の OS $7=置き場
#   $8=「旧い名乗りの正規表現:新しい framework の名」を空白区切りで（依存の付け替え・無ければ空）
wrap_framework() {
  local name="$1" dylib="$2" headers="$3" version="$4" platform="$5" minos="$6" out="$7" deps="${8:-}"
  local fw="$out/$name.framework" bin
  rm -rf "$fw"
  if [ "$platform" = "MacOSX" ]; then
    # ⚠ macOS の framework は版付きの深い形（Versions/A）でなければならない。
    mkdir -p "$fw/Versions/A/Headers" "$fw/Versions/A/Resources"
    cp "$dylib" "$fw/Versions/A/$name"
    cp -R "$headers/." "$fw/Versions/A/Headers/"
    framework_plist "$name" "$version" "$platform" "$fw/Versions/A/Resources/Info.plist" "$minos"
    ln -s A "$fw/Versions/Current"
    ln -s "Versions/Current/$name" "$fw/$name"
    ln -s Versions/Current/Headers "$fw/Headers"
    ln -s Versions/Current/Resources "$fw/Resources"
    bin="$fw/Versions/A/$name"
  else
    mkdir -p "$fw/Headers"
    cp "$dylib" "$fw/$name"
    cp -R "$headers/." "$fw/Headers/"
    framework_plist "$name" "$version" "$platform" "$fw/Info.plist" "$minos"
    bin="$fw/$name"
  fi
  # 🔴 名乗りと依存を framework の形へ（⛔ 焼いた場所の絶対パスのままだと端末で見つからない）。
  install_name_tool -id "@rpath/$name.framework/$name" "$bin"
  local entry pattern target old
  for entry in $deps; do
    pattern="${entry%%:*}"
    target="${entry#*:}"
    old="$(otool -L "$bin" | awk 'NR>1 {print $1}' | grep -E "$pattern" || true)"
    [ -n "$old" ] && install_name_tool -change "$old" "@rpath/$target.framework/$target" "$bin"
  done
  # ⚠ install_name_tool で署名が壊れる ∴ 仮の署名をし直す（arm64 は署名の無い code を読まない）。配るときはアプリの署名で上書きされる。
  codesign -f -s - "$bin" 2>/dev/null
  # 🔴 中身が dylib であること —— ⛔ 静的な .a を framework の形に入れたものにしない。
  file "$bin" | grep -q "dynamically linked shared library" || { echo "⛔ $name が dylib でない: $(file "$bin")" >&2; return 1; }
  echo "$fw"
}
