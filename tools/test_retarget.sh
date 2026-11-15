#!/bin/bash
# The app's on-device retargeting (shim/MachORetarget.swift) must write exactly what tools/ios_retarget.py --game-folder
# writes. Runs both on every arm64 Mach-O given and compares output bytes and log lines (Mac or Linux with swiftc).
#   tools/test_retarget.sh <Cyberpunk2077.app>/Contents/MacOS/Cyberpunk2077 <Cyberpunk2077.app>/Contents/Frameworks/*.dylib
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -gt 0 ] || { echo "usage: $0 <arm64 Mach-O>..."; exit 2; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
SWIFTC="$(xcrun -f swiftc 2>/dev/null || command -v swiftc)"
SDKARG=(); [ "$(uname)" = Darwin ] && SDKARG=(-sdk "$(xcrun --sdk macosx --show-sdk-path)")
"$SWIFTC" "${SDKARG[@]}" -O "$HERE/shim/MachORetarget.swift" "$HERE/tools/retarget_test/main.swift" -o "$T/retarget-swift"
fail=0
for f in "$@"; do
  py="$(python3 "$HERE/tools/ios_retarget.py" --game-folder "$f" "$T/py.out" 2>&1)" || { echo "SKIP $f (python: $py)"; continue; }
  sw="$("$T/retarget-swift" "$f" "$T/sw.out" 2>&1)" || { echo "FAIL $f (swift: $sw)"; fail=1; continue; }
  if ! cmp -s "$T/py.out" "$T/sw.out"; then echo "FAIL $f: output bytes differ"; cmp "$T/py.out" "$T/sw.out" | head -3; fail=1
  elif [ "$py" != "$sw" ]; then echo "FAIL $f: log differs"; diff <(echo "$py") <(echo "$sw") | head -10; fail=1
  else echo "ok   $f"; echo "$sw" | sed 's/^/       /'; fi
done
exit $fail
