---
round: 308
verdict: FIXED
packages: [rpc_dart, rpc_dart_http, rpc_dart_http2]
lens: RPC-25
bench: none
commit: yes
---

# Round 308 — four routers, and the one that drifted

## Target

The THIRD clause of the owner's mandate — "навести порядок в самом коде и
абстракциях" — which 293-307 did not touch. Every one of those rounds reports
zero or near-zero code lines changed, and the owner's stop hook said so twice.

No lens covered it. RPC-23 is about prose and RPC-24 about the export surface;
forcing this into either would have produced cosmetic edits dressed as
structural ones. So this round derives one — RPC-25 — and applies it.

## Hypothesis

Four transports implement one interface, written at different times. Where the
interface gives them nothing, each will have hand-rolled the same helper, and at
least one copy will have DRIFTED — because no file imports another, so nothing
can bring the difference to anyone's attention.

## Before

Step 1 of the new detector, a field every sibling declares:

```
grep -n "_streamControllers" packages/transport/*/lib/**

rpc_http_caller_transport        10 references
rpc_http_responder_transport      8
rpc_http2_caller_transport       10
rpc_http2_responder_transport    10
```

Four copies of a per-stream router: the `Map<int, StreamController<...>>`, a
create-or-reuse `getMessagesForStream`, an `_emit` that routes to both the
broadcast and the per-stream controller and closes it on end-of-stream, an
`_emitError`, and a close loop. **121 lines across four files.**

## Mechanism

**The extraction is not the finding. The drift it exposed is.**

Step 3 asks what each copy does that the others do not.
`rpc_http2_caller_transport.getMessagesForStream`:

```dart
final existing = _streamControllers[streamId];
if (existing != null) return existing.stream;        // NOT metered
final ctl = StreamController<RpcTransportMessage>(...);
_streamControllers[streamId] = ctl;
return _fcMetered(streamId, ctl.stream);             // metered
```

A REPEAT call for the same stream returns the stream without flow-control
metering. `_fcMetered` is what discharges `_fcOutstanding` as a consumer takes
bytes, so that consumer never discharges: the counter only climbs, and the call
is refused at `_fcWindow` for bytes it did in fact consume.

Its own sibling — `rpc_http2_responder_transport`, the same twenty lines in
another file of the same package — meters BOTH paths, and is correct.

Nothing could have caught this. The two files never import each other, the
analyzer sees two valid methods, and the suite passes because a second
`getMessagesForStream` for one stream is the uncommon path. It is visible only
with the four side by side, which is exactly what the extraction forces and what
the lens now prescribes.

The shared `RpcStreamRouter` went into `rpc_dart`'s `src/core/`, beside
`BufferedBroadcastController` — which RPC-24 established is transport-authoring
API rather than an internal, and which all four transports already use. It owns
the per-stream half ONLY; each transport keeps its own broadcast, because
extracting that too would have forced three different error-envelope policies
into one class.

Two specialisations were kept rather than merged away, and shaped the API:

- http2 wraps the router's stream in `_fcMetered`; the http pair does not.
- the http caller reports `_closedDuringCall()` on close but only for streams
  IN FLIGHT — which is why `closeAll` takes `Object? Function(int streamId)` and
  honours a null return. My first draft took a non-nullable `Object Function(int)`
  and could not express it; the transport is what corrected the abstraction.

## After

```
                                    lines
the four hand-rolled copies           121
RpcStreamRouter (core, new)            57

transports, net                       -64   (57 insertions, 121 deletions)
```

Behaviour identical everywhere except the drift, which is now fixed:
`getMessagesForStream` on the http2 caller is metered on every call.

## Canary

**The test suite is not the witness here** — it passed before and after, which
is the whole reason the drift survived. The honest witness is the code:
`_fcMetered` now wraps the single expression the method returns, so there is no
second path for it to be missing from. Reintroducing the defect means writing
the two-branch form back.

The suite's role is the other half: it proves the extraction changed nothing
ELSE across four transports. 14 packages, 0 failures.

## Gate

`melos run analyze` — 21 packages plus rpc_dart_wasm, no issues.
`melos run test:unit --no-select` — 14 packages, all passed, 0 failures.
`melos run format:check` — SUCCESS, 0 changed.
`melos run license:check` — compliant, 1306/1306.

The first `melos run analyze` was RED: 5 errors, `RpcTransportMessage` imported
from `message.dart` where it lives in `transport.dart`. Recorded because it is
the gate doing its job on a cross-package refactor, and because the LSP is what
answered it in one query.

## Not fixed

RPC-25's detector names other candidates in this repo, unswept:

- `_drain` / `_inFlightCalls` — the same 25 ms poll-until-deadline loop in
  `RpcHttp2Server`, `RpcWebSocketServer` and `RpcHttpServer`.
- `_notify` — near-identical in `RpcHttp2Server` and `RpcWebSocketServer`, both
  guarding a user callback on a detached path.

Both are servers rather than transports, and each deserves its own step-3 diff
before anything is merged: the point of the lens is the drift, not the line
count.

## Links

RPC-25 (new, `applied: [308]`), and RPC-24 for where the shared type had to go —
a shared helper is a new public promise, so it is chosen rather than emitted.

The mandate's three clauses now each have a lens: RPC-23 for the doc comments,
RPC-24 for the boundary, RPC-25 for the code and its abstractions.
