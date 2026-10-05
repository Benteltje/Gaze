#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/gaze-admin-prompt-tests.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
xcrun swiftc -parse-as-library -warnings-as-errors \
	"$ROOT/Sources/Security/AdminPromptRules.swift" \
	"$ROOT/Tests/AdminPrompt/AdminPromptRulesTests.swift" \
	-o "$BUILD/admin-prompt-tests"
"$BUILD/admin-prompt-tests"
