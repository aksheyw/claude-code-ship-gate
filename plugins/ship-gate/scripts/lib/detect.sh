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
# P2 (S149): emit one line per suite the single configured tests.command would silently SKIP (the gap that
# motivated S149). ADVISORY only — `doctor` wraps each line in a [WARN] and never blocks. Four kinds, each a clear
# category so the user can wire the missing suite as a `when`-conditional array entry:
#   1. a nested package.json (non-root, non-node_modules) that has its own `scripts.test`
#   2. an extra/named UNIT-test config (vitest.workspace.*, a vitest.config.<name>.* variant, or a nested
#      vitest/jest config) — a single root vitest.config.ts / jest.config.js is the normal case and is NOT flagged
#   3. an e2e suite — an e2e/ or tests/e2e/ directory, or a playwright/cypress/wdio config (almost never run
#      by the default `npm test`)
#   4. a *.rules file (Firestore/Storage security rules) — needs an emulator test suite a JS runner won't cover
# bash-3.2-safe (no mapfile); node_modules is always pruned; over-flagging is acceptable (advisory), silently
# missing a suite is the failure mode to avoid.
sg_detect_uncovered(){ local d="$1" f
  [ -d "$d" ] || return 0
  # 1. nested package.json with its own test script
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$f" = "$d/package.json" ] && continue
    jq -e '(.scripts.test // null) != null' "$f" >/dev/null 2>&1 \
      && printf 'nested package with its own test script: %s\n' "${f#"$d"/}"
  done < <(find "$d" -name package.json -not -path '*/node_modules/*' -type f 2>/dev/null)
  # 2. extra/named unit-test configs. A NAMED variant (vitest.workspace.*, vitest/jest.config.<name>.*,
  # jest.<word>.config.*) is a separate suite a bare `vitest`/`jest` skips, at ANY depth; a PLAIN
  # vitest.config.* / jest.config.* is the normal single config at the root (NOT flagged) but a separate
  # suite when NESTED. Depth is decided on the prefix-stripped RELATIVE path with literal string ops — NOT a
  # `-path "$d/*/*"` glob, which a '[' in $d would defeat into a char class (deep-review L1-2). The find
  # -name list surfaces every candidate; the case classifies. jest variants are symmetric with vitest (L1-1).
  local rel base
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$d"/}"; base="${f##*/}"
    case "$base" in
      vitest.workspace.*|vitest.config.*.*|vitest.*.config.*|jest.config.*.*|jest.*.config.*)
        printf 'extra test-runner config: %s\n' "$rel" ;;                                # named variant (suffix OR infix) => any depth
      vitest.config.*|jest.config.*)
        case "$rel" in */*) printf 'extra test-runner config: %s\n' "$rel" ;; esac ;;    # plain => only when nested
    esac
  done < <(find "$d" -not -path '*/node_modules/*' -type f \( \
        -name 'vitest.workspace.*' -o -name 'vitest.config.*' -o -name 'vitest.*.config.*' \
        -o -name 'jest.config.*' -o -name 'jest.*.config.*' \) 2>/dev/null)
  # 3. e2e suites — directories and e2e/component-test configs
  local sub; for sub in e2e tests/e2e cypress; do
    [ -d "$d/$sub" ] && printf 'end-to-end test directory: %s\n' "$sub"
  done
  while IFS= read -r f; do
    [ -n "$f" ] && printf 'end-to-end test config: %s\n' "${f#"$d"/}"
  done < <(find "$d" -not -path '*/node_modules/*' -type f \( \
        -name 'playwright.config.*' -o -name 'cypress.config.*' -o -name 'wdio.conf.*' \) 2>/dev/null)
  # 4. security-rules files
  while IFS= read -r f; do
    [ -n "$f" ] && printf 'security-rules file (needs an emulator test suite): %s\n' "${f#"$d"/}"
  done < <(find "$d" -name '*.rules' -not -path '*/node_modules/*' -type f 2>/dev/null)
}
# P4 (S149): name the CI system if one is configured, else "" — so /ship-init + doctor can warn that with no
# CI this gate is the SOLE automated check before prod. First match wins (like sg_detect_deploy).
sg_detect_ci(){ local d="$1"
  # find (not a glob) so a present .yml is detected even when the sibling *.yaml glob has no match (ls would
  # exit non-zero on the unmatched operand and read as "no CI" — a fail-open for the very warning we want).
  if [ -n "$(find "$d/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null)" ]; then printf '%s\n' "GitHub Actions"; return; fi
  [ -f "$d/.gitlab-ci.yml" ] && { printf '%s\n' "GitLab CI"; return; }
  [ -f "$d/.circleci/config.yml" ] && { printf '%s\n' "CircleCI"; return; }
  [ -f "$d/Jenkinsfile" ] && { printf '%s\n' "Jenkins"; return; }
  { [ -f "$d/azure-pipelines.yml" ] || [ -f "$d/azure-pipelines.yaml" ]; } && { printf '%s\n' "Azure Pipelines"; return; }
  [ -f "$d/.travis.yml" ] && { printf '%s\n' "Travis CI"; return; }
  [ -f "$d/bitbucket-pipelines.yml" ] && { printf '%s\n' "Bitbucket Pipelines"; return; }
  [ -f "$d/.buildkite/pipeline.yml" ] && { printf '%s\n' "Buildkite"; return; }
  [ -f "$d/.drone.yml" ] && { printf '%s\n' "Drone CI"; return; }
  { [ -f "$d/appveyor.yml" ] || [ -f "$d/.appveyor.yml" ]; } && { printf '%s\n' "AppVeyor"; return; }
  printf '%s\n' ""; }
