#!/usr/bin/env bash
set -euo pipefail

# 可从任意目录运行，发布配置从 podspec 中读取。
TOS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOS_SPEC="$TOS_ROOT/VeTOSiOSSDK.podspec"
TOS_PROJECT="$TOS_ROOT/VeTOSiOSSDK/VeTOSiOSSDK.xcodeproj"
TOS_OUTPUT="$TOS_ROOT/Frameworks/VeTOSiOSSDK.xcframework"
TOS_BUILD_PARENT="$TOS_ROOT/build/xcframework"

if [[ -e "$TOS_OUTPUT" ]]; then
  printf 'Output already exists: %s\nMove or remove it before rebuilding.\n' "$TOS_OUTPUT" >&2
  exit 1
fi

for TOS_TOOL in pod xcodebuild xcrun plutil git; do
  if ! command -v "$TOS_TOOL" >/dev/null 2>&1; then
    printf 'Required tool not found: %s\n' "$TOS_TOOL" >&2
    exit 1
  fi
done

mkdir -p "$TOS_BUILD_PARENT"
TOS_BUILD_DIR="$(mktemp -d "$TOS_BUILD_PARENT/run.XXXXXX")"
pod ipc spec "$TOS_SPEC" > "$TOS_BUILD_DIR/spec.json"
TOS_VERSION="$(plutil -extract version raw -o - "$TOS_BUILD_DIR/spec.json")"
TOS_IOS_VERSION="$(plutil -extract platforms.ios raw -o - "$TOS_BUILD_DIR/spec.json")"
# CFBundleShortVersionString 使用上游的纯数字版本号；
# podspec 和 BUILD_INFO 记录完整的 TimeHut 发布版本号。
TOS_MARKETING_VERSION="${TOS_VERSION%%-*}"

tos_archive() {
  local TOS_PLATFORM="$1"
  local TOS_DESTINATION="$2"
  local TOS_ARCHITECTURES="$3"
  local TOS_LOG="$TOS_BUILD_DIR/$TOS_PLATFORM.log"
  printf 'Archiving %s for iOS %s (%s)...\n' "$TOS_PLATFORM" "$TOS_IOS_VERSION" "$TOS_ARCHITECTURES"
  if ! xcodebuild archive \
    -project "$TOS_PROJECT" -scheme VeTOSiOSSDK \
    -configuration Release -destination "$TOS_DESTINATION" \
    -archivePath "$TOS_BUILD_DIR/$TOS_PLATFORM.xcarchive" \
    -derivedDataPath "$TOS_BUILD_DIR/$TOS_PLATFORM-derived" \
    SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO \
    "ARCHS=$TOS_ARCHITECTURES" \
    "IPHONEOS_DEPLOYMENT_TARGET=$TOS_IOS_VERSION" \
    "MARKETING_VERSION=$TOS_MARKETING_VERSION" \
    > "$TOS_LOG" 2>&1; then
    tail -n 60 "$TOS_LOG" >&2
    printf 'Archive failed. Full log: %s\n' "$TOS_LOG" >&2
    exit 1
  fi
}

tos_archive device 'generic/platform=iOS' arm64
tos_archive simulator 'generic/platform=iOS Simulator' 'arm64 x86_64'

if ! xcodebuild -create-xcframework \
  -framework "$TOS_BUILD_DIR/device.xcarchive/Products/Library/Frameworks/VeTOSiOSSDK.framework" \
  -framework "$TOS_BUILD_DIR/simulator.xcarchive/Products/Library/Frameworks/VeTOSiOSSDK.framework" \
  -output "$TOS_BUILD_DIR/VeTOSiOSSDK.xcframework" \
  > "$TOS_BUILD_DIR/create-xcframework.log" 2>&1; then
  cat "$TOS_BUILD_DIR/create-xcframework.log" >&2
  exit 1
fi

# 真机和模拟器均归档成功后，再将产物移动到发布目录。
mkdir -p "$TOS_ROOT/Frameworks"
mv "$TOS_BUILD_DIR/VeTOSiOSSDK.xcframework" "$TOS_OUTPUT"
{
  printf 'Pod version: %s\n' "$TOS_VERSION"
  printf 'Minimum iOS version: %s\n' "$TOS_IOS_VERSION"
  printf 'Source commit: %s\n' "$(git -C "$TOS_ROOT" rev-parse HEAD)"
  printf 'TOSConstants.m SHA-256: '
  shasum -a 256 "$TOS_ROOT/VeTOSiOSSDK/VeTOSiOSSDK/Utility/TOSConstants.m"
  xcodebuild -version
  printf 'Device architectures: '
  xcrun lipo -archs "$TOS_OUTPUT/ios-arm64/VeTOSiOSSDK.framework/VeTOSiOSSDK"
  printf 'Simulator architectures: '
  xcrun lipo -archs "$TOS_OUTPUT/ios-arm64_x86_64-simulator/VeTOSiOSSDK.framework/VeTOSiOSSDK"
} > "$TOS_ROOT/Frameworks/BUILD_INFO.txt"

printf 'Created %s\nBuild logs: %s\n' "$TOS_OUTPUT" "$TOS_BUILD_DIR"
