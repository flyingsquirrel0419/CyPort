#!/bin/bash
# The app signs the game program it converts (shim/MachOSign.swift, like build.sh's `codesign -f -s -`). Checks the
# result with the Mac's codesign. macOS only.   tools/test_sign.sh <arm64 Mach-O>...
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -gt 0 ] || { echo "usage: $0 <arm64 Mach-O>..."; exit 2; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
xcrun swiftc -sdk "$(xcrun --sdk macosx --show-sdk-path)" -O "$HERE/shim/MachORetarget.swift" "$HERE/shim/MachOSign.swift" \
  "$HERE/tools/sign_test/main.swift" -o "$T/sign-swift"
fail=0
for f in "$@"; do
  "$T/sign-swift" "$f" "$T/out" || { echo "FAIL $f: signing"; fail=1; continue; }
  if codesign --verify --strict -vvvv "$T/out" 2>&1; then
    codesign -d -vvv "$T/out" 2>&1 | grep -E 'Identifier|Format|CodeDirectory|Signature=|Hash' | sed 's/^/       /'
    echo "ok   $f"
  else echo "FAIL $f: codesign doesn't accept the signature"; fail=1; fi
done
exit $fail
