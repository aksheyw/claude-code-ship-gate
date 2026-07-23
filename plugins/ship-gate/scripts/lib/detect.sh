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
# Config-drift detection (2026-07-23): cheap, execution-free signal that a repo now has the capability a
# DISABLED gate covers (a test suite, a lint config, a tsconfig, a build script) — the OTHER half of the
# "no silent pass" spec (§16 covers an ENABLED gate with no command; this covers a DISABLED gate that now
# has something to run). Checked ONLY when a gate is disabled (see sg_gate_skip_or_drift below); never
# runs anything, only stats/globs, so it's safe to call on every `run`/`doctor`.
# Two tiers, cheapest first:
#   1. the EXISTING root-marker auto-detect (sg_detect_*_cmd) — if that already finds a command, reuse it.
#   2. a filename-pattern scan (no root marker matched) — catches the real-world gap that motivated this:
#      a test/lint/build capability that lives in a subdirectory with no root-level marker file (e.g. a
#      pytest suite under .claude/scripts/ in a repo with no root pyproject.toml/requirements*.txt).
# node_modules/.git are always pruned. Over-flagging risk is kept low deliberately (see DECISIONS.md): only
# well-known, low-ambiguity filename conventions are matched — a stray file named loosely like "test" is
# NOT a signal, only conventional patterns (test_*.py, *.spec.ts, .eslintrc*, tsconfig.json, etc).
# sg_capability_files <dir> <kind> — emit RELATIVE paths of candidate files for a capability `kind`.
# Discovery respects GIT's view of the repo when there is one: `git ls-files --cached --others
# --exclude-standard` lists tracked files PLUS untracked-not-ignored ones, so a brand-new uncommitted test
# file still counts (desirable — that's a suite about to land) while everything .gitignore'd or excluded via
# .git/info/exclude is skipped. That matters: the repo that motivated this feature keeps LINKED WORKTREES
# under a git-excluded `.claude/worktrees/` holding full COPIES of its suite, so a raw filesystem scan
# reported 8 test files (real count: 5) and named an untracked worktree copy as the example — misleading in
# exactly the line a human is meant to act on. Same class as vendored deps and build output. Outside a git
# repo (or if git errors), fall back to `find`. One `git ls-files` process is also cheaper than `find`.
sg_capability_files(){ local d="$1" kind="$2" f base any=0
  # Normalise away trailing slashes FIRST: `$d` reaches here from `dir="${2:-$PWD}"`, so a caller passing
  # `run /path/` used to make the find-fallback prefix strip (`${f#"$d"/}` => `${f#"/path//"}`) miss, leaving
  # an absolute path that then matched the `*/*` nested-file check and silently dropped a ROOT Makefile.
  # The `/` guard keeps a bare root dir intact rather than reducing it to the empty string.
  while :; do case "$d" in /) break ;; */) d="${d%/}" ;; *) break ;; esac; done
  if git -C "$d" rev-parse --git-dir >/dev/null 2>&1; then
    # -z is REQUIRED, not a nicety: without it git QUOTES any path containing non-ASCII bytes
    # ("dir/t\303\251st.py"), which both breaks the suffix pattern match (trailing quote) and would print a
    # backslash-escaped example path. -z emits raw, byte-exact paths.
    while IFS= read -r -d '' f; do
      [ -n "$f" ] || continue
      any=1                                   # git can see SOMETHING here => git governs this tree
      # --cached lists INDEX entries, so a file deleted on disk but not yet staged is still listed. Skip
      # anything that no longer exists, or drift would count it and name a file the reader cannot open.
      [ -e "$d/$f" ] || continue
      case "$f" in */node_modules/*|node_modules/*|*/vendor/*|vendor/*) continue ;; esac
      base="${f##*/}"
      if sg_capability_match "$base" "$kind"; then printf '%s\n' "$f"; fi
    done < <(git -C "$d" ls-files -z --cached --others --exclude-standard 2>/dev/null)
    # If git could see NO files at all under $d, git is not actually governing this tree — the usual cause
    # is $d being a plain directory inside a PARENT repo's ignored path, where rev-parse still succeeds via
    # the parent's .git but ls-files legitimately returns nothing. Reporting "no capability" there would be
    # a SILENT MISS (the very failure this feature exists to prevent), so fall through to the plain scan.
    [ "$any" = 1 ] && return 0
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="${f##*/}"
    if sg_capability_match "$base" "$kind"; then printf '%s\n' "${f#"$d"/}"; fi
  done < <(find "$d" -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/vendor/*' -type f 2>/dev/null)
  return 0; }
# Filename conventions per capability. Deliberately CONSERVATIVE (see DECISIONS.md): only well-known,
# low-ambiguity patterns count, so a file merely named loosely like "test" is not a signal.
sg_capability_match(){ local base="$1" kind="$2"
  case "$kind" in
    tests) case "$base" in
        test_*.py|*_test.py|conftest.py|*.test.js|*.test.ts|*.test.jsx|*.test.tsx) return 0 ;;
        *.spec.js|*.spec.ts|*.spec.jsx|*.spec.tsx|*_test.go|*Test.java|*_spec.rb) return 0 ;;
      esac ;;
    lint) case "$base" in
        .eslintrc*|.flake8|.pylintrc|ruff.toml|.rubocop.yml|stylelint.config.*) return 0 ;;
      esac ;;
    typecheck) case "$base" in tsconfig.json|mypy.ini|pyrightconfig.json) return 0 ;; esac ;;
    buildfile) case "$base" in Makefile) return 0 ;; esac ;;
    packagejson) case "$base" in package.json) return 0 ;; esac ;;
  esac
  return 1; }
sg_detect_capability(){ local d="$1" gate="$2" root="" n=0 first="" f
  case "$gate" in
    tests) root="$(sg_detect_test_cmd "$d")" ;;
    lint) root="$(sg_detect_lint_cmd "$d")" ;;
    typecheck) root="$(sg_detect_typecheck_cmd "$d")" ;;
    build) root="$(sg_detect_build_cmd "$d")" ;;
    *) return 0 ;;
  esac
  if [ -n "$root" ]; then printf 'root markers detected (auto-detected command: %s)\n' "$root"; return 0; fi
  case "$gate" in
    tests)
      while IFS= read -r f; do
        [ -n "$f" ] || continue; n=$((n+1)); [ -n "$first" ] || first="$f"
      done < <(sg_capability_files "$d" tests)
      [ "$n" -gt 0 ] && printf '%s test file(s) detected (e.g. %s)\n' "$n" "$first" ;;
    lint)
      while IFS= read -r f; do
        [ -n "$f" ] || continue; n=$((n+1)); [ -n "$first" ] || first="$f"
      done < <(sg_capability_files "$d" lint)
      [ "$n" -gt 0 ] && printf '%s lint config file(s) detected (e.g. %s)\n' "$n" "$first" ;;
    typecheck)
      while IFS= read -r f; do
        [ -n "$f" ] || continue; n=$((n+1)); [ -n "$first" ] || first="$f"
      done < <(sg_capability_files "$d" typecheck)
      [ "$n" -gt 0 ] && printf '%s type-check config file(s) detected (e.g. %s)\n' "$n" "$first" ;;
    build)
      # A root-level Makefile, or ANY package.json (at any depth) that declares a build script.
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in */*) continue ;; esac                     # Makefile only counts at the repo root
        n=$((n+1)); [ -n "$first" ] || first="$f"
      done < <(sg_capability_files "$d" buildfile)
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        jq -e '(.scripts.build // null) != null' "$d/$f" >/dev/null 2>&1 \
          && { n=$((n+1)); [ -n "$first" ] || first="$f"; }
      done < <(sg_capability_files "$d" packagejson)
      [ "$n" -gt 0 ] && printf '%s build file(s) detected (e.g. %s)\n' "$n" "$first" ;;
  esac
  return 0; }
# sg_gate_skip_or_drift <dir> <gate-key>: called ONLY on the disabled-gate path (never on an enabled gate,
# never for secretScan/codeReview/security/uat — the drift check applies only to the four command gates).
# A plain [SKIP] stays plain and silent when nothing is detected (the legitimately-not-applicable case —
# e.g. lint in a repo with no linter — must never get noisier). When the repo demonstrably has the gate's
# capability: [DRIFT] if no `reason` is recorded on the gate (a signal /ship's orchestration PAUSES on, the
# same weight as an enabled gate with no command — see SKILL.md); [DRIFT-ACK] if a `reason` IS recorded (a
# conscious, dated decision — surfaced every run so the premise is never invisible again, but NOT a pause,
# to avoid training people to click through a line that fires on every ship for something already decided).
sg_gate_skip_or_drift(){ local d="$1" key="$2" cap reason
  case "$key" in tests|lint|typecheck|build) : ;; *) sg_log skip "$key (disabled)"; return 0 ;; esac
  cap=$(sg_detect_capability "$d" "$key")
  [ -n "$cap" ] || { sg_log skip "$key (disabled)"; return 0; }
  reason=$(sg_config_get "$d" ".gates.${key}.reason" 2>/dev/null || true); if [ "$reason" = "null" ]; then reason=""; fi
  if [ -n "$reason" ]; then
    sg_log driftack "$key: disabled (reason: \"$reason\") — but $cap; reconsider if this reason is stale (run /ship doctor)"
  else
    sg_log drift "$key: disabled in config, but $cap — run '/ship doctor' to review, or set gates.${key}.reason if this is intentional"
  fi
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
