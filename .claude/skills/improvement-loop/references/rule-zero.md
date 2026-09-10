# Rule zero — the full list

> [References](REFERENCES.md) · the allowlist is written by
> [methods/setup.md](../methods/setup.md) and declared in
> [specs/config.md](../specs/config.md) · it binds the canary protocol too:
> [methods/canary.md](../methods/canary.md)

In force when `unattended: yes`. A permission prompt stops the round dead, and
there is nobody to answer it. A command that *may* ask is the wrong command:
find the path before running, not after.

**Never issue a command that needs approval.** Not "issue it and see" — a
prompt is a failure of the round, whether or not a human happens to answer it.
Before every `Bash` call, check the command against the two lists below; if it
is not obviously covered, use `Read`/`Grep`/`Glob` instead, or split it into
calls that are.

## One command per call

`;`, `&&`, `||` and `|` between two commands make the line match **no** prefix
rule, so it prompts even when each half would have been allowed alone. Issue
them as separate `Bash` calls — they can go in the same message. The pattern
that keeps recurring is a status echo welded onto an allowed command
(`loop.py lint; echo "EXIT=$?"`): the allowed half is invisible to the
allowlist because of the half that was never needed.

## What the allowlist covers

- The skill's `allowed-tools`: `Read`, `Edit`, `Write`, `Glob`, `Grep`,
  subagents, `python3` **for `scripts/loop.py` only**, and
  `git status|log|diff|add|commit`.
- `permissions.allow` in the project's `.claude/settings.json`: the toolchain
  and the gate from `config.md` as prefix rules (`Bash(dart test:*)`), plus a
  rule for `loop.py` **naming its path**. `setup` mode writes them, `loop.py
  lint` checks them.

**The interpreter rule is a PATH rule, and that is the whole point.**
`Bash(python3:*)` reads like "the script may run" and actually means "any
program I type may run" — `python3 -c "..."` matches it, silently. The rule is
therefore written as
`Bash(python3 <path>/scripts/loop.py:*)`, and `lint` rejects the bare form
wherever it appears: in the project's settings, in the skill's own
`allowed-tools`. Measured: with the bare rule in the skill, an agent ran inline
Python roughly fifteen times across one session without a single prompt, in a
repository whose own settings had the narrow rule all along.

## What is forbidden, every item learned the hard way

- `$VAR`, `${...}`, `$(...)`, backticks, globs, `for` loops over variables. A
  prefix rule does not cover them and they always ask. Including
  `echo "EXIT=$?"` — the Bash tool reports a non-zero exit code by itself.
- **A program written on the command line**: `python3 -c`, `python3 -`,
  `node -e`, `dart -e`, `perl -e`, a heredoc. It is a script authored outside
  `Write`, so it never appears in a diff and nobody can review it; and it is
  how an interpreter rule gets used for something other than the one script it
  was allowed for. Whatever it computes, compute it with `loop.py`, with `Read`,
  or with a probe file the round records by name.
- **Backgrounding and file redirection**: `cmd &`, `( cmd & )`, `cmd > out.txt`,
  `nohup`. They prompt, and they move the output out of the transcript, so the
  round's evidence ends up somewhere the record cannot quote. A long command
  runs in the foreground with a timeout.
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
- Spawning another agent process from the shell (`claude -p`) — only if a rule
  for it is on the allowlist. Delegation goes through the `Agent`/`Task` tool,
  which is already covered.

When `unattended: no`, interactivity is allowed, but `Read`/`Edit`/`Write` for
project files still stand: that is about quality, not about prompts.
