---
round: 833
verdict: FIXED
packages: [rpc_dart]
lens: RPC-22
bench: P-308 — new
commit: yes
severity: S3
release: changelog
---

# Round 833 — ConsoleOutput let a peer write a line

## Target

Round 832's `## Not fixed`: a server's `grpc-message` is percent-decoded at
the caller, so it can carry CR/LF, and the caller logs the status it got.
Rounds 830 and 832 escaped peer text at two sites; there are more (every
status message, every quoted error), so the question moved to the sink:
rpc_dart's own `ConsoleOutput`.

## Hypothesis

`ConsoleOutput` prints a record's message, error and data raw, so any peer
text that reaches a record forges lines, drives the terminal, or (json)
breaks the line's syntax.

## Before

P-308 at 54bf6160:

```
  pretty / compact, hostile   17 lines (16 + 1 forged "FORGED-LINE ERRO pwned"),
                              3 control chars (CR, ESC, \x01)
  json, hostile               1 line that does not parse
  plain (control)             16 lines, 0, 0
```

## Mechanism

`_writePrettyEvent` wrote `${event.message}` and `err=${event.error}`,
`_writeCompact` the message, `_writeData` each value, all raw. The json
writer escaped `"`, `\`, `\n`, `\r`, `\t` and nothing else below 0x20.

## Fix

- pretty and compact: `_oneLine` escapes control characters (CR and LF as
  `\r` `\n`, the rest as `\u{..}`; tab kept) in the message, the error and
  the data values; the stack trace is still printed on its own lines.
- json: every character below 0x20 that has no short form is written as
  `\u00XX`.
- The shipped skill's `logging-and-health.md` says so, and that a custom
  text `LogOutput` has to do the same.

## After

P-308: every hostile row as its plain row. Witness
`test/logger/a_record_stays_one_line_test.dart` (pretty, compact: one line,
no control character; json: parses and the text round-trips; GUARD: a tab
and plain text unchanged), VM and node.

## Canary

Both halves off in place (`_oneLine` returning the text, the json branch
writing the raw character): the three witnesses fail, `Expected: not match
... Actual: '... Call answered 7 - denied\r\n'` (pretty and compact) and
`FormatException: Unexpected character (at character 116)` (json); the
GUARD passes. Restored.

## The verdict questions

1. Only the message's characters differ.
2. Yes: 17 lines against 16, 1 invalid json line against 0.
3. On stdout, what `ConsoleOutput` printed, read by a separate checker.
4. n/a.
5. Quoted.
6. Two halves (text formats, json), one canary run switching both; each
   witness names its own format.
7. From the numbers.
8. none.
9. none.
10. Siblings below.
A1. n/a. A2. n/a. L1. n/a.

## Gate

`melos run analyze`, `test:unit`, `check:skills` green; the witness and
`console_output_test` on node.

## Siblings

- `RingBufferOutput`: n/a, stores records, prints nothing
- every transport: covered here, since the sink is shared; rounds 830 and
  832 escaped at the source as well
- `rpc_dart_log` (remote collector) and `rpc_dart_opentelemetry`: other
  packages' outputs, not measured (out of the round scope)

## Not fixed

- `rpc_dart_log` and `rpc_dart_opentelemetry` outputs not checked.

CHANGELOG line: "rpc_dart: `ConsoleOutput` escapes control characters in a
record's message, error and data, so a peer's text (a status message, a
close reason) can no longer forge log lines or drive the terminal; the
`json` format escapes every control character and stays parseable."

## Links

Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md`. Bench
`../probes/P-308-peer-text-through-console-output.md`. Rounds
`830-a-peers-newline-forged-a-log-line.md`,
`832-a-peers-close-reason-forged-a-log-line.md`.
