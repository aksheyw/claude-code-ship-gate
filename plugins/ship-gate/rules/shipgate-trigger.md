# Ship Gate: natural-language ship trigger

ship-gate gates pushes to the protected branch (usually `main`) behind its quality gates. This rule routes
plain-language ship intent to that gated flow, so a push to the protected branch never skips the gates.

## When the user gives a command to ship

If the user tells you to ship, release, or push to the protected branch: "ship it", "go ahead and ship",
"sync with GitHub", "push this to main": invoke the `/ship` skill. `/ship` runs every gate and, when all
required gates pass and nothing needs the user's decision, **pushes automatically**. The command itself is
the authorization: do not ask "ready to push?" again. `/ship` still pauses for any gate that genuinely needs
input: a UAT call, a feature-branch merge, a missing test command, or a detected deploy target, so
auto-push only ever happens on a clean, fully-passed run.

## When the user asks a question, or says not yet

If the user *asks* whether to ship, or says *not* to ship yet: "should we ship?", "is this ready?",
"don't ship until the gates pass": run the gates and report only. Use `/ship --dry-run`: it prints the
gate summary and never pushes. A question or a "not yet" is never a command to ship; do not auto-push.

## The one hard rule

Never push to the protected branch by any path other than the `/ship` flow: no direct `git push` to the
protected branch, no `git push --no-verify`, no working around the gate. The push-block hook enforces this
even if this rule is missed, but the rule keeps the normal path on `/ship`.
