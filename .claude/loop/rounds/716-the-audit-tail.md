---
round: 716
verdict: FIXED
packages: [rpc_dart_http2, rpc_dart_wasm, rpc_dart, rpc_dart_websocket, rpc_dart_http]
lens: RPC-06
bench: none — `.dart_tool/probe/b266/proxy_tls_socket.dart`; the native fixes by reading, with the device suite as the regression check
commit: yes
release: changelog
---

# Round 716 — the audit tail

## Target

B-266, the six minor items of the audit after round 710, with the owner's
decisions: fix the proxy TLS socket; document items 3, 4 and 6; items 1 and 2
are mine to fix.

## Hypothesis

Item 5: the caller's proxy path bounds its TLS handshake by destroying a Socket
that `SecureSocket.secure` has taken over, which round 712 measured not to
close it.

## Before

```
caller: TLS handshake through the proxy did not finish within 1s
proxy side: STILL OPEN 5s after the timeout
```

## Mechanism

As hypothesised.

## Fix

- **Item 5.** The proxy path runs on a `RawSocket` end to end: the CONNECT
  exchange on raw events, then `RawSecureSocket.secure`, which leaves the
  socket closable. `RawSocketPipe` adapts it to the stream and sink HTTP/2
  takes. `RawSecureSocket.secure` refuses a paused subscription, so the CONNECT
  stage stops reads with `readEventsEnabled` instead of a pause.
- **Item 1.** Android: `registerByteChannel` and `provideNamedData` moved
  inside the boot's `try`, whose catch already unregisters and closes.
- **Item 2.** iOS: the scheme handler holds the answer to a host send while its
  guest queue is over 1 MiB, and answers held sends as `/recv` drains it or the
  runtime stops. The host's send pump awaits each answer, so the queue is
  bounded.
- **Items 3, 4, 6** documented: codecs must not `sublist` a payload view
  (skill), no total cap on h1 request bodies (README), what websocket
  compression gives up (README).

## After

```
caller: TLS handshake through the proxy did not finish within 1s
proxy side: closed by the caller
```

## Canary

The library stashed: the extended `a_silent_tunnel_is_bounded` witness times
out waiting for the proxy to see the close. Items 1 and 2 have no canary: no
device test makes `provideNamedData` throw or stops the guest from polling.

## The verdict questions

1. Yes for item 5. 2. Yes. 3. Yes. 4. Not zero. 5. Quoted. 6. One cause per
item. 7. Not a trade. 8. None.

## Gate

`analyze`, `format:check`, `check:skills`, rpc_dart_http2 suite (300 + 2 pipe
tests), `analyze:native`, `test:wasm:device` on the Android emulator (30
passed, 4 skipped) and the iOS simulator (32 passed, 2 skipped).

## Not fixed

Items 1 and 2 are verified by reading and the regression suite only.

## Links

Lead `../backlog/B-266-audit-minor-items.md` closed.
Lens `../lenses/RPC-06-native-plugin-layers.md` -- `applied: [..., 716]`.
