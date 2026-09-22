---
status: closed (round 428)
round: 313
commit: 6a35cb7a
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport_web.dart]
probe: none
reason: decided — take route 3, `@visibleForTesting` plus the ~40-line VM test; the surface widening is worth a real witness over the cheaper variant's weaker claim
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

**Taken: route 3.** `@visibleForTesting`, and the test that actually drives the
channel.

The cheaper variant is declined on what it would witness. Extracting the policy
proves the decision — "a non-cloneable payload must not close the channel" — and
leaves untested the thing round 310 actually got wrong, which was where that
decision is APPLIED: the `catch (_)` that swallowed the reason and the close
that took every other in-flight call with it. A test that cannot see the other
calls survive is not a witness for this fix.

The cost is contained in a way that matters here: the test runs **on the VM**.
Nothing in the failure path needs `dart:js_interop` — only the `_send` callback
does, and the test supplies it — so this buys coverage of a web-only defect
without adding anything to the browser gate.

The witness must show both halves, since either alone passes on a wrong fix:
the failing send reports a NAMED error, and a second call on the same channel
still completes.

## CLOSED — round 428, and NOT by route 3

**Route 3 could not have worked, and the reason is one level below where this
lead was looking.** Its selling point was "the test runs on the VM, since
nothing in the channel's failure path needs `dart:js_interop`". True of the
PATH. A test imports a FILE, and `isolate_transport_web.dart` opens with
`dart:js_interop` and `package:web`:

```
Failed to load "test/b31_import_probe_test.dart":
  .../isolate_manager/lib/src/utils/extract_array_buffers.dart:6:9:
    Error: Type 'JSArrayBuffer' not found.
  .../web-1.1.1/lib/src/helpers.dart:81:10:
    Error: Type 'JSFunction' not found.
  ... ~20 000 characters of the same
```

`@visibleForTesting` makes a class nameable; it does not make a library
loadable. Route 2's diagnosis — "the barrier is the underscore rather than the
export" — was half the barrier.

**What was done instead**: the channel, the wire format and the helpers moved to
`lib/src/web_bridge.dart`, which imports `dart:async` and rpc_dart and nothing
else. Read first, then proven by compiling — the JS dependency is all in
`spawn`, `_workerSelf` and the isolate_manager controllers.

**Cheaper on the axis this lead was worried about.** Route 3 would have
annotated a class inside a file the package barrel conditionally EXPORTS.
`web_bridge.dart` is exported by nothing, so the public API is unchanged and the
class is testable — the trade this lead called the owner's call did not have to
be made at all.

The witness asserts both halves plus one more (the channel still RECEIVES), and
two ablations separate the clauses: closing on a send failure fails all three
witnesses, swallowing the reason without closing fails only the first.

`../rounds/428-the-file-the-test-could-not-import.md`.
