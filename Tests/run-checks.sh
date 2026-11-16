#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_directory=$(mktemp -d "${TMPDIR:-/tmp}/diary-checks.XXXXXX")
trap 'rm -rf "$check_directory"' EXIT
sources=()
while IFS= read -r source; do
    sources+=("$source")
done < <(rg --files Diary -g '*.swift' -g '!DiaryApp.swift')
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos15.0" \
    "${sources[@]}" Tests/RegressionChecks.swift -o "$check_directory/regression-checks"
"$check_directory/regression-checks"
