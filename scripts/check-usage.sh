#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p tmp/usage-native
run="$(mktemp -d "$PWD/tmp/usage-native/case-XXXXXX")"
swiftc -swift-version 5 -parse-as-library Sources/PiDeskApp/UsageLedger.swift Tests/PiDeskAppTests/UsageChecks.swift -o "$run/UsageChecks"
"$run/UsageChecks" "$run"
