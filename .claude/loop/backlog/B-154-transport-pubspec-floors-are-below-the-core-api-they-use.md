---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/pubspec.yaml, packages/transport/rpc_dart_websocket/pubspec.yaml, packages/transport/rpc_dart_isolate/pubspec.yaml, packages/transport/rpc_dart_http2/pubspec.yaml, packages/transport/rpc_dart_wasm/pubspec.yaml]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-154 — transport pubspecs declare rpc_dart floors below the APIs they call

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Http `>=6.0.0`, websocket `>=6.1.0` while they use `maxFramedMessageBytes`, `isAcceptableContentType`, `RpcNoConnectionException` (added 2026-09-28, after core's version became 6.3.0); invisible to the workspace — release flow step 1b (`bump:rpc_dart`) is where this closes.

## The shape

`git log -S` dates: `maxFramedMessageBytes` 071cd0e (2026-09-28),
`RpcNoConnectionException` d4c9285 (2026-09-28); core `version: 6.3.0` since
7993c50 (2026-09-22). Tags are absent from the auditing clone, so whether 6.3.0
is published was not checked.

## Why it matters

A published transport resolving an older core fails to compile.

## Witness a round would build

`git show <release-tag>:<core file>` grep for the symbols, per CLAUDE.md 1b.

## Fix sketch

Run `melos run bump:rpc_dart` at the next release; bump core's version if 6.3.0
is already out.

## Owner decision

—
