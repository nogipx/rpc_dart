---
round: 662
verdict: CLEAN
packages: [rpc_dart_http2]
lens: RPC-22
bench: none — a one-off probe whose control is an in-place ablation; recorded with the negative C-65
commit: yes
release: none
---

# Round 662 — the refusal text nothing foreign reaches

## Target

B-191, an audit lead read statically: `_answerRejectedStream` formats
`'Request rejected: $error'` for any non-`ArgumentError`, bypassing the
default-deny `wireStatusFor`. A disclosure on a path anyone reaches, if a foreign
error can get there. Scope: every throw inside `_handleIncomingMessage`'s try.

## Hypothesis

Some error not of this library's making can be thrown inside that try, and its
text reaches the peer.

## Before

```
POST    grpc-status=0
GET     grpc-status=3  gRPC requires POST; this request used a different HTTP method
BIGHDR  grpc-status=3  Invalid metadata header value for: x-big
NHDRS   grpc-status=3  Too many metadata headers: more than 128
ABLATION (foreign StateError thrown in place)
        grpc-status=13 Request rejected: Bad state: db password=hunter2
```

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/b191_rejected_stream_text.dart`.

## Mechanism

The formatting is as the lead says; nothing reaches it. The sweep: `:method` is
our `ArgumentError` with a fixed message; header conversion and
`validateMetadata` throw only `RpcMetadataViolation`, and `RpcSecurityPolicy` is
`final`; `_emit`'s controllers route listener throws to the zone; the data half
catches its own errors and already uses `wireStatusFor`.

## After

n/a — CLEAN.

## Canary

n/a — no fix. The ablation above is the control: the bench sees a leak when one
exists.

## Gate

n/a — no code change.

## Not fixed

The formatting itself, deliberately: with no reachable foreign error there is no
witness, and a change without one is not a fix. C-65 names it as the thing to
re-check if a throw site is added inside that try.

## Links

Lead `../backlog/B-191-http2-rejected-stream-sends-error-text.md` closed.
Negative `../checked/C-65-no-foreign-error-reaches-the-http2-header-refusal.md`.
Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md` -- `applied: [..., 662]`.
