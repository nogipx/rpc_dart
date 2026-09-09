# Rule zero — the full list

In force when `unattended: yes`. A permission prompt stops the round dead, and
there is nobody to answer it. A command that *may* ask is the wrong command:
find the path before running, not after.

## What the allowlist covers

- The skill's `allowed-tools`: `Read`, `Edit`, `Write`, `Glob`, `Grep`,
  subagents, `python3` (for `loop.py`), `git status|log|diff|add|commit`.
- `permissions.allow` in the project's `.claude/settings.json`: the toolchain
  and the gate from `config.md` as prefix rules (`Bash(dart test:*)`), plus a
  rule for `loop.py`. `setup` mode writes them, `loop.py lint` checks them.

## What is forbidden, every item learned the hard way

- `$VAR`, `${...}`, `$(...)`, backticks, globs, `for` loops over variables. A
  prefix rule does not cover them and they always ask. Including
  `echo "EXIT=$?"` — the Bash tool reports a non-zero exit code by itself.
- `sed`, `head`, `tail`, `cat`, `awk` over a project file. That is `Read` with
  offset/limit. The rule is about the tool, not only about variable expansion: a
  literal `sed -n '150,200p'` counts too. And `| head -N` on a grep hides the
  evidence that refutes the hypothesis.
- `cd X && ...` chains. A bare `cd /abs/path` as the whole command is fine.
- `git stash`, `git checkout -- <path>`, `rm`, heredocs: destructive or
  interactive on failure. A canary switches the fix off with `Edit` and restores
  it with `Edit`; probes are overwritten, never deleted.
- Reading anything outside the project through the shell. Only `Read` with a
  full, literal, absolute path.
- `claude -p` for the review — only if a rule for it is on the allowlist;
  otherwise the reviewer is a subagent or yourself.

When `unattended: no`, interactivity is allowed, but `Read`/`Edit`/`Write` for
project files still stand: that is about quality, not about prompts.
