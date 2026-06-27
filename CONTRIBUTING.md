# Contributing to Ship Gate

Thanks for considering a contribution. Ship Gate is intentionally small and dependency-free (bash + jq + awk), and the bar for the enforcement path is high, because a bug there can let an un-gated push through.

## Running the tests

The whole suite is plain bash, no framework:

```sh
for t in plugins/ship-gate/scripts/test/*_test.sh; do bash "$t"; done   # expect TOTAL PASS=265 FAIL=0
claude plugin validate ./plugins/ship-gate
claude plugin validate .
```

Every change must keep the suite green and both manifests valid.

## What to know before you open a PR

- **The push-detection parser is bounded on purpose.** Ship Gate matches `git push` as a simple command (env-assignment prefixes, git global options, and bash quoting/escaping are all honored). It does not chase a push hidden inside a wrapper (`bash -c`, `eval`, `$(...)`, `sudo`, `xargs`) or obscured by I/O redirection. That boundary is deliberate: reimplementing bash inside a hook tends to introduce new holes. A report about a wrapper-hidden push is working as intended; a report about a *normal* command shape that slips through is a real bug worth fixing with a test.
- **The hook fails closed.** Any change to `check-push.sh` must keep every failure mode routing to `deny`. Add a test that proves it.
- **Small files, immutable patterns.** Match the surrounding style.

## Opening a PR

1. Fork and branch.
2. Make the change with a test (write the failing test first, then the fix).
3. Run the suite and both `plugin validate`s; both must pass.
4. Open a PR describing what changed, why, and what a reviewer should check.

Bug reports and questions are welcome as issues.
