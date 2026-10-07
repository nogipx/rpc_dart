---
round: 699
verdict: FIXED
packages: [rpc_dart]
lens: RPC-07
bench: none — a dart2wasm websocket client run in node 22 against a VM server (`.dart_tool/probe/b256_client.dart`, `b256_server.dart`), dart2js as the control
commit: yes
release: changelog
---

# Round 699 — the web under dart2wasm decodes

## Target

B-256, filed by round 682: the browser transports under dart2wasm may hit the
same JS-backed `sublist` bug as the wasm guest, because `package:web_socket`
hands up `toDart.asUint8List()` and core's CBOR slices payload views.

## Hypothesis

Every response decode fails under dart2wasm; dart2js is unaffected.

## Before

A websocket client compiled both ways, run in node 22 (which has a global
`WebSocket`) against an `RpcWebSocketServer` on the VM:

```
dart2wasm  RESULT a -> ERROR RpcStatusException(13): Response could not be decoded
           RESULT hello world -> ERROR RpcStatusException(13): Response could not be decoded
dart2js    RESULT a -> echo:a
           RESULT hello world -> echo:hello world
```

## Mechanism

As round 682 measured for the guest: `sublist` of a JS-backed view at a
non-zero offset counts the offset twice. The payload is a view into the
WebSocket message; the CBOR decoder's two `sublist` calls (text and byte
strings) break on it. The parser's own `sublist` reads its internal buffer,
which is a Dart list, and is unaffected.

## Fix

In `special_cbor.dart`: a text string is decoded from `Uint8List.sublistView`
-- no copy at all, since `utf8.decode` only reads it -- and a byte string is
`Uint8List.fromList(Uint8List.sublistView(...))`, the same one copy `sublist`
made. No cost added; the text path loses a copy. This covers every transport
on the web, not one.

## After

```
dart2wasm  RESULT a -> echo:a
           RESULT hello world -> echo:hello world
```

## Canary

The text change reverted: both results back to `Response could not be
decoded`. Restored: `echo:` again. dart2js is the control throughout.

## The verdict questions

1. Yes: one canary; dart2js the control.
2. Yes: a real transport on the target the lead named.
3. Yes: the caller's result.
4. Not zero-valued.
5. Yes, quoted.
6. One cause.
7. Not a policy question: no cost to trade.
8. None.

## Gate

`analyze`, `format:check`, `test:unit`, `test:web` (14 suites, all green this
run).

## Not fixed

A user codec that calls `sublist` on its payload under dart2wasm on the web
still meets the SDK bug; the wasm guest copies at its boundary (round 682),
the browser transports do not. node is not a browser: its `WebSocket` stands in
for the browser's.

## Links

Lead `../backlog/B-256-js-backed-bytes-on-the-web-under-dart2wasm.md` closed.
Lens `../lenses/RPC-07-web-as-separate-runtime.md` -- `applied: [..., 699]`.
