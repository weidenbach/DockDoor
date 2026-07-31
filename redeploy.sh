#!/bin/bash

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$SCRIPT_DIR"
DERIVED_DATA_PATH="${HOME}/Library/Developer/Xcode/DerivedData"

echo "🔨 Building DockDoor..."
cd "$PROJECT_DIR"
xcodebuild -project DockDoor.xcodeproj -scheme DockDoor -configuration Debug build \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO > /dev/null 2>&1

# Find the built app (most recent)
BUILT_APP=$(find "$DERIVED_DATA_PATH" -name "DockDoor.app" -type d 2>/dev/null | sort -r | head -1)

if [ -z "$BUILT_APP" ]; then
    echo "❌ Failed to find built DockDoor.app"
    exit 1
fi

echo "✅ Build complete: $BUILT_APP"

echo "📦 Moving to /Applications..."

# Try without sudo first
if rm -rf /Applications/DockDoor.app 2>/dev/null && cp -r "$BUILT_APP" /Applications/DockDoor.app 2>/dev/null; then
    :
else
    # If that fails, try with sudo (using cached password)
    sudo -n rm -rf /Applications/DockDoor.app 2>/dev/null || sudo rm -rf /Applications/DockDoor.app
    sudo -n cp -r "$BUILT_APP" /Applications/DockDoor.app 2>/dev/null || sudo cp -r "$BUILT_APP" /Applications/DockDoor.app
    sudo -n chown -R $(whoami):admin /Applications/DockDoor.app 2>/dev/null || sudo chown -R $(whoami):admin /Applications/DockDoor.app
fi

echo "🔄 Restarting DockDoor..."
killall DockDoor 2>/dev/null || true
sleep 1
open /Applications/DockDoor.app

echo "✨ DockDoor redeployed and restarted!"
