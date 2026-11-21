#!/bin/bash
set -e

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
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""

echo "--> Building for iOS Device..."
cmake --build "$OUTPUT_DIR/build-ios" --config Release --target zf_tajweed

# 2. Build for iOS Simulator (arm64)
echo "--> Configuring for iOS Simulator (arm64)..."
cmake -B "$OUTPUT_DIR/build-sim" \
  -S "$SDK_ROOT" \
  -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphonesimulator \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""

echo "--> Building for iOS Simulator..."
cmake --build "$OUTPUT_DIR/build-sim" --config Release --target zf_tajweed

# 3. Locate framework outputs
IOS_FW=$(find "$OUTPUT_DIR/build-ios" -name "zf_tajweed.framework" -type d | grep -E "Release-iphoneos|Release" | head -n 1)
SIM_FW=$(find "$OUTPUT_DIR/build-sim" -name "zf_tajweed.framework" -type d | grep -E "Release-iphonesimulator|Release" | head -n 1)

if [ -z "$IOS_FW" ] || [ -z "$SIM_FW" ]; then
  echo "Error: Could not locate built frameworks."
  echo "iOS Framework: $IOS_FW"
  echo "Simulator Framework: $SIM_FW"
  exit 1
fi

echo "Found iOS Framework: $IOS_FW"
echo "Found Simulator Framework: $SIM_FW"

# 4. Create XCFramework
XCFRAMEWORK_OUT="$OUTPUT_DIR/zf_tajweed.xcframework"
rm -rf "$XCFRAMEWORK_OUT"

echo "--> Creating XCFramework with xcodebuild..."
xcodebuild -create-xcframework \
  -framework "$IOS_FW" \
  -framework "$SIM_FW" \
  -output "$XCFRAMEWORK_OUT"

echo "=== Successfully built $XCFRAMEWORK_OUT ==="
