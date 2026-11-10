#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p tmp/session-metrics-checks
run="$(mktemp -d "$PWD/tmp/session-metrics-checks/case-XXXXXX")"
swiftc -swift-version 5 -parse-as-library Sources/PiDeskApp/UsageLedger.swift Tests/PiDeskAppTests/SessionMetricsChecks.swift -o "$run/SessionMetricsChecks"
"$run/SessionMetricsChecks" "$run"
