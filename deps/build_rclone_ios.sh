#!/usr/bin/env bash
set -euo pipefail

GO_TAGS="${GO_TAGS-ts_omit_logtail,ts_omit_portmapper}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/deps/rclone-mobile"
OUT="$ROOT/deps/frameworks"
BUILD="$ROOT/deps/build/rclone"

command -v go >/dev/null || { echo "error: go toolchain not found" >&2; exit 1; }

mkdir -p "$BUILD" "$OUT"
cd "$SRC"

# Pin Go dependency to fix build failure
go get github.com/go-json-experiment/json@v0.0.0-20231103231146-083d372dc545
go mod tidy

build_slice() {
  local sdk="$1" minflag="$2" tag="$3"
  echo "==> $tag"
  CC="$(xcrun --sdk "$sdk" -f clang) -isysroot $(xcrun --sdk "$sdk" --show-sdk-path) $minflag -arch arm64" \
  CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
    go build -buildmode=c-archive -trimpath -ldflags="-s -w" ${GO_TAGS:+-tags "$GO_TAGS"} \
      -o "$BUILD/$tag/librclone.a" ./librclone
}

echo "==> $(go version) tags='${GO_TAGS}'"

build_slice iphoneos          "-miphoneos-version-min=16.0"        device
build_slice iphonesimulator   "-mios-simulator-version-min=16.0"   simulator

for t in device simulator; do
  mkdir -p "$BUILD/$t/include"
  mv "$BUILD/$t/librclone.h" "$BUILD/$t/include/" 2>/dev/null || true
done

rm -rf "$OUT/Rclone.xcframework"
xcodebuild -create-xcframework \
  -library "$BUILD/device/librclone.a"    -headers "$BUILD/device/include" \
  -library "$BUILD/simulator/librclone.a" -headers "$BUILD/simulator/include" \
  -output "$OUT/Rclone.xcframework" >/dev/null
