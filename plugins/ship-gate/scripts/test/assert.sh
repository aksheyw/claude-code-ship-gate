#!/usr/bin/env bash
# Minimal dependency-free assert harness.
# Hermetic git identity: tests commit in throwaway repos and must not depend on the runner's
# git config (CI runners have none, and git's hostname auto-detect hard-fails on a "(none)"
# domain). Env identity overrides config lookup everywhere, so every test commits cleanly.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ASSERT_PASS=0; ASSERT_FAIL=0
assert_eq(){ if [ "$1" = "$2" ]; then ASSERT_PASS=$((ASSERT_PASS+1)); else ASSERT_FAIL=$((ASSERT_FAIL+1)); echo "FAIL: $3 (expected '$2', got '$1')"; fi; }
assert_contains(){ case "$1" in *"$2"*) ASSERT_PASS=$((ASSERT_PASS+1));; *) ASSERT_FAIL=$((ASSERT_FAIL+1)); echo "FAIL: $3 (got '$1' lacks '$2')";; esac; }
assert_summary(){ echo "PASS=$ASSERT_PASS FAIL=$ASSERT_FAIL"; [ "$ASSERT_FAIL" -eq 0 ]; }
