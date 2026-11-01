#!/usr/bin/env bash
# libsmb2（NAS の SMB に繋ぐ・LGPL 2.1+）を、決めた版で取ってくる。手元（Linux）と CI（macOS）の両方の焼くスクリプトが使う。
#
# 🔴 版は固定し、tag が指す commit を照合する —— ⛔ GitHub の tarball は作り直されて sha256 が変わることがある ∴ commit で縛る。
#    ⚠ 版を上げるときは TAG と COMMIT を一緒に変え、NAS の試験（tools/test_ios_media_linux.sh・CI）を回す。
# 使い方: SRC=$(bash tools/fetch_libsmb2.sh <置き場>)   —— 取った source の在り処を 1 行で返す
set -euo pipefail

TAG=libsmb2-6.3
COMMIT=2bcb014b23a8c8cccf534eea8bda2fe5df453cfd

WORK="${1:?置き場を渡す}"
SRC="$WORK/libsmb2-$TAG"
if [ ! -d "$SRC/.git" ]; then
  rm -rf "$SRC"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$TAG" https://github.com/sahlberg/libsmb2.git "$SRC" >&2
fi
got="$(git -C "$SRC" rev-parse HEAD)"
[ "$got" = "$COMMIT" ] || { echo "⛔ libsmb2 の $TAG が $COMMIT ではなく $got を指している" >&2; exit 1; }
echo "$SRC"
