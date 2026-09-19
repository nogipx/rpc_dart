---
round: 413
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-15
bench: none — the evidence is B-62's own sweep plus four assertions on the type, one of them the deny that had to survive
commit: yes
---

# Round 413 — the envelope that threw it away

## Target

B-62, which round 409 filed and deferred. `RpcHttp2StreamError` is the last
type in core or the transports outside the hierarchy — and `rpc_dart_http2` is a
transport, so it is inside the goal, not outside it.

## Hypothesis

409's framing still holds: two opposite fixes, no number to choose between them.

## Before

It does not hold, because **round 412 changed the calculus**. RPC-15 in its
plainest form: a deferral's stated blocker re-read after the ground moved.

409 weighed "restore `filterStreamEvents`" against "drop the envelope", and
called it even because the envelope is what distinguishes a per-stream error
from a connection-fatal one, which is the thing it was introduced for. Both
options were about ROUTING.

Round 412 then gave every library error the status that fits. The envelope is a
plain class, so `wireStatusFor` takes its DENY branch:

```
inner                                            peer was told
RpcStatusException(resourceExhausted, 'max: 16') INTERNAL "Internal server error"
RpcStatusException(unimplemented, 'no method')   INTERNAL "Internal server error"
```

Every status the type system had just been given was thrown away one layer out.
That is a third option neither of 409's two describes, and it needs no number:
the envelope can keep doing its routing job AND stop destroying the status.

## Mechanism

`RpcHttp2StreamError extends RpcStatusException`, deriving its status and
message **through `wireStatusFor(error)`** rather than reading the inner's
fields.

Deriving rather than copying is the whole safety argument: `wireStatusFor` is
the single place that decides what may leave this process, so a FOREIGN inner
error is still redacted. Copying `inner.statusCode` would have worked for ours
and silently opened the deny for everyone else's.

`streamId` and `error` are untouched, so the routing the envelope exists for is
unchanged.

## After

```
limit        statusCode resourceExhausted, message contains 'max: 16'
unimplemented statusCode unimplemented
foreign      statusCode internal, message == kInternalErrorWireMessage
```

## Canary

`the_envelope_keeps_the_status_test.dart`, four tests, two of them GUARDs:

- **a foreign inner error is still redacted** — the load-bearing one. Deriving a
  status from a wrapped error is exactly the shape that could become a way
  around default-deny, and this is the assertion that says it did not.
- the envelope still carries its `streamId` and the identical inner object,
  because dropping either would break per-stream routing silently and no
  existing test watches those fields.

## Gate

`melos run analyze` clean over 21 packages + wasm; `format:check` clean;
`license:check` compliant; workspace suite **SUCCESS in all 14 packages**,
rpc_dart_http2 **+234**.

## Not fixed

`filterStreamEvents` still has no production call site — that half of B-62 is
unchanged and is now purely about routing, which is where 409 left it. It is no
longer urgent: the envelope reaching a broadcast consumer is now classifiable,
so the missing unwrapper costs precision, not correctness.

Outside the goal's scope and named rather than touched: four types in `data/`
and `blob/` — `SqlCipherException` twice, `ImportResumeException`, and
`SchemaValidationError` / `SchemaMigrationError`, which are not `Exception`s at
all.

## Links

- B-62 — closed here, except the unwrapper
- Round 412 — which made this worth fixing by giving the inner errors statuses
- RPC-15 — a deferral re-read after the ground under it moved
