#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${1:-}" != "--skip-build" ]; then swift build --jobs 2; fi
bin="$(swift build --show-bin-path)"
mkdir -p tmp
run="$(mktemp -d "$PWD/tmp/draft-check-XXXXXX")"
trap 'rm -rf "$run"' EXIT
swiftc -swift-version 5 -parse-as-library -module-name PiDeskDraftChecks \
  -I "$bin/Modules" Sources/PiDeskApp/AppModel.swift Sources/PiDeskApp/UsageLedger.swift Sources/PiDeskApp/NotificationClient.swift Sources/PiDeskApp/PiSettingsStore.swift Sources/PiDeskApp/TerminalRouteActivator.swift Tests/PiDeskAppTests/DraftChecks.swift \
  "$bin"/PiDeskCore.build/*.o "$bin"/PiDeskTransport.build/*.o -o "$run/DraftChecks"
"$run/DraftChecks" --socket-path "$run/desk.sock" --settings-path "$run/settings.json"
