---
round: 832
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-22
bench: none — the witness test is the measurement; the probe is below
commit: yes
severity: S3
release: changelog
---

# Round 832 — a peer's close reason forged a log line

## Target

Round 830's class swept further (L-12): peer text that reaches a log line.
`RpcWebSocketChannel` turns a peer's close (code and reason) into the status
every open call fails with, and the reason is the peer's own UTF-8 text.

## Hypothesis

A CR/LF in a close reason reaches this side's log through that status.

## Before

Probe `packages/transport/rpc_dart_websocket/.dart_tool/probe/r832_close_reason.dart`:
a dart:io websocket server that closes with code 4000 and a reason; a call
in flight on the client.

```
  reason                        client log records with CR/LF/ESC
  "bye" (control)               0 of 3
  "bye\r\nFORGED LINE \e[31m"   3 of 3:
    error: Transport error [streamId: 1] | ... code 4000: bye<CR><LF>FORGED LINE <ESC>[31m...
    error: Transport incoming error | (same)
    error: Unary call /Svc/m failed [streamId: 1] | (same)
```

## Mechanism

`'WebSocket closed by peer with code $code: $reason'`, the reason as it came.

## Fix

The reason is quoted through `_printable`: characters outside printable
ASCII as `\u{..}`. Not capped: the protocol caps a reason at 123 bytes.

## After

```
  "bye\r\nFORGED..."   0 of 3; the call's error reads
                       "... code 4000: bye\u{d}\u{a}FORGED LINE \u{1b}[31mred"
```

Witness `test/a_peer_close_reason_is_escaped_test.dart`; GUARD: a printable
reason is quoted as it is.

## Canary

The raw reason back, in place: the witness fails, `Expected: not match
'[\x00-\x1f\x7f]' Actual: 'WebSocket closed by peer with code 4000:
bye\r\n...'`. Restored.

## The verdict questions

1. Only the reason's characters differ.
2. Yes: 3 records against 0.
3. In the client's log stream and the call's error.
4. n/a.
5. Quoted.
6. One site, one canary.
7. From the numbers.
8. none.
9. none.
10. Siblings below.
A1. n/a. A2. n/a. L1. n/a.

## Gate

`melos run analyze` green; the websocket suite +315; `websocket_web_smoke_test`
on node.

## Siblings

- websocket: fixed here; the server side uses the same channel class
- http, channel, isolate, wasm: n/a, no close reason
- http2: GOAWAY debug data not measured (low priority)

## Not fixed

- A server's `grpc-message` is percent-decoded at the caller, so it can
  hold CR/LF too, and the caller logs a failed call's status. Next round.

CHANGELOG line: "rpc_dart_websocket: a peer's close reason is quoted with
control characters escaped in the status calls fail with, so it can no
longer write forged lines into the log."

## Links

Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md`. Round
`830-a-peers-newline-forged-a-log-line.md`.
