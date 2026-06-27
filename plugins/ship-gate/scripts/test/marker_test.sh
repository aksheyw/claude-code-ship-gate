#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"; . "$DIR/assert.sh"; . "$DIR/../lib/marker.sh"
# Create "main" explicitly: the marker now keys on a NAMED branch ref (rev-parse "$branch"), so the test's
# branch must exist regardless of the host's init.defaultBranch (was branch-agnostic when it keyed on HEAD).
R=$(mktemp -d); cd "$R"; git init -q && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m init && git branch -M main
sg_marker_write "$R" "main" "false"
assert_eq "$(jq -r .branch "$R/.git/shipgate/last-pass.json")" "main" "marker branch written"
assert_eq "$(sg_marker_valid "$R" "main" 900; echo $?)" "0" "fresh marker valid"
jq '.ts=1' "$R/.git/shipgate/last-pass.json" > "$R/.git/shipgate/t" && mv "$R/.git/shipgate/t" "$R/.git/shipgate/last-pass.json"
assert_eq "$(sg_marker_valid "$R" "main" 900; echo $?)" "1" "expired marker invalid"
assert_summary
