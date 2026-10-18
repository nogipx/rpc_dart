---
file: packages/transport/rpc_dart_http/.dart_tool/probe/r845_shelf_stderr.dart
round: 845
commit: ffebbc80
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart]
status: stale (526c8d52)
promoted: packages/transport/rpc_dart_http/test/an_unparseable_request_is_answered_quietly_test.dart
---

# P-314 — an unparseable request and the server's stderr

`fvm dart run <file> <valid|star|fragment|esc-host> [count]` from the repo
root. `RpcHttpServer` runs in a child process; the parent sends `count` raw
requests of one kind and counts the child's stderr lines, the ERROR headers
among them and the lines carrying a raw ESC. Kinds: an asterisk target, a
target with a fragment, a Host carrying `ESC[31m`. The websocket sibling is
`rpc_dart_websocket/.dart_tool/probe/r845_ws_stderr.dart`.

## Measures

Lines the server writes to stderr per request a peer sends, and the status
it answers.

## Control

`valid`: well-formed requests. Before the fix:

```
kind x50     answers              stderr lines   ERROR   raw ESC
valid        200 x50              0              0       0
star         500 x50              450            50      0
fragment     400 x50              300            50      0
esc-host     500 x50              450            50      50
```
