#!/bin/bash
# dev.sh - Build PRDashboard with local signing for development
# This script overrides the project's ad-hoc signing with your local Apple Development certificate
# Requires: Apple ID configured in Xcode (Xcode → Settings → Accounts)

set -e

PROJECT="PRDashboard.xcodeproj"
SCHEME="PRDashboard"
# CONFIG="Debug"
CONFIG="Release"
BUILD_DIR="build/DerivedData"

# Your development team ID (from Xcode → Target → Signing & Capabilities)
# This will be used to sign the app locally
DEVELOPMENT_TEAM="WNF89D7V44"

echo "Building PRDashboard with local signing..."
echo "Team ID: $DEVELOPMENT_TEAM"
echo ""

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE="Automatic" \
    build

APP_PATH=$(find "$BUILD_DIR" -name "PRDashboard.app" -type d | head -1)

if [ -z "$APP_PATH" ]; then
    echo "Error: Could not find PRDashboard.app"
    exit 1
fi

echo ""
echo "Build succeeded: $APP_PATH"

# Verify signing
echo ""
echo "Code signing info:"
codesign -dv "$APP_PATH" 2>&1 | grep -E "TeamIdentifier|Signature"

# Install to ~/Applications
DEST_DIR="$HOME/Applications"
echo ""
echo "Installing to $DEST_DIR..."
mkdir -p "$DEST_DIR"
rm -rf "$DEST_DIR/PRDashboard.app"
cp -R "$APP_PATH" "$DEST_DIR/"
echo "Installed: $DEST_DIR/PRDashboard.app"

# Run if --run flag is passed
if [ "$1" = "--run" ]; then
    echo ""
    echo "Starting PRDashboard..."
    open "$DEST_DIR/PRDashboard.app"
fi
