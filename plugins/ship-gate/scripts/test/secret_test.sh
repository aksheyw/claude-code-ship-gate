#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/assert.sh"
SCAN="$DIR/../secret-scan.sh"
KEY="sk-or-v1-$(printf 'a%.0s' {1..40})"
assert_eq "$(printf '+const k="%s"' "$KEY" | bash "$SCAN" --stdin >/dev/null 2>&1; echo $?)" "1" "openrouter key => exit 1"
assert_eq "$(printf '+const x = 2' | bash "$SCAN" --stdin >/dev/null 2>&1; echo $?)" "0" "clean line => exit 0"
assert_eq "$(printf '+-----BEGIN RSA PRIVATE KEY-----' | bash "$SCAN" --stdin >/dev/null 2>&1; echo $?)" "1" "private key => exit 1"
ERR=$(printf '+const x = 2' | bash "$SCAN" --stdin 2>&1 >/dev/null)
assert_eq "$ERR" "" "no stderr noise on clean scan (grep -- fix)"
assert_summary
