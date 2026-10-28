#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 1 ]; then
  echo "Pass the explicitly authorized usage-v1 metadata root (never a sessions/JSONL root)." >&2
  exit 2
fi
run="$(mktemp -d "$PWD/tmp/large-ledger-check-XXXXXX")"
swiftc -swift-version 5 -parse-as-library Sources/PiDeskApp/UsageLedger.swift Tests/PiDeskAppTests/LargeLedgerChecks.swift -o "$run/LargeLedgerChecks"
"$run/LargeLedgerChecks" "$1"
