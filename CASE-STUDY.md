# Ship Gate: a case study

**The bet:** the quality check that fails you is never the one you skip on purpose, it is the one a flag quietly turns off, so the gate worth building is one that sits where the skip flag does not exist. Ship Gate runs your tests, review, security, and secret scan before a push to your protected branch (a docs-only change runs the deterministic gates and the secret scan; the judgment gates apply to code), and because it runs above git as a pre-tool hook rather than inside it, the usual escape hatch of pushing with no-verify is not there to reach for.

## The problem
I run the same ritual before every push to main, which is tests, a review pass, a security glance, and a secret scan, and for a long time the only thing enforcing that ritual was me remembering to do it. Discipline is exactly what evaporates at one in the morning, or the moment an agent is moving fast on my behalf, and the obvious fix does not actually work, because a git pre-push hook is one no-verify flag away from being optional and anything that wants the push to succeed will reach for that flag. I wanted a gate an agent in my terminal could not opt out of.

## The decisions that mattered most
The first was where to put the gate, and putting it above git as a pre-tool hook is the entire idea, because a hook that fires before the push command runs has no bypass flag, so by the time git would consult its own hooks the decision is already made.

The second is the one I am most pleased with, and it is about knowing when to stop. When I hardened the part that decides whether a command is really a push, my own deep-review method plus three adversarial passes found seven different ways a cleverly shaped command could slip a real push past the detector, and I fixed all seven and then deliberately stopped, since you can always hide a push inside a wrapper and chasing every one of those means rebuilding bash inside a hook, which only opens new holes. So I named the boundary honestly, that this is a guardrail against the accidental push and the fast agent and not a sandbox against someone determined to defeat it.

The third was learning from a real footgun rather than over-correcting from it, because my first version turned the gate on for every repo at once and immediately blocked a hackathon repo that had never asked for it, and the lesson was not that on-by-default was wrong but that there was no easy way out, so the version I shipped makes on-by-default a one-flag choice of the personal install (the marketplace install stays opt-in per repo), with four clean ways to step out.

## What I deliberately left out
I chose not to chase pushes hidden inside wrappers like `bash -c` or command substitution, and I wrote that boundary into the README in plain words, because pretending to stop a determined adversary would be a worse outcome than honestly stopping the failure that actually bites.

## What I'd do next
The honest next steps are widening the deterministic test coverage beyond its current set, and watching how the default-on behaviour lands for other people now that it is public, since the real test of a guardrail is whether it helps without getting in the way.

---

*Built by [Akshey Walia](https://www.linkedin.com/in/aksheywalia/). The project: [claude-code-ship-gate](https://github.com/aksheyw/claude-code-ship-gate) · companion: [claude-code-deep-review](https://github.com/aksheyw/claude-code-deep-review).*
