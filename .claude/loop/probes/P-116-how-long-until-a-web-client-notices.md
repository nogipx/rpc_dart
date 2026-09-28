---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/how_long_until_a_web_client_notices.dart
round: 466
commit: 0d6924e8
paths: [packages/transport/rpc_dart_websocket/lib/src/ws_open_stub.dart, packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
status: valid
---

# P-116 — how long until a web client notices?

## Why it exists

B-71 was filed from a READ (`probe: none`) and claims *"a web client on a
half-open path has no liveness signal at all"*. "None" and "slower" are different
leads, so the gap needs a number before a fix is designed for it.

Both `openWebSocket` implementations are importable on the VM — **the stub IS the
portable fallback as well as the web one** — so the arms differ in exactly the
implementation under test, against one server, at one interval. No browser
needed.

## The harness — and why the server has to be raw

A RAW `ServerSocket` that completes the WebSocket handshake by hand (SHA-1 over
the key plus the GUID, a 101) and then answers **nothing**, pings included.

**That is the whole point.** A `dart:io` WebSocket server answers a ping inside
its own implementation, so against one of those neither arm can ever detect
anything and both read "clean" — a control that passes on broken code.

Second half, for the owner's third question: what a heartbeat would COST. The
heartbeat does not exist yet, but what it would send does — `caller.ping()` — so
the cost is measurable today as a long server-stream with and without pings at
heartbeat rate.

## The numbers (round 466)

```
a silent peer, pingInterval = 300ms, cap 5s
  ws_open_io   (dart:io, honours it)     626ms      ~2 intervals
  ws_open_stub (web, DROPS it)           NEVER (capped)
  CONTROL: ws_open_io, no interval       NEVER (capped)
```

The lead's claim, with a number: detection at about twice the interval where the
parameter is honoured, and none at all where it is dropped.

Cost, 120000 x 1 KiB, two runs:

```
                      run 1     run 2    pings landed
no heartbeat          4380ms    4806ms
ping every 300ms      4741ms    5492ms    15 / 18
ping every 50ms       4124ms    4764ms    77 / 86
no heartbeat          4096ms    4558ms
```

## Measures

Time from open until the channel reports the path is gone (`onError` or
`onDone`), capped; and for the cost half, wall-clock to drain the stream plus the
number of pings that actually completed.

## Control

Three, and each caught something:

- **`ws_open_io` with NO interval**, which is what the stub effectively is:
  `NEVER`. Without it, "io detects" is equally consistent with `dart:io` noticing
  for some other reason.
- **Two identical no-heartbeat arms, first and last**, which quantify the
  run-to-run and ordering spread: 4380/4096 and 4806/4558, about 7%.
- **The ping COUNT**, which is what exposed a void arm. At 2000 messages the
  stream finished in ~100 ms and **zero pings landed in either heartbeat arm** —
  reading as "the heartbeat is free" while measuring nothing (L-15). The message
  count was raised until pings landed.

## What it establishes, and what it does not

Establishes: the gap is real, it is total, and the honoured path detects in ~2x
the interval.

**Does NOT establish what a heartbeat costs.** The 300 ms arm is the slowest in
both runs while carrying a FIFTH of the pings of the 50 ms arm, which is
incoherent as a dose-response and is the signature of the fixed arm ORDER rather
than of ping load. The bound the bench supports: smaller than the ~7-15% spread
at 120 MB, with no dose-response visible. Resolving it needs randomised or
interleaved arms.
