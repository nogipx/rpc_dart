---
round: 359
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-19
bench: P-50 — new
commit: yes
---

# Round 359 — the state nobody named

## Target

The owner's 6.0.0 review list, P1 item 10, both halves.

RPC-19, which round 353 widened from a flag to any signal carrying two meanings.
This is the lens back on its original subject — a lifecycle FLAG — and the
defect is the third possibility neither of its two values covers.
`_disconnected` distinguishes "closed for good" from "no connection, recovery
expected", and `_reconnectOnce` spends a whole handshake in a state that is the
second and says the first is false.

**Scope counted before the fix.** Every method on the transport, against every
state it can be in — that is the bench, and the count is the table.
`_ensureUsable()` guards four of six; the two it does not are
`releaseStreamId` and `finishSending`, deliberately, because both run from
`finally` blocks where a throw masks the error that got there. Their own comment
says so: *"a stale id is DROPPED, never raised on"*.

So the class is: **methods that should refuse work when there is no socket, and
the states in which they do.** Six methods, three states, eighteen cells.

## Hypothesis

`_disconnected` is set in the catch of `_reconnectOnce` — the factory failed —
and nowhere else. But `_inner.close()` happens BEFORE the factory is awaited, so
between those two points there is no socket and the flag says there is. If
`_ensureUsable()` passes there, work goes into a closed inner.

## Before

```
method                 healthy     in-window               disconnected
createStream           id=3        id=3                    StateError
sendMetadata           returned    returned                StateError
sendMessage            returned    returned                StateError
sendDirectObject       Unsupported Unsupported             Unsupported
finishSending          returned    returned                returned
getMessagesForStream   HUNG        RpcStatusException(14)  StateError
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/calls_inside_the_reconnect_window.dart`.

`healthy` and `disconnected` are the two states the code means to have; they are
the controls, and the in-window column should equal one of them. It equals
neither. Sends are ACCEPTED and dropped by the closed inner — the caller then
waits out a deadline for a frame that was never on the wire — and a read answers
**UNAVAILABLE, which is retryable**, inviting the caller to repeat the thing that
cannot work.

## Mechanism

```dart
await _inner.close();
final ws = await _reconnectFactory();   // tens to hundreds of ms
...
_disconnected = false;                  // only on success
} catch (e) {
  _disconnected = true;                 // only on failure
```

The flag describes the OUTCOME of the reconnect and nothing describes its
DURATION. `RpcChannelTransport` answers a closed transport quietly —
`sendMetadata` and `sendMessage` are `if (_closed) return;` — so nothing above
notices.

## After

```
method                 healthy     in-window               disconnected
createStream           id=3        StateError              StateError
sendMetadata           returned    StateError              StateError
sendMessage            returned    StateError              StateError
sendDirectObject       Unsupported StateError              StateError
finishSending          returned    returned                returned
getMessagesForStream   HUNG        StateError              StateError
```

One line: `_disconnected = true` immediately after `_inner.close()`. The
in-window column now equals the disconnected column, which is what "the window
is a disconnected state" means when written down.

## Canary

Two halves, two canaries, each failing only its own witnesses.

```
_disconnected = true after close()  removed
  a send inside the reconnect window is refused
    Expected: throws <Instance of 'StateError'>  Actual: <Instance of 'Future<void>'>
  a read inside the reconnect window is refused, not UNAVAILABLE
    Expected: throws <Instance of 'StateError'>
      Actual: <Closure: () => Stream<RpcTransportMessage>>
  +3 -2, all three GUARDs green

_ensureUsable() in sendDirectObject  removed
  sendDirectObject is refused inside the window, like its siblings
    Expected: throws <Instance of 'StateError'>  Actual: <Instance of 'Future<void>'>
    stack: channel_transport.dart 551  RpcChannelTransport.sendDirectObject
  +5 -1, only its own witness
```

The GUARD that matters most is **the window ENDS**: a transport that refused
forever would pass both witnesses and be far worse than the defect. Two more pin
what must not change — a healthy transport still accepts work, and the teardown
paths still do not throw.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos exec --scope=rpc_dart_websocket -- fvm dart test` `+154`;
`melos run test:unit --no-select` SUCCESS at load 5.94;
`melos run format:check` SUCCESS; `melos run license:check` 1354/1354.

## Not fixed

**The second half has no reachable failure, and that is stated rather than
implied.** `RpcWebSocketCallerTransport.supportsZeroCopy` is `false`, so
`caller_pipeline.dart` throws `ArgumentError('Zero-copy requires a transport
that supports zero-copy')` before the transport is reached, and the frame
channel underneath raises `UnsupportedError` whatever the state. The missing
`_ensureUsable()` therefore changed nothing observable through the library's
API. It is fixed for consistency — it was the one send method of three without
it — and it is witnessed at the transport level, where the guard does change the
answer from the inner's `UnsupportedError` to the explicit `StateError`. A guard
with a witness beats a guard without one (L-04), even a cheap one.

## Links

Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md`, fifth application —
back on a FLAG after round 353 widened it to signals.
Bench `../probes/P-50-calls-inside-the-reconnect-window.md`, new.
Catalog shapes U-18 and U-19 — the evidence is a parity matrix, and the defect
is the cell where two axes disagree.
Lesson `../lessons/L-04-a-guard-with-no-witness.md` for the second half.
