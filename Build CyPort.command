#!/bin/bash
# Double-click me (right-click > Open the first time). Builds CyPort from your own copy of Cyberpunk 2077 for Mac:
# a GOG/Steam Cyberpunk2077.app on this Mac, or downloaded here from your Steam account.
cd "$(dirname "$0")"
if [ -z "${GAME_APP:-}" ] && [ -z "${STEAM_USER:-}" ]; then
  echo "Drag your Cyberpunk2077.app (from the 'Cyberpunk 2077' folder) into this window and press Return,"
  echo "or type your Steam account name to download the Mac version from Steam:"
  read -r IN; IN="${IN%/}"; IN="${IN//\\ / }"; IN="${IN%\'}"; IN="${IN#\'}"
  if [[ "$IN" == */* ]]; then GAME_APP="$IN"; else STEAM_USER="$IN"; fi
fi
export GAME_APP STEAM_USER
if ! xcode-select -p >/dev/null 2>&1; then echo "Xcode is required (install it from the App Store)"; read -r -p "Press Return to close"; exit 1; fi
# the Steam sign-in asks for a password / Steam Guard code: keep the terminal attached (no tee on stdin)
mkdir -p build; ./build.sh 2>&1 | tee build/build.log
echo; echo "Log: $(pwd)/build/build.log"; open build 2>/dev/null
read -r -p "Press Return to close"
