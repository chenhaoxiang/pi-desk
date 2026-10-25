#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --jobs 2
swift run --skip-build PiDeskCoreTests
swift run --skip-build PiDeskTransportTests
bash scripts/check-draft.sh --skip-build
bash scripts/check-usage.sh
bash scripts/check-narrow-ux.sh
