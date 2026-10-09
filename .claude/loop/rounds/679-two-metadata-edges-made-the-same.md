---
round: 679
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none — the parity matrix filed with the lead (`.dart_tool/probe/parity_matrix.dart`, group 2), re-run
commit: yes
release: changelog
severity: S3
---

# Round 679 — two metadata edges made the same

## Target

B-253, core, decided by the owner: items 1 and 2 of three. Item 3 (transport
headers in the handler context) stays.

- Item 1: a request value with leading or trailing whitespace. Three sites copy
  context headers into request metadata (`UnaryCaller`, the streaming base
  processor, the ping in `caller_pipeline`).
- Item 2: a reserved `grpc-` request header reaching the handler. One site, the
  responder's `_createContextFromMessage`, which every transport feeds.

## Hypothesis

Nothing on the send path looks at value edges, and the responder's context
filter knows `:`-pseudo headers, `content-type` and `te` but not the `grpc-`
prefix.

## Before

```
2.value-whitespace     memory/isolate/websocket/http2 "  v  w  "   http1 "v  w"
2.reserved-grpc-status "7" on all five
```

## Mechanism

As hypothesised.

## Fix

- `RpcHeaders.checkValueEdges(name, value)`: an `RpcMetadataViolation`
  (INVALID_ARGUMENT) for a value starting or ending with SP or HTAB, called at
  the three copy sites -- so the caller refuses before anything is sent.
- `RpcHeaders.isHiddenFromHandler(name)`: `grpc-*` except `grpc-timeout`,
  `grpc-encoding` and `grpc-accept-encoding`, which the framework negotiates
  through the context; the responder skips those keys when it builds the
  handler's context.

## After

```
2.value-whitespace     RpcMetadataViolation/3 on all five
2.reserved-grpc-status <absent> on all five
```

## Canary

`packages/core/rpc_dart/test/endpoint/request_metadata_edges_test.dart`, both
checks disabled: `Expected: 'status 3' Actual: '  v  w  '` and `Expected:
'<absent>' Actual: '7'`. The inner-whitespace and negotiated-header GUARDs
green both ways. Restored: 4 of 4 green.

## The verdict questions

1. Yes: one check per canary; each GUARD is its control.
2. Yes: both rows changed on all five transports.
3. Yes: what the handler saw, and the caller's status.
4. Not zero-valued.
5. Yes, quoted.
6. Two halves, two canaries.
7. Yes; the owner's choice of items.
8. None.

## Gate

`analyze`, `test:unit` (15 packages), `format:check`, `license:check` green.
Another session was adding Agent Skills to the package while this round ran
(a `skills` directory and a root `pubspec.yaml` edit); its files are not part
of this commit.

## Not fixed

Item 3, by decision.

## Links

Lead `../backlog/B-253-request-metadata-edges-differ-by-transport.md` closed.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` -- `applied: [..., 679]`.
