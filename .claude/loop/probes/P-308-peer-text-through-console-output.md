---
file: packages/core/rpc_dart/.dart_tool/probe/r833_console_output.dart
round: 833
commit: 54bf6160
paths: [packages/core/rpc_dart/lib/src/logger/outputs/console_output.dart]
status: valid
promoted: packages/core/rpc_dart/test/logger/a_record_stays_one_line_test.dart
---

# P-308 — peer text through ConsoleOutput

## Measures

`r833_console_output.dart <pretty|compact|json> <plain|hostile>`: a server
over the framed channel pair answers a call with
`RpcStatusException(7, message)`; the caller's endpoint logs through
`ConsoleOutput(colored: false, format)` at every level. The hostile message
is `'denied\r\nFORGED-LINE ERRO pwned \x1b[2J\x01'`. A python checker reads
stdout: lines, lines starting `FORGED`, control characters other than the
line breaks, and (json) lines that do not parse.

```
  format   message   lines   FORGED   control chars   invalid json
  pretty   plain     16      0        0
  pretty   hostile   17      1        3
  compact  hostile   17      1        3
  json     hostile   16      0        2               1
  after the fix: every hostile row as its plain row (16, 0, 0, 0)
```

The forged line came from a DEBUG record ("Call answered 7 - ..."), and
`LogController`'s default `minLevel` is debug, so an attached `ConsoleOutput`
prints it by default.

## Control

The plain message: 16 lines, nothing forged, no control character.
