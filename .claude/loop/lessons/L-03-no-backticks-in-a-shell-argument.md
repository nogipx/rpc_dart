---
round: 210 — where it was paid for
class: toolchain
cost: 1 mangled commit body (three words silently deleted) plus 1 amend, and 2 interruptions from the owner asking for no permission prompts
paths: []
commit: beed83e5
status: active
---

# L-03 — never put a backtick in a shell argument, not even inside quotes

Round 210's commit body quoted a Dart expression in backticks inside a
double-quoted `-m`. zsh read that as command substitution: it printed
"command not found: await", deleted the quoted words from the message, and — the
part that matters — turned a statically matchable `git commit` into one the
allowlist cannot match, so it asked the owner for permission. Rule zero forbids
substitutions for exactly that reason; the failure mode is not just a broken
string.

Same family, same session: an unquoted `--plain-name a paused download ...` was
word-split into nine arguments and produced nine spurious "Failed to load"
errors that read like test failures.

In a Bash argument use plain words and straight quotes only — no backticks, no
dollar signs, no tildes, no globs, no pipes. Markdown formatting belongs in
files written with Write and Edit, never in a command line.
