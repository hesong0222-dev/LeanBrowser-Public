#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

if [ "$#" -gt 1 ]; then
	printf '%s\n' 'usage: scripts/build-native.sh [output-directory]' >&2
	exit 2
fi

output_dir=${1:-"$repo_root/dist"}
bundle_id=${LEANBROWSER_BUNDLE_ID:-dev.leanbrowser.desktop}
case "$bundle_id" in
    *[!A-Za-z0-9.-]*|.*|*.|*..*|'') printf '%s\n' 'invalid bundle identifier' >&2; exit 2 ;;
esac
case "$output_dir" in
	/*) ;;
	*) output_dir="$repo_root/$output_dir" ;;
esac

case "$(uname -m)" in
	arm64) target_arch=arm64 ;;
	x86_64) target_arch=x86_64 ;;
	*) printf 'unsupported host architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

swiftc=$(xcrun --find swiftc)
sdk=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p "$output_dir"
build_work=$(mktemp -d "$output_dir/.leanbrowser-build.XXXXXX")
trap 'rm -rf "$build_work"' EXIT HUP INT TERM
app="$build_work/LeanBrowser.app"
executable="$app/Contents/MacOS/LeanBrowser"

set -- "$repo_root"/native/LeanBrowser/*.swift
if [ ! -f "$1" ]; then
	printf '%s\n' 'native/LeanBrowser contains no Swift sources' >&2
	exit 1
fi

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

"$swiftc" \
	-swift-version 5 \
	-target "${target_arch}-apple-macos14.0" \
	-sdk "$sdk" \
	-framework AppKit \
	-framework SwiftUI \
	-framework WebKit \
	-framework Security \
	-Osize \
	-whole-module-optimization \
	-emit-executable \
	-o "$executable" \
	"$@"

icon_work="$build_work"
mkdir -p "$icon_work/LeanBrowser.iconset"
"$swiftc" -swift-version 5 -sdk "$sdk" -Osize "$repo_root/native/make-icon.swift" -o "$icon_work/make-icon"
"$icon_work/make-icon" "$icon_work/LeanBrowser.iconset"
iconutil -c icns "$icon_work/LeanBrowser.iconset" -o "$app/Contents/Resources/LeanBrowser.icns"

cp "$repo_root/native/Info.plist" "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"
# Keep the previous working build until compilation, resources and signing pass.
if [ -e "$output_dir/LeanBrowser.app" ]; then
    mv "$output_dir/LeanBrowser.app" "$build_work/Previous.app"
fi
if ! mv "$app" "$output_dir/LeanBrowser.app"; then
    [ ! -e "$build_work/Previous.app" ] || mv "$build_work/Previous.app" "$output_dir/LeanBrowser.app"
    exit 1
fi
app="$output_dir/LeanBrowser.app"

printf 'Built %s\n' "$app"
printf 'Bundle identifier: %s\n' "$bundle_id"
