#!/usr/bin/env bash
sg_log(){ local k="$1"; shift; case "$k" in pass) printf '[PASS] %s\n' "$*";; fail) printf '[FAIL] %s\n' "$*";; run) printf '[RUN]  %s\n' "$*";; skip) printf '[SKIP] %s\n' "$*";; warn) printf '[WARN] %s\n' "$*";; *) printf '%s\n' "$*";; esac; }
