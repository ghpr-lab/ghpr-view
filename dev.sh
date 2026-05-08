#!/bin/bash
# dev.sh - Build PRDashboard with local signing for development.
# This script overrides the project's ad-hoc signing with your local Apple Development certificate.
# Requires: Apple ID configured in Xcode (Xcode -> Settings -> Accounts).

set -euo pipefail

PROJECT="PRDashboard.xcodeproj"
SCHEME="PRDashboard"
# CONFIG="Debug"
CONFIG="Release"
BUILD_DIR="build/DerivedData"
BASE_PRODUCT_NAME="PRDashboard"
BASE_BUNDLE_ID="com.xiaocang.PRDashboard"

# Your development team ID (from Xcode -> Target -> Signing & Capabilities).
# This will be used to sign the app locally.
DEVELOPMENT_TEAM="WNF89D7V44"

RUN_APP=false
RAW_TAG=""

usage() {
    cat <<EOF
Usage: $0 [--run] [--tag TAG]

Options:
  --run          Start the app after installing.
  --tag TAG      Build a tagged dev app, e.g. --tag feature/foo.
                 The tag is folded into the app name, bundle id, and signing identifier.
EOF
}

sanitize_tag() {
    local value="$1"
    value=$(printf "%s" "$value" | tr '[:upper:]' '[:lower:]')
    value=$(printf "%s" "$value" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
    printf "%s" "$value"
}

escape_regex() {
    printf "%s" "$1" | sed -E 's/[][\\.^$*+?{}|()]/\\&/g'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --run)
            RUN_APP=true
            shift
            ;;
        --tag)
            if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                echo "Error: --tag requires a non-empty value" >&2
                exit 1
            fi
            RAW_TAG="$2"
            shift 2
            ;;
        --tag=*)
            RAW_TAG="${1#--tag=}"
            if [ -z "$RAW_TAG" ]; then
                echo "Error: --tag requires a non-empty value" >&2
                exit 1
            fi
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

TAG=$(sanitize_tag "$RAW_TAG")
if [ -n "$RAW_TAG" ] && [ -z "$TAG" ]; then
    echo "Error: --tag value '$RAW_TAG' does not contain any usable characters" >&2
    exit 1
fi

if [ -n "$TAG" ]; then
    PRODUCT_NAME="${BASE_PRODUCT_NAME}-${TAG}"
    BUNDLE_ID="${BASE_BUNDLE_ID}.${TAG}"
else
    PRODUCT_NAME="$BASE_PRODUCT_NAME"
    BUNDLE_ID="$BASE_BUNDLE_ID"
fi

INSTALL_PATH="/Applications/${PRODUCT_NAME}.app"
APP_EXECUTABLE_PATH="${INSTALL_PATH}/Contents/MacOS/${PRODUCT_NAME}"
APP_EXECUTABLE_PATTERN=$(escape_regex "$APP_EXECUTABLE_PATH")

existing_pids() {
    {
        pgrep -x "$PRODUCT_NAME" 2>/dev/null || true
        pgrep -f "$APP_EXECUTABLE_PATTERN" 2>/dev/null || true
    } | sort -u
}

stop_existing_instance() {
    local pids="$1"
    [ -z "$pids" ] && return

    echo "Stopping existing ${PRODUCT_NAME} instance(s): $(echo "$pids" | tr '\n' ' ')"
    pkill -x "$PRODUCT_NAME" 2>/dev/null || true
    pkill -f "$APP_EXECUTABLE_PATTERN" 2>/dev/null || true

    for _ in {1..20}; do
        if [ -z "$(existing_pids)" ]; then
            return
        fi
        sleep 0.2
    done

    echo "Force stopping remaining ${PRODUCT_NAME} instance(s)..."
    pkill -9 -x "$PRODUCT_NAME" 2>/dev/null || true
    pkill -9 -f "$APP_EXECUTABLE_PATTERN" 2>/dev/null || true
}

echo "Building ${PRODUCT_NAME} with local signing..."
echo "Team ID: $DEVELOPMENT_TEAM"
echo "Bundle ID: $BUNDLE_ID"
if [ -n "$TAG" ]; then
    echo "Tag: $TAG"
fi
echo ""

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$BUILD_DIR" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_STYLE="Automatic" \
    PRODUCT_NAME="$PRODUCT_NAME" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    build

APP_PATH=""
PRODUCTS_DIR="$BUILD_DIR/Build/Products/$CONFIG"
if [ -d "$PRODUCTS_DIR" ]; then
    APP_PATH=$(find "$PRODUCTS_DIR" -maxdepth 1 -name "${PRODUCT_NAME}.app" -type d | head -1)
fi
if [ -z "$APP_PATH" ]; then
    APP_PATH=$(find "$BUILD_DIR" -name "${PRODUCT_NAME}.app" -type d | head -1)
fi

if [ -z "$APP_PATH" ]; then
    echo "Error: Could not find ${PRODUCT_NAME}.app"
    exit 1
fi

echo ""
echo "Build succeeded: $APP_PATH"

# Verify signing.
echo ""
echo "Code signing info:"
codesign -dv "$APP_PATH" 2>&1 | grep -E "Identifier|TeamIdentifier|Authority|Signature" || true

EXISTING_PIDS=$(existing_pids)
WAS_RUNNING=false
if [ -n "$EXISTING_PIDS" ]; then
    WAS_RUNNING=true
    stop_existing_instance "$EXISTING_PIDS"
fi

# Install to /Applications with a tag-specific bundle name.
echo ""
echo "Installing to $INSTALL_PATH..."
rm -rf "$INSTALL_PATH"
cp -R "$APP_PATH" "$INSTALL_PATH"
echo "Installed: $INSTALL_PATH"

if [ "$RUN_APP" = true ] || [ "$WAS_RUNNING" = true ]; then
    echo ""
    echo "Starting ${PRODUCT_NAME}..."
    open "$INSTALL_PATH"
fi
