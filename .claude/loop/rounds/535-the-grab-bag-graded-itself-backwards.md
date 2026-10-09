---
round: 535
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-13
bench: P-168 — new
commit: yes
severity: S1
---

# Round 535 — the grab-bag graded itself backwards

## Target

B-139, next in rank order: seven item groups of "smaller defects and hygiene", with the note that
"items 1 and 6's unhandled future are behaviour, not style".

Lens RPC-13 — an unhandled async error — reached by way of the same argument round 526 made about
B-129: a grab-bag lead does not merely under-state severity, it randomises it. So the round examined
the two items the lead itself singles out, and inverted both.

## Hypothesis

Item 1: `close()` cancels the read subscription before `sink.close()`, so dart:io falls back to its
multi-second timer on a clean close.

## Before

```
  arm                                   close() took (min of 5)   all
  as shipped: cancel, then sink.close    0ms                      [4, 0, 0, 0, 0]
  swapped:    sink.close, then cancel    0ms                      [0, 0, 0, 0, 12]
  CONTROL raw dart:io WebSocket.close    0ms                      [0, 0, 0, 0, 12]
```

Bench `../probes/P-168-what-does-a-clean-close-cost.md`.

**Item 1 REFUTED, with the control that makes the refutation mean something**: the raw SDK close,
with no channel involved, is the same zero. Cancelling the subscription does not stop the handshake,
because the SDK's close and ping machinery sits BELOW the subscription — in the transformer, not in
the listener.

**Item 3 refuted by reading**: there is one `@override` on `sendDirectObject`, not two.

## Mechanism

The item the lead buried in a list of six sub-points is the real one.
`_handleConnection`'s failure path ended in a bare `channel.sink.close()` — an unawaited Future with
no error handler, in a method that runs in the accept loop's event handler. That is the ROOT ZONE,
which this very file's comments name four times: an unhandled async error there kills the isolate.

And a close rejecting is not exotic — it is the state a failed setup tends to leave a socket in.

## After

Guarded exactly like the refusal path eighty lines above it:
`unawaited(Future<void>.sync(channel.sink.close).catchError(...))`. `Future.sync` so a SYNCHRONOUS
throw from `close` is covered too.

## Canary

Reverted to the bare `channel.sink.close()`: the witness fails, and the failure names
`_ThrowingSink.close` as the unhandled source rather than any expectation of the test. The control
passes in that state.

The witness drives both failures at once — a channel that cannot be listened to and a sink that
cannot be closed — and then requires the server to SERVE a real call afterwards. "Still running" is a
flag; answering a call is what says the accept loop and the isolate both survived.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check` — all green. The websocket package: 237
passed.

## Not fixed

**B-139 stays OPEN, with four of seven item groups unexamined.** This round did items 1, 3 and 6's
unhandled future. What remains:

- **item 2** (mapping rows said to be dead) is a judgement call and probably wrong: the rows encode
  the intended mapping, a test pins them, and deleting them makes `_ => unknown` the answer for a
  clean close the moment the function gains a second caller. Round 528 also made 1002 reachable,
  which the item predates.
- **item 4** (`connect()` captures `headers` once, so an expiring token cannot be refreshed) is a
  FEATURE — a headers callback — not a defect, and the code's existing comment argues deliberately
  for reusing them. Features leave the loop by the B-01 precedent.
- **item 5** (a record allocated to silence the analyzer) is a documented deliberate choice with a
  comment explaining it, once per connect.
- **item 6's other five sub-points** (duplicated branches, `onEndpointCreated` ignored in peer mode,
  `createWithContracts` dropping `logController`, no connection cap) and **item 7** (the responder
  transport forwarding every member) are untouched. The connection cap is the one among them with a
  plausible severity, and nothing here measured it.

**The severity inversion is the round's finding and it is now twice-observed.** B-129 and B-139 are
both external-audit grab-bags, and in both the items the lead flagged as behaviour were the cheap ones
while a real defect sat inside a bulleted sub-list. Splitting before working is not a preference.

## Links

Lens RPC-13. Bench P-168 (new). Lead B-139 still open. Round 526 made the same argument about B-129;
this is the second instance, in a different lead, from the same intake.
