---
round: 830
verdict: FIXED
packages: [rpc_dart]
lens: RPC-22
bench: P-307 — new
commit: yes
severity: S3
release: changelog
---

# Round 830 — a peer's newline forged a log line

## Target

Network-audit KV-R-10, its second half: "interpolation of peer strings into
log lines (control characters)". No record (`find 'log injection control
characters newline peer string interpolated log line'`).

## Hypothesis

A peer's text with CR/LF reaches a log message unescaped, so an
unauthenticated peer writes forged lines into the server's log.

## Before

P-307 at 8da0fa28, raw frames over the channel pair:

```
  /Svc\r\nFORGED/m   1 record with CR/LF:
    "... Invalid methodPath in metadata: /Svc<CR><LF>FORGED/m"
```

HTTP/1.1: the same paths percent-encoded are answered 400 with nothing
logged.

## Mechanism

`RpcSecurityPolicy.validateMetadata` built its message as `'Invalid
methodPath in metadata: $methodPath'` (and `'Invalid metadata header name:
${header.name}'`); the channel transport reports the refusal, and the
endpoint logs that message once per connection. The text is the very value
that failed validation, so it can hold anything, at any length the metadata
bound allows (64 KiB).

## Fix

`_peerText` quotes the peer's text in both messages: characters outside
printable ASCII as `\u{..}`, at most 128 of them, then `...`. `invalidValue`
keeps the raw value (`ArgumentError.toString` escapes it already).

## After

P-307: no record with CR/LF/ESC in any row. Witness
`packages/core/rpc_dart/test/core/a_violation_message_escapes_peer_text_test.dart`
(method path with CR/LF, header name with LF, a 4000-character path; GUARD:
a printable path quoted as it is), run on the VM and on node.

## Canary

Both messages back to the raw text, in place: the three witnesses fail,
`Expected: not match '[\x00-\x1f\x7f]' Actual: 'Invalid methodPath in
metadata: /Svc\r\n...'`, the same for the header name, and `Expected: a value
less than <960> Actual: <4035>` for the long path; the GUARD passes.
Restored.

## The verdict questions

1. Only the path's characters differ from the control.
2. Yes: 1 record with CR/LF against 0.
3. In the server's log stream (a `LogController` on the endpoint), and the
   violation's message directly in the witness.
4. n/a.
5. Quoted.
6. Two sites, one helper; the canary reverted both and each witness failed.
7. From the numbers.
8. The cancel reason was not quoted: it is refused as an invalid header
   value, and that message names the header, not the value.
9. none.
10. Siblings below.
A1. n/a. A2. n/a. L1. n/a.

## Gate

`melos run analyze` green. `test:unit`, twice, each with one red in a test
this session wrote: (1) http2 `graceful_drain_on_stop_test` "a second stop
during a drain waits for it", the call ended UNAVAILABLE instead of
finishing; not reproduced in 6 sequential runs, 8 parallel runs of the file
and 3 parallel runs of the whole http2 suite; (2) http
`aggregate_metadata_bound_test` "a block far over the bound is cut", a 30 s
timeout: the test awaited a flush into the socket the server had cut;
fixed in the test (`unawaited`), commit 4263a2b9.

## Siblings

- channel, websocket, isolate: fixed here (the policy is core's, and all of
  them validate inbound metadata with it)
- http: measured clean (P-307's http half: 400 before any log)
- http2: validates through the same `RpcSecurityPolicy`; fixed here, not
  measured separately
- wasm: the same policy; not measured

## Not fixed

- The http2 drain witness's one red under the gate's load (Gate).

CHANGELOG line: "rpc_dart: a metadata violation quotes the peer's offending
text with control characters escaped and at most 128 characters, so a peer
can no longer write forged lines into the receiver's log."

## Links

Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md`. Bench
`../probes/P-307-peer-text-in-log-lines.md`.
