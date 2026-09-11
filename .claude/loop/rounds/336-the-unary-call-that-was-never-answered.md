---
round: 336
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none
commit: yes
---

# Round 336 — the unary call that was never answered

## Target

Round 334's defect lived in one of the responder pipeline's zero-copy/serialized
branch PAIRS, and round 335 checked only one property of those pairs — which
arguments each passes. The rest of the pair surface was unexamined, on a shape
with a proven defect history.

## Hypothesis

The pairs differ somewhere else: cleanup wiring, state registration, or error
handling.

## Before

The three streaming pairs are symmetric — `state.responder =`, `_detached(...
_cleanupStream)`, the same bind call, and for bidi the same pump, the same
`finishReceiving`, the same `wireStatusFor` catch. Nothing.

The UNARY pair is not a pair: the zero-copy branch hand-rolls its dispatch over
`_RpcZeroCopyUnaryResponder` + `StreamProcessor`, and it carries this comment:

> The request stream can fail before a request exists — a peer whose payload
> SHAPE does not match this method's mode reports it here. With no handler the
> error was a dropped future and the caller got UNAVAILABLE "Stream closed
> without receiving response", which says nothing about the cause. It also has to
> be answered: **the three streaming shapes already route their request-stream
> errors, and this one did not.**

An earlier round fixed the zero-copy branch and asserted the streaming shapes
were fine. Nobody asked about the serialized unary branch — the default for
every codec-based unary method. `UnaryResponder`'s `onError`:

```dart
onError: (Object error, StackTrace stackTrace) async {
  _logger.error('Transport error for $_methodPath', ...);
},
```

Driving each shape with a request stream that errors before any request arrives
(`.dart_tool/probe/unary_request_stream_error.dart`):

```
ServerStreamResponder    status 13 sent to the peer
UnaryResponder           NONE
```

## Mechanism

`StreamProcessor.bindToMessageStream`'s `onError` forwards into
`_requestController`, so the handler sees the error and the surrounding
machinery answers — that is the streaming shapes' routing, and the claim in the
comment is true. `UnaryResponder` does not use `StreamProcessor`: it subscribes
to the transport's global `incomingMessages` itself, and its `onError` only
logs.

The `onDone` branch eight lines above it DOES answer, with
`invalidArgument "Request not received: stream closed without data"`. So the
same method both knows how to answer and fails to.

## After

`onError` now answers every unguarded stream it owns with `wireStatusFor(error)`,
mirroring the zero-copy branch:

```
UnaryResponder           NONE  ->  status 13
rpc_dart suite           +1440 ~1  ->  +1443 ~1
```

## Canary

```
fix in place       witness passes, both guards pass
fix ablated        Expected: non-empty  Actual: []
                   'the caller is left waiting for a response that never comes'
                   both GUARDS still pass
```

The two guards are what stop the fix being "answer everything with an error":
the streaming shape must still answer (the control the fix was measured
against), and a healthy unary call must still return its response rather than a
status.

## Gate

`melos run analyze` clean over 21 packages plus `rpc_dart_wasm`;
`format:check` clean; `test:unit` 14 packages, 0 failures — `rpc_dart`
`+1443 ~1`, `rpc_dart_http2` `+204`, `rpc_dart_websocket` `+137`.

## Not fixed

Nothing outstanding on this shape. The three streaming pairs were read in full
and are symmetric.

## Links

RPC-25 (`applied:` gains 336). The lens says to read the METHODS around a shared
field side by side; this is the same instruction applied to two branches of one
`if`, which is where rounds 334 and 336 have now both found defects.

> **A comment that says "the others already do this" is a claim about the
> others, and it names them.** The zero-copy branch's fix asserted three
> streaming shapes were fine — true — and silently excluded the fourth shape
> from its own count, because the author was inside the zero-copy branch and the
> serialized one is a different method. Re-read such a comment as a CHECKLIST:
> every shape it does not name is a shape nobody checked.
