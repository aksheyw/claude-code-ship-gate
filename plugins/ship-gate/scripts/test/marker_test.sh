#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/assert.sh"; . "$DIR/../lib/marker.sh"
R=$(mktemp -d); cd "$R"; git init -q; git commit -q --allow-empty -m init
sg_marker_write "$R" "main" "false"
assert_eq "$(jq -r .branch "$R/.git/shipgate/last-pass.json")" "main" "marker branch written"
assert_eq "$(sg_marker_valid "$R" "main" 900; echo $?)" "0" "fresh marker valid"
jq '.ts=1' "$R/.git/shipgate/last-pass.json" > "$R/.git/shipgate/t" && mv "$R/.git/shipgate/t" "$R/.git/shipgate/last-pass.json"
assert_eq "$(sg_marker_valid "$R" "main" 900; echo $?)" "1" "expired marker invalid"
assert_summary
