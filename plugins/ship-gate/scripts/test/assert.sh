#!/usr/bin/env bash
# Minimal dependency-free assert harness.
ASSERT_PASS=0; ASSERT_FAIL=0
assert_eq(){ if [ "$1" = "$2" ]; then ASSERT_PASS=$((ASSERT_PASS+1)); else ASSERT_FAIL=$((ASSERT_FAIL+1)); echo "FAIL: $3 (expected '$2', got '$1')"; fi; }
assert_contains(){ case "$1" in *"$2"*) ASSERT_PASS=$((ASSERT_PASS+1));; *) ASSERT_FAIL=$((ASSERT_FAIL+1)); echo "FAIL: $3 (got '$1' lacks '$2')";; esac; }
assert_summary(){ echo "PASS=$ASSERT_PASS FAIL=$ASSERT_FAIL"; [ "$ASSERT_FAIL" -eq 0 ]; }
