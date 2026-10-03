#!/bin/zsh
# Builds Babble.app, signs it with the local identity, installs to ~/Applications and (re)launches it.
# Run scripts/make-signing-cert.sh once first so permissions survive rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${BABBLE_SIGN_IDENTITY:-Babble Local Signing}"
APP="build/Babble.app"
DEST="$HOME/Applications/Babble.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Babble "$APP/Contents/MacOS/Babble"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/vocabulary.txt "$APP/Contents/Resources/vocabulary.txt"
codesign --force --sign "$IDENTITY" "$APP"

pkill -x Babble || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed $DEST"
