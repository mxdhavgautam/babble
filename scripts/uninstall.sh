#!/bin/zsh
# Removes Babble and everything it created: the app (and with it the login item), settings,
# permissions, personal vocabulary and history.
# The signing identity is left in the keychain; delete it with:
#   security delete-identity -c "Babble Local Signing" ~/Library/Keychains/login.keychain-db
set -euo pipefail

pkill -x Babble || true
rm -rf "$HOME/Applications/Babble.app"
rm -rf "$HOME/Library/Application Support/Babble"
defaults delete dev.babble.app >/dev/null 2>&1 || true
tccutil reset All dev.babble.app >/dev/null 2>&1 || true
echo "Babble removed."
