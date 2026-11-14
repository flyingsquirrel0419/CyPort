#!/bin/bash
# Download Cyberpunk 2077 for Mac (arm64) from your own Steam account. Builds the downloader first (Mac, Xcode or the
# command line tools), from the same Steam client the app uses (shim/StoresCore.swift).
#
#   tools/steam_download.sh --user <steam account> [--out <folder>] [--all]      (--help for everything)
#
# Prints the path of the downloaded Cyberpunk2077.app on stdout (build.sh uses it as GAME_APP).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
B="${CYPORT_TOOL_DIR:-$HERE/build/.steam-tool}"
BIN="$B/cyport-steam"
SRC=("$HERE/shim/StoresCore.swift" "$HERE/tools/steam_download/SteamDownload.swift" "$HERE/tools/steam_download/log.c"
     "$HERE/shim/StoreCodecs.c" "$HERE/shim/third_party/lzma/LzmaDec.c")
[ "$(uname)" = "Darwin" ] || { echo "the Steam downloader runs on a Mac (it uses CommonCrypto/Security)" >&2; exit 1; }

stale=0; [ -x "$BIN" ] || stale=1
for s in "${SRC[@]}"; do if [ "$s" -nt "$BIN" ]; then stale=1; fi; done
if [ "$stale" = 1 ]; then
  echo "==> building the Steam downloader ($BIN)" >&2
  mkdir -p "$B"
  ARCH="$(uname -m)"; TARGET="$ARCH-apple-macos12.0"
  SDK="$(xcrun --sdk macosx --show-sdk-path)"
  for c in "$HERE/shim/StoreCodecs.c" "$HERE/shim/third_party/lzma/LzmaDec.c" "$HERE/tools/steam_download/log.c"; do
    xcrun clang -target "$TARGET" -isysroot "$SDK" -O2 -c "$c" -o "$B/$(basename "${c%.c}").o"
  done
  xcrun swiftc -target "$TARGET" -sdk "$SDK" -O -parse-as-library -module-name CyPortSteam \
    "$HERE/shim/StoresCore.swift" "$HERE/tools/steam_download/SteamDownload.swift" \
    "$B/StoreCodecs.o" "$B/LzmaDec.o" "$B/log.o" -lz -o "$BIN"
fi
exec "$BIN" "$@"
