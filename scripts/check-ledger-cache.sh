#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
run="$(mktemp -d "$PWD/tmp/ledger-cache-XXXXXX")"
trap 'rm -rf "$run"' EXIT
swiftc -swift-version 5 -parse-as-library Sources/PiDeskApp/UsageLedger.swift Tests/PiDeskAppTests/LedgerCacheChecks.swift -o "$run/LedgerCacheChecks"
"$run/LedgerCacheChecks" "$run/usage-v1"
