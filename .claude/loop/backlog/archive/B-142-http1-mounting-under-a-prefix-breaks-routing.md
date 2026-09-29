---
status: closed (round 538)
round: 538
commit: 0471c02c
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
probe: P-171
reason: "CONFIRMED exactly as filed and FIXED with the sketch's own one-liner. Unmounted, `url` and `requestedUri.path` are identical — which is why every existing test agreed with the broken reading"
---

# B-142 — HTTP/1.1 responder routes by the full request path

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium-high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`methodPath = request.requestedUri.path`; mounted under `/rpc/` (the doc says it can be mounted anywhere) the path is `/rpc/Svc/M` — refused as invalid or unimplemented.

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart:249`.

## Why it matters

The documented composition does not work.

## What round 538 measured

```
  arm                    methodPath the transport saw   the caller got
  mounted at /rpc        /rpc/Echo/echo           status 3: Invalid method path: /rpc/Echo/echo
  CONTROL not mounted    /Echo/echo               ok: echo:hi
```

Bench `../probes/P-171-does-a-mounted-handler-route.md`. After the fix both rows read `/Echo/echo` and
`ok: echo:hi`.

Two readings from one run, because a wrong path and a missing service give the same status from
different causes. The mount is built from shelf's own primitive — `Request.change(path: 'rpc')`, which
is what `shelf_router.mount` does — so no dependency was added to measure it.

## Fix

The sketch's one-liner, `'/${request.url.path}'`. Shelf's `url` is the path RELATIVE to where the
handler was mounted; the leading slash is added back because `url` never carries one and
`parseRpcMethodPath` requires it.

**Unmounted the two forms are identical**, which is why every existing test agreed with the broken
reading — and why the unmounted control has to be there. The witness also covers a two-level mount, to
rule out a fix that strips one segment by counting rather than by asking shelf.

**A CHANGELOG line is owed**: nothing changes at the root, but a deployment that worked around this by
registering services under a prefixed name would now break.

## Owner decision

—
