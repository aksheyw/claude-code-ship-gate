#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/assert.sh"; . "$DIR/../lib/detect.sh"
NODE=$(mktemp -d); echo '{}' > "$NODE/package.json"; : > "$NODE/pnpm-lock.yaml"
assert_eq "$(sg_detect_pm "$NODE")" "pnpm" "pnpm lockfile"
assert_contains "$(sg_detect_test_cmd "$NODE")" "pnpm" "node test uses pnpm"
GO=$(mktemp -d); : > "$GO/go.mod"
assert_eq "$(sg_detect_test_cmd "$GO")" "go test ./..." "go test"
assert_eq "$(sg_detect_build_cmd "$GO")" "go build ./..." "go build"
RUST=$(mktemp -d); : > "$RUST/Cargo.toml"
assert_eq "$(sg_detect_test_cmd "$RUST")" "cargo test" "cargo test"
VER=$(mktemp -d); : > "$VER/vercel.json"
assert_contains "$(sg_detect_deploy "$VER")" "Vercel" "deploy detect vercel"
assert_summary
