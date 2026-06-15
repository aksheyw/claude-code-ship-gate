#!/usr/bin/env bash
sg_detect_pm(){ local d="$1"; [ -f "$d/pnpm-lock.yaml" ] && { printf '%s\n' pnpm; return; }; [ -f "$d/yarn.lock" ] && { printf '%s\n' yarn; return; }; [ -f "$d/bun.lockb" ] && { printf '%s\n' bun; return; }; printf '%s\n' npm; }
sg_detect_test_cmd(){ local d="$1"
  [ -f "$d/package.json" ] && { printf '%s\n' "$(sg_detect_pm "$d") test"; return; }
  [ -f "$d/go.mod" ] && { printf '%s\n' "go test ./..."; return; }
  [ -f "$d/Cargo.toml" ] && { printf '%s\n' "cargo test"; return; }
  { [ -f "$d/pyproject.toml" ] || ls "$d"/requirements*.txt >/dev/null 2>&1; } && { printf '%s\n' "pytest"; return; }
  [ -f "$d/pubspec.yaml" ] && { printf '%s\n' "flutter test"; return; }
  { [ -f "$d/pom.xml" ]; } && { printf '%s\n' "mvn test"; return; }
  ls "$d"/build.gradle* >/dev/null 2>&1 && { printf '%s\n' "gradle test"; return; }
  printf '%s\n' ""; }
sg_detect_build_cmd(){ local d="$1"
  [ -f "$d/package.json" ] && { printf '%s\n' "$(sg_detect_pm "$d") run build"; return; }
  [ -f "$d/go.mod" ] && { printf '%s\n' "go build ./..."; return; }
  [ -f "$d/Cargo.toml" ] && { printf '%s\n' "cargo build"; return; }
  printf '%s\n' ""; }
sg_detect_lint_cmd(){ local d="$1"
  [ -f "$d/package.json" ] && { printf '%s\n' "npx eslint ."; return; }
  [ -f "$d/Cargo.toml" ] && { printf '%s\n' "cargo clippy"; return; }
  [ -f "$d/go.mod" ] && { printf '%s\n' "go vet ./..."; return; }
  { [ -f "$d/pyproject.toml" ]; } && { printf '%s\n' "ruff check ."; return; }
  printf '%s\n' ""; }
sg_detect_typecheck_cmd(){ local d="$1"
  # first marker wins; TypeScript typecheck requires tsconfig.json, else falls through (e.g. Python mypy)
  [ -f "$d/tsconfig.json" ] && { printf '%s\n' "npx tsc --noEmit"; return; }
  { [ -f "$d/pyproject.toml" ]; } && { printf '%s\n' "mypy ."; return; }
  printf '%s\n' ""; }
sg_detect_deploy(){ local d="$1"
  { [ -f "$d/vercel.json" ] || [ -d "$d/.vercel" ]; } && { printf '%s\n' "Vercel"; return; }
  [ -f "$d/netlify.toml" ] && { printf '%s\n' "Netlify"; return; }
  [ -f "$d/fly.toml" ] && { printf '%s\n' "Fly.io"; return; }
  [ -f "$d/render.yaml" ] && { printf '%s\n' "Render"; return; }
  [ -f "$d/firebase.json" ] && { printf '%s\n' "Firebase"; return; }
  printf '%s\n' ""; }
