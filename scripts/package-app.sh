#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in release|debug) ;; *) echo "Use release or debug" >&2; exit 2;; esac
swift build -c "$configuration" --jobs 2
bin="$(swift build -c "$configuration" --show-bin-path)"
mkdir -p "$PWD/tmp/candidate"
stage="$(mktemp -d "$PWD/tmp/package-XXXXXX")"
app="$stage/Pi Desk.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bin/PiDesk" "$app/Contents/MacOS/PiDesk"
cp "$bin/PiDeskPeerCheck" "$app/Contents/Helpers/PiDeskPeerCheck"
/usr/libexec/PlistBuddy -c 'Clear dict' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string io.github.chenhaoxiang.pi-desk' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleName string Pi Desk' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Pi Desk' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string PiDesk' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 0.1.0' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 14.0' "$app/Contents/Info.plist"
node scripts/bundle-metadata.mjs "$app" "$configuration"
/usr/bin/codesign --force --sign - "$app/Contents/Helpers/PiDeskPeerCheck"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict --deep "$app"
candidate="$PWD/tmp/candidate/Pi Desk.app"
if [ -e "$candidate" ]; then
  previous="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist")"
  case "$previous" in io.github.chenhaoxiang.pi-desk|io.github.chenhaoxiang.pi-desk.candidate) ;; *) echo "Unknown candidate: preserved" >&2; exit 1;; esac
  mv "$candidate" "$stage/previous.app"
fi
mv "$app" "$candidate"
printf '%s\n' "$candidate"
# Ad-hoc local build only. Stable installation is an explicit separate command.
