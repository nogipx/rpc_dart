---
round: 508
verdict: FIXED
packages: [rpc_dart]
lens: RPC-05
bench: P-146 — new
commit: yes
---

# Round 508 — work added to undo work

## Target

The transport-wide broadcast in `channel_transport.dart` — twenty-fourth in the
audit's rank.

Lens RPC-05, the charge/release lens, read on a resource that is not a counter: a
buffered controller charges memory when a message is added and releases it when a
listener takes it. The question the lens asks — *where is it charged, and does
everything reach the release* — has the answer here: a caller-only endpoint charges
on every response and nothing releases, so `startCallerListening` exists to attach a
listener that does nothing except release.

## Hypothesis

`_incoming.add(message)` runs for every inbound message, including responses already
routed to their own stream controller, and a caller-only endpoint needs a no-op
subscription purely so the buffer does not fill.

## Before

With the caller's observer detached, after a server stream is FULLY consumed, a late
subscriber is replayed:

```
  10 messages consumed  ->    11 replayed
 100 messages consumed  ->   101 replayed
1000 messages consumed  ->  1001 replayed
```

Speed, 10 000 small messages, five runs:

```
always broadcast     min 5.805   median 5.987   max 6.154 us/message
```

Benches: `b117_unlistened_buffer.dart`, `b117_broadcast_per_message.dart`

**CONFIRMED on both halves — and the lead has them the wrong way round.** It leads
with the dispatch cost and mentions the leak second. The dispatch cost is about 6%;
the retention is every response the caller already consumed, held for a listener
that may never arrive.

## Mechanism

```dart
final ctl = ...;
if (ctl != null && !ctl.isClosed) { ... ctl.add(message); }
...
_incoming.add(message);          // unconditional
```

The broadcast exists for NEW-STREAM ROUTING: it is how the responder pipeline
discovers a peer-initiated call, and it buffers while unlistened so a call arriving
before that pipeline subscribes is not dropped. A response on a stream we opened
ourselves has already been routed one branch above, so the second dispatch serves
nobody — and on a caller-only endpoint nobody is listening, so it accumulates.

`startCallerListening`'s own doc says this outright: *"this subscription exists to
keep the buffer drained"*. **Work added to compensate for work that should not
happen**, which is the lead's phrase and it is exact.

## After

```
  10 messages consumed  ->  0 replayed
1000 messages consumed  ->  0 replayed

skip when routed     min 5.481   median 5.604   max 5.875 us/message
```

Skip the broadcast when the stream is locally initiated (by id parity — a client
issues odd ids, a server even) AND the message was routed to a live controller.

**Errors are untouched**, which is what makes this safe: a channel failure or a
policy violation with no known stream goes through `_incoming.addError`, so the
caller's observer still has something to observe. The subscription is still needed;
it is no longer needed to drain routed responses.

Regression: `test/transports/a_consumed_response_is_not_retained_test.dart`,
1 WITNESS and 3 GUARD.

## Canary

`if (true || ...)` — always broadcast. The WITNESS fails:

```
Expected: <0>
  Actual: <101>
```

All three GUARDs stay green. The third is the one worth having: it reads the
RESPONDER's broadcast directly off the transport and asserts the ids it sees are odd
— peer-initiated from the server's point of view. If the parity condition were
inverted, every server would stop discovering calls, and a guard that only checked
"the call succeeded" would still pass on the client's half of the suite.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS.

**`test:web` is RED, and not because of this change.** The web-worker suite fails at
the LOAD stage — compile-and-start, never an assertion — and passes alone every
time. This is the second consecutive round it has done so; round 507 spent three
full runs establishing the same thing. **Filed as B-196 rather than absorbed again**,
because a gate that fails intermittently is worse than one that fails: it teaches
the reader to re-run instead of to look, and it forces every round to re-derive that
its own change is innocent. The evidence that it is innocent here is the same as in
507 — it passes alone, and nothing in a web-worker startup path touches channel
broadcast routing.

## Not fixed

**The websocket transport's second broadcast.** The lead names
`websocket_caller_transport.dart` re-broadcasting into `_incomingCtl` with a set
lookup per message. Only the core channel transport was varied, so that one is
unmeasured and untouched.

**`startCallerListening` still exists and is still needed.** It now serves only its
error-observing half. Whether the two responsibilities should be separated — an
error stream distinct from the message broadcast — is a design question with no
measured failure behind it.

**The 6% is not worth quoting on its own.** It is real and the distributions barely
overlap, but next to ~6 us per message it is a rounding error. The record leads with
the retention because that is the part that changes what can go wrong, not what it
costs.

## Links

Lens RPC-05. Bench P-146 (new). Lead B-117 (closed). B-196 (new) is the flaky gate
this round refused to absorb a second time.
