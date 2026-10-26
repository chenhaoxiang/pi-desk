#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --jobs 2 >/dev/null
bin="$(swift build --show-bin-path)"
run="$(mktemp -d "$PWD/tmp/narrow-ux-XXXXXX")"
trap 'rm -rf "$run"' EXIT
swiftc -swift-version 5 -parse-as-library -module-name PiDeskNarrowUX \
  -I "$bin/Modules" Sources/PiDeskApp/AppModel.swift Sources/PiDeskApp/UsageLedger.swift Sources/PiDeskApp/NotificationClient.swift Sources/PiDeskApp/PiSettingsStore.swift Sources/PiDeskApp/TerminalRouteActivator.swift Tests/PiDeskAppTests/NarrowUXChecks.swift \
  "$bin"/PiDeskCore.build/*.o "$bin"/PiDeskTransport.build/*.o -o "$run/NarrowUXChecks"
"$run/NarrowUXChecks" --socket-path "$run/desk.sock" --settings-path "$run/settings.json" --usage-path "$run/usage-v1"
