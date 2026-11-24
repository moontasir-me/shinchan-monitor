#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$(mktemp -d /tmp/tintin-tests.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -module-cache-path "${TINTIN_MODULE_CACHE:-$TEST_DIR/module-cache}" \
  "$SCRIPT_DIR/AlertEngine.swift" "$SCRIPT_DIR/AlertEngineTests.swift" -o "$TEST_DIR/alert-tests"
"$TEST_DIR/alert-tests"

xcrun swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -module-cache-path "${TINTIN_MODULE_CACHE:-$TEST_DIR/module-cache}" \
  "$SCRIPT_DIR/ResourceValues.swift" "$SCRIPT_DIR/ResourceValuesTests.swift" -o "$TEST_DIR/resource-tests"
"$TEST_DIR/resource-tests"
