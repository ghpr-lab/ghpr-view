#!/bin/bash
set -e

APP_NAME="PRDashboard"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DERIVED_DATA_PATH="$ROOT_DIR/build/DerivedData"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/$APP_NAME.app"

# Kill existing instance
pkill -x "$APP_NAME" 2>/dev/null || true

# Build into one deterministic location
xcodebuild -project "$ROOT_DIR/PRDashboard.xcodeproj" -scheme "$APP_NAME" \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA_PATH" build -quiet

# Open the app that was just built
open "$APP_PATH"
