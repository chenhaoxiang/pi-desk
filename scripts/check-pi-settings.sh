#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
run="$(mktemp -d "$PWD/tmp/pi-settings-XXXXXX")"
trap 'rm -rf "$run"' EXIT
swiftc -swift-version 5 -parse-as-library Sources/PiDeskApp/PiSettingsStore.swift Tests/PiDeskAppTests/PiSettingsStoreChecks.swift -o "$run/PiSettingsStoreChecks"
"$run/PiSettingsStoreChecks" "$run/fixture"
