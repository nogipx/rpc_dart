---
round: 845
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-22
bench: P-314 — new
commit: yes
severity: S3 — "diagnostics (log level, log volume, message text)"
release: changelog
---

# Round 845 — an unparseable request is answered quietly

## Target

Round 844 found that P-225 has no harness for `RpcHttpServer`, and HTTP/1.1
is one of the owner's transports. A new harness,
`rpc_dart_http/.dart_tool/probe/fuzz_http_server.dart` (hostile raw HTTP/1.1
requests, a well-formed call every ten attacks), ran 300 attacks at seed
8451: 30 of 30 checks served, nothing in the zone, and eight multi-line
`ERROR - ... Error parsing request.` blocks on stderr, each with a stack.
That is KV-R-10, peer-triggered log amplification, and round 830's class,
peer text in a log line. Rounds 794 and 795 quietened rpc_dart's own logging
of rejected requests; this output never passes through it.

## Hypothesis

A request shelf cannot build a `Request` from makes the server write to
stderr every time, with the peer's text in it. Fails if a request the peer
controls costs a bounded number of lines.

## Before

```
kind x50     answers              stderr lines   ERROR   raw ESC
valid        200 x50              0              0       0
star         500 x50              450            50      0
fragment     400 x50              300            50      0
esc-host     500 x50              450            50      50
```

Six to nine lines per request, from any client, before any handler or auth,
and a Host carrying `ESC[31m` reaches stderr raw. An asterisk target and a
bad Host are answered 500, a server error for a client's.

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/r845_shelf_stderr.dart`.

## Mechanism

`shelf_io.handleRequest` builds a shelf `Request` from `requestedUri`; when
that throws (dart:io cannot parse the Host into a URI) or the URI is not
absolute (a fragment), it calls `_logTopLevelError`, which writes `ERROR -
<time>`, the error text (the URI, the peer's) and a stack to `stderr`, and
answers 500 or 400.

## After

```
kind x50     answers              stderr lines
valid        200 x50              0
star         400 x50              0
fragment     400 x50              0
esc-host     400 x50              0
```

`RpcHttpServer` checks `requestedUri` before shelf sees the request; one that
fails is answered 400 there and logged once, as a warning with no peer text.

## Canary

Witness `packages/transport/rpc_dart_http/test/an_unparseable_request_is_answered_quietly_test.dart`
(stderr captured through `IOOverrides`). Filter off: "WITNESS an unparseable
request is answered 400 with nothing on stderr" failed with `Expected: empty`
and the three ERROR blocks, the last holding `http://127.0.0.1:\x1B[31mX/Svc/m`;
"GUARD a well-formed request is still served" green. The first canary run had
the status assertion first and failed on `500 Internal Server Error` before
reaching stderr; the assertions were reordered so the canary hits the claim.

## Gate

`melos run analyze` SUCCESS (after `dart format` reflowed the server file);
`melos run test:unit --no-select` SUCCESS (rpc_dart_http +259, rpc_dart
+2206 ~1, websocket +331, http2 +316); `format:check` SUCCESS;
`license:check` compliant.

## Siblings

- http: fixed here
- http2: n/a — `package:http2`, no shelf and no `requestedUri` on its path
- websocket: clean — the same three requests x30 against `bindRpcWebSocketHttpServer` + `rpcWebSocketConnections`: 0 stderr lines (`r845_ws_stderr.dart`)
- channel: n/a — no HTTP request line or Host header, so no URI is built from peer text
- isolate: n/a — no HTTP request, as channel
- wasm: n/a — no HTTP request, as channel
- caller: n/a — the defect is shelf's handling of an inbound request; a caller parses responses, and C-83's client harnesses saw nothing in the zone
- responder: fixed here (`RpcHttpServer` is the responder side)

## Not fixed

- shelf's other top-level path, "Asynchronous error" for an error a handler
  leaves in the zone, is not peer-triggered here: the fuzzers find nothing in
  the zone (C-83, this round's harness).
- `fuzz_http_server.dart` is added to P-225's harness list; it found nothing
  else in 300 attacks.

## Links

Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md`. Bench
`../probes/P-314-an-unparseable-request-and-the-servers-stderr.md`, harness
`../probes/P-225-what-a-fuzzer-finds-in-the-decoders-and-the-servers.md`.
Rounds `830-a-peers-newline-forged-a-log-line.md`,
`844-the-fuzzers-two-hundred-rounds-on.md`.
