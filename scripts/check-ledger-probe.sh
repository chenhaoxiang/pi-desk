#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
run="$(mktemp -d "$PWD/tmp/ledger-probe-XXXXXX")"
trap 'rm -rf "$run"' EXIT
swiftc -swift-version 5 -parse-as-library Sources/PiDeskApp/UsageLedger.swift Tests/PiDeskAppTests/LedgerProbe.swift -o "$run/LedgerProbe"
"$run/LedgerProbe" "$1"
