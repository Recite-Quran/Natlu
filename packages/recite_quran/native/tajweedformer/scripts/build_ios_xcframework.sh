#!/bin/bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$SDK_ROOT/build_xcframework}"

echo "=== Building zf_tajweed.xcframework ==="
echo "SDK Root: $SDK_ROOT"
echo "Output Directory: $OUTPUT_DIR"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# 1. Build for iOS Device (arm64)
echo "--> Configuring for iOS Device (arm64)..."
cmake -B "$OUTPUT_DIR/build-ios" \
  -S "$SDK_ROOT" \
  -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER=com.recitequran.zf-tajweed \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""

echo "--> Compiling for iOS Device (arm64)..."
cmake --build "$OUTPUT_DIR/build-ios" --config Release --target zf_tajweed -- -sdk iphoneos ONLY_ACTIVE_ARCH=NO

# Locate iOS Device framework (skip intermediate .build and EagerLinkingTBDs)
IOS_FW=$(find "$OUTPUT_DIR/build-ios" -name "zf_tajweed.framework" -type d | grep -v "EagerLinkingTBDs" | grep -v "/build/" | head -n 1)
if [ -z "$IOS_FW" ] || [ ! -f "$IOS_FW/zf_tajweed" ]; then
  echo "Error: iOS Device framework binary not found in $OUTPUT_DIR/build-ios"
  exit 1
fi
echo "Found iOS Device framework: $IOS_FW"

# Ensure CFBundleSupportedPlatforms for device
if [ -f "$IOS_FW/Info.plist" ]; then
  /usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms array" "$IOS_FW/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms:0 string iPhoneOS" "$IOS_FW/Info.plist" 2>/dev/null || true
fi

# 2. Build for iOS Simulator (arm64)
echo "--> Configuring for iOS Simulator (arm64)..."
cmake -B "$OUTPUT_DIR/build-sim" \
  -S "$SDK_ROOT" \
  -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphonesimulator \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER=com.recitequran.zf-tajweed \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""

echo "--> Compiling for iOS Simulator (arm64)..."
cmake --build "$OUTPUT_DIR/build-sim" --config Release --target zf_tajweed -- -sdk iphonesimulator ONLY_ACTIVE_ARCH=NO

# Locate iOS Simulator framework (skip intermediate .build and EagerLinkingTBDs)
SIM_FW=$(find "$OUTPUT_DIR/build-sim" -name "zf_tajweed.framework" -type d | grep -v "EagerLinkingTBDs" | grep -v "/build/" | head -n 1)
if [ -z "$SIM_FW" ] || [ ! -f "$SIM_FW/zf_tajweed" ]; then
  echo "Error: iOS Simulator framework binary not found in $OUTPUT_DIR/build-sim"
  exit 1
fi
echo "Found iOS Simulator framework: $SIM_FW"

# Ensure CFBundleSupportedPlatforms for simulator
if [ -f "$SIM_FW/Info.plist" ]; then
  /usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms array" "$SIM_FW/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms:0 string iPhoneSimulator" "$SIM_FW/Info.plist" 2>/dev/null || true
fi

# 3. Assemble XCFramework
XCFRAMEWORK_OUT="$OUTPUT_DIR/zf_tajweed.xcframework"
rm -rf "$XCFRAMEWORK_OUT"

echo "--> Creating XCFramework with xcodebuild..."
xcodebuild -create-xcframework \
  -framework "$IOS_FW" \
  -framework "$SIM_FW" \
  -output "$XCFRAMEWORK_OUT"

echo "=== Successfully built $XCFRAMEWORK_OUT ==="
