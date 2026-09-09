#!/bin/sh
set -eu

release_version='0.6.0-preview.1'
short_version='0.6.0'
build_version='6001'
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

usage() {
	printf '%s\n' "usage: $0 /absolute/output-directory" >&2
	printf '%s\n' 'Builds LeanBrowser native preview artifacts for an Apple Silicon macOS 14+ host.' >&2
}

[ "$#" -eq 1 ] || { usage; exit 2; }
case "$1" in /*) requested_output_dir=$1 ;; *) printf '%s\n' 'output directory must be an absolute path' >&2; exit 2 ;; esac
case "$(uname -s):$(uname -m)" in Darwin:arm64) ;; *) printf '%s\n' 'native preview packaging requires an arm64 macOS host' >&2; exit 1 ;; esac
[ -d "$repo_root/skills/leanbrowser" ] || { printf '%s\n' 'missing skills/leanbrowser; prepare the portable skill before packaging' >&2; exit 1; }
[ -f "$repo_root/skills/leanbrowser/SKILL.md" ] || { printf '%s\n' 'missing skills/leanbrowser/SKILL.md' >&2; exit 1; }

output_parent=$(dirname -- "$requested_output_dir")
[ -d "$output_parent" ] || { printf 'output parent does not exist: %s\n' "$output_parent" >&2; exit 1; }
repo_root=$(cd "$repo_root" && pwd -P)
output_dir="$(cd "$output_parent" && pwd -P)/$(basename -- "$requested_output_dir")"
case "$output_dir" in "$repo_root"|"$repo_root"/*) printf '%s\n' 'output directory must be outside the repository' >&2; exit 1 ;; esac
mkdir -p "$output_dir"
for artifact in "LeanBrowser-$release_version-arm64.dmg" "LeanBrowser-$release_version-arm64.zip" "LeanBrowser-agent-kit-$release_version.zip" "LeanBrowser-skill-$release_version.zip" SHA256SUMS; do
	[ ! -e "$output_dir/$artifact" ] || { printf 'refusing to replace existing artifact: %s\n' "$output_dir/$artifact" >&2; exit 1; }
done

work=$(mktemp -d "${TMPDIR:-/tmp}/leanbrowser-release.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT HUP INT TERM
native_out="$work/native"
mkdir -p "$native_out"
"$script_dir/build-native.sh" "$native_out"
app="$native_out/LeanBrowser.app"
plutil -replace CFBundleShortVersionString -string "$short_version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_version" "$app/Contents/Info.plist"
cp "$repo_root/LICENSE" "$app/Contents/Resources/LICENSE"
cp "$repo_root/distribution/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --deep --strict "$app"

dmg_root="$work/dmg-root"
mkdir -p "$dmg_root"
ditto "$app" "$dmg_root/LeanBrowser.app"
ln -s /Applications "$dmg_root/Applications"
cp "$repo_root/distribution/README.md" "$dmg_root/README.md"
hdiutil create -quiet -volname "LeanBrowser $release_version" -srcfolder "$dmg_root" -format UDZO -ov "$output_dir/LeanBrowser-$release_version-arm64.dmg"

ditto -c -k --sequesterRsrc --keepParent "$app" "$output_dir/LeanBrowser-$release_version-arm64.zip"

kit_root="$work/LeanBrowser-agent-kit-$release_version"
mkdir -p "$kit_root/skills"
cp "$repo_root/scripts/native_agent.py" "$kit_root/native_agent.py"
cp "$repo_root/scripts/install-agent-kit.sh" "$kit_root/install-agent-kit.sh"
chmod 755 "$kit_root/install-agent-kit.sh"
ditto "$repo_root/skills/leanbrowser" "$kit_root/skills/leanbrowser"
cp "$repo_root/LICENSE" "$kit_root/LICENSE"
cp "$repo_root/distribution/README.md" "$kit_root/README.md"
(
	cd "$kit_root"
	find LICENSE README.md install-agent-kit.sh native_agent.py skills -type f -print | LC_ALL=C sort | xargs shasum -a 256 > .leanbrowser-agent-kit.sha256
)
ditto -c -k --sequesterRsrc --keepParent "$kit_root" "$output_dir/LeanBrowser-agent-kit-$release_version.zip"
skill_root="$work/LeanBrowser-skill-$release_version"
mkdir -p "$skill_root"
ditto "$repo_root/skills/leanbrowser" "$skill_root/leanbrowser"
cp "$repo_root/LICENSE" "$skill_root/LICENSE"
ditto -c -k --sequesterRsrc --keepParent "$skill_root" "$output_dir/LeanBrowser-skill-$release_version.zip"

(
	cd "$output_dir"
	shasum -a 256 "LeanBrowser-$release_version-arm64.dmg" "LeanBrowser-$release_version-arm64.zip" "LeanBrowser-agent-kit-$release_version.zip" "LeanBrowser-skill-$release_version.zip" > SHA256SUMS
)
printf 'Created release artifacts in %s\n' "$output_dir"
