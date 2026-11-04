#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${1:-}" != "--skip-build" ]; then swift build --jobs 2 >/dev/null; fi
bin="$(swift build --show-bin-path)"
run="$(mktemp -d "$PWD/tmp/assistant-checks-XXXXXX")"
trap 'rm -rf "$run"' EXIT
swiftc -swift-version 5 -parse-as-library -module-name PiDeskAssistantChecks \
  -I "$bin/Modules" Sources/PiDeskApp/AppModel.swift Sources/PiDeskApp/AssistantClient.swift Sources/PiDeskApp/LocalAssistantTransport.swift Sources/PiDeskApp/UsageLedger.swift Sources/PiDeskApp/NotificationClient.swift Sources/PiDeskApp/PiSettingsStore.swift Sources/PiDeskApp/TerminalRouteActivator.swift Tests/PiDeskAppTests/AssistantChecks.swift \
  "$bin"/PiDeskCore.build/*.o "$bin"/PiDeskTransport.build/*.o -o "$run/AssistantChecks"
PI_DESK_TEST_NODE="$(command -v node)" "$run/AssistantChecks" --socket-path "$run/desk.sock" --settings-path "$run/settings.json" --usage-path "$run/usage-v1"
