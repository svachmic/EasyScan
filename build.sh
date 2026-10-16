#!/usr/bin/env bash
# Builds EasyScan.app from the SwiftPM package (no Xcode project needed).
#
#   ./build.sh                    release build -> build/EasyScan.app
#   ./build.sh --install --run    ...then copy to ~/Applications and launch it
#
# Options:
#   --install   copy the bundle to ~/Applications/EasyScan.app (replacing an existing copy)
#   --run       open the app after building (the installed copy when --install is given)
#   --debug     package the debug build instead of the release build
#   --icon      regenerate Packaging/AppIcon.icns even if it already exists
#   -h, --help  show this help
#
# Environment:
#   VERSION=1.2.0      overrides CFBundleShortVersionString (default: value in Packaging/Info.plist)
#   BUILD_NUMBER=42    overrides CFBundleVersion
set -euo pipefail

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$root"

app_name="EasyScan"
config="release"
install=0
run=0
force_icon=0

for arg in "$@"; do
    case "$arg" in
        --install) install=1 ;;
        --run)     run=1 ;;
        --debug)   config="debug" ;;
        --icon)    force_icon=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown option '$arg'" >&2; usage >&2; exit 2 ;;
    esac
done

packaging="$root/Packaging"
icns="$packaging/AppIcon.icns"
app="$root/build/$app_name.app"
install_dir="$HOME/Applications"
installed_app="$install_dir/$app_name.app"

if [[ -t 1 ]]; then bold=$'\033[1m' blue=$'\033[1;34m' red=$'\033[1;31m' reset=$'\033[0m'
else bold="" blue="" red="" reset=""; fi
step() { printf '%s==>%s %s%s%s\n' "$blue" "$reset" "$bold" "$*" "$reset"; }
note() { printf '    %s\n' "$*"; }
fail() { printf '%serror:%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

# Ask a running EasyScan to quit (never force-kill it: a scan may be in progress).
quit_running() {
    pgrep -x "$app_name" >/dev/null 2>&1 || return 0
    step "Quitting running $app_name"
    osascript -e "tell application \"$app_name\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
        pgrep -x "$app_name" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    fail "$app_name is still running (is a scan in progress?). Quit it and run ./build.sh again."
}

# 1. App icon --------------------------------------------------------------------------------------
if [[ $force_icon -eq 1 || ! -f "$icns" ]]; then
    step "Generating app icon"
    "$packaging/make-icns.sh"
fi

# 2. Compile ---------------------------------------------------------------------------------------
step "Building $app_name ($config)"
if ! swift build -c "$config"; then
    fail "swift build failed (see the compiler output above)."
fi

bin_dir="$(swift build -c "$config" --show-bin-path 2>/dev/null || true)"
binary="$bin_dir/$app_name"
[[ -x "$binary" ]] || binary="$root/.build/$config/$app_name"
[[ -x "$binary" ]] || fail "built executable not found (looked in '$bin_dir' and .build/$config)."
note "$binary"

# Make sure the freshly built app is the one that launches.
if [[ $install -eq 1 || $run -eq 1 ]]; then
    quit_running
elif pgrep -x "$app_name" >/dev/null 2>&1; then
    note "note: $app_name is running; relaunch it to pick up this build."
fi

# 3. Assemble the bundle ---------------------------------------------------------------------------
step "Assembling ${app#"$root"/}"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$binary" "$app/Contents/MacOS/$app_name"
cp "$packaging/Info.plist" "$app/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$app/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$app/Contents/Info.plist"
fi
plutil -lint -s "$app/Contents/Info.plist" || fail "Info.plist is invalid."
printf 'APPL????' > "$app/Contents/PkgInfo"
cp "$icns" "$app/Contents/Resources/AppIcon.icns"

# SwiftPM resource bundles (only present if the target ever declares resources).
shopt -s nullglob
for bundle in "$bin_dir"/"${app_name}"_*.bundle; do
    cp -R "$bundle" "$app/Contents/Resources/"
    note "resources: $(basename "$bundle")"
done
shopt -u nullglob

version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
build_number="$(plutil -extract CFBundleVersion raw "$app/Contents/Info.plist")"
note "version $version ($build_number), $(lipo -archs "$app/Contents/MacOS/$app_name")"

# 4. Sign ------------------------------------------------------------------------------------------
step "Signing (ad hoc)"
codesign --force --deep --sign - "$app"
codesign --verify --strict "$app" || fail "code signature verification failed."
note "signature OK"
touch "$app"   # nudge Finder/LaunchServices to refresh the icon

final="$app"

# 5. Install ---------------------------------------------------------------------------------------
if [[ $install -eq 1 ]]; then
    step "Installing to ${installed_app/#$HOME/~}"
    mkdir -p "$install_dir"
    staging="$install_dir/.$app_name.app.new"
    rm -rf "$staging"
    ditto "$app" "$staging"
    rm -rf "$installed_app"
    mv "$staging" "$installed_app"
    lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    [[ -x "$lsregister" ]] && "$lsregister" -f "$installed_app" >/dev/null 2>&1 || true
    final="$installed_app"
fi

# 6. Run -------------------------------------------------------------------------------------------
if [[ $run -eq 1 ]]; then
    step "Launching $app_name"
    open "$final"
fi

step "Done: $final"
