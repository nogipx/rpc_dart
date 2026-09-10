---
status: open
round: 313
commit: 6a35cb7a
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport_web.dart]
probe: none
reason: "owner decision — the only route to a witness widens a transport's surface (@visibleForTesting or a factory) for a platform the ordinary gate does not run; that is a trade about API shape, not a bug fix"
---

# B-31 — the isolate web channel has no reachable witness

Round 310 fixed a real defect in `_WebMultiplexedChannel.send`: a payload that
cannot be structured-cloned closed the WHOLE channel, killing every other
in-flight call, and `catch (_)` dropped the reason so the caller saw
UNAVAILABLE. The VM sibling throws a named error and stays open, and its comment
explains why closing is wrong.

The fix is analyser-verified and sibling-verified. **It has no test.**

## The three routes, and why each fails

1. **Through the public API.** `RpcIsolateTransport.spawn` builds a real
   `Worker` from a script URI, so it needs a browser. `melos run test:unit`
   cannot run it; `melos run test:wasm` is a different package
   (`rpc_dart_wasm`) with its own harness and does not cover this one.

2. **Directly on the channel.** This is the route that *should* work, and it is
   one line: the class takes its transmit function as a constructor parameter —

   ```dart
   _WebMultiplexedChannel({
     required Stream<dynamic> messageStream,
     required void Function(Map<String, Object?> data) send,
     void Function()? onClose,
   })
   ```

   so a stub that throws reaches the defect with no Worker at all. It is
   library-private, and Dart privacy is per-LIBRARY: a test cannot name
   `_WebMultiplexedChannel` even importing the file directly. This is the same
   wall `src/`-importing solved for round 307's helpers, and it does not help
   here, because the barrier is the underscore rather than the export.

3. **Make it visible.** `@visibleForTesting` on the class, or a
   `@visibleForTesting` factory that hands back an `IRpcMultiplexedChannel`.
   Works, and is the only thing that does.

## Why this is the owner's call

(3) widens a transport's surface — even annotated, the class becomes nameable —
to test a platform the ordinary gate never runs. That is a trade between API
shape and coverage, and the standing requirements do not settle it: the
"ask before trading speed" rule is about speed, and nothing here covers
"ask before widening a surface for a test".

There is a cheaper variant worth weighing: extract the send-failure POLICY (what
a non-cloneable payload does) into a tiny internal function in the same file,
public within the package the way `unconsumedWindowFor` now is, and test that.
It does not exercise the channel, so it witnesses the decision rather than the
integration — weaker, but free of any surface change.

## What it would cost

Route 3: one annotation plus a ~40-line test. The test runs on the VM, since
nothing in the channel's failure path needs `dart:js_interop` — only the
`_send` callback does, and the test supplies it.

The cheaper variant: ~15 lines, and a weaker claim.

## Owner decision

—
