---
file: packages/transport/rpc_dart_http/.dart_tool/probe/b142_mounted_prefix.dart
round: 538
commit: 0471c02c
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
status: valid
---

# P-171 — does the HTTP/1.1 responder route when mounted under a prefix?

## Why it exists

The claim is about a documented composition, so the rig has to BE that composition rather than a
description of it. And it needs two readings from one run: what the transport thought the method path
was, and what the caller got — because a wrong path and a missing service produce the same status from
different causes.

## The harness

A real caller and responder over `shelf_io`, with the mount built from shelf's own primitive:
`Request.change(path: 'rpc')` is exactly what a mount does — it moves a prefix out of `url` and into
`handlerPath`. Same mechanism as `shelf_router.mount`, with no dependency added to measure it.

## The numbers (round 538)

```
  arm                    methodPath the transport saw   the caller got
  mounted at /rpc        /rpc/Echo/echo           status 3: Invalid method path: /rpc/Echo/echo
  CONTROL not mounted    /Echo/echo               ok: echo:hi
```

After the fix both rows read `/Echo/echo` and `ok: echo:hi`.

## Measures

The `methodPath` the transport emitted, and the caller's outcome. The first is what names the cause; the
second is what says it matters.

## Control

**The unmounted arm.** It is also the reason the defect survived: unmounted, `url` and
`requestedUri.path` are identical, so every existing test agreed with the broken reading. A fix that
broke the ordinary case would pass the witness alone.

The witness test adds a two-level mount (`api/v1`), which rules out a fix that strips one segment by
counting rather than by asking shelf.

## What it establishes, and what it does not

Establishes: routing on `requestedUri.path` made the documented "mount on any shelf server or router"
answer INVALID_ARGUMENT for every call under a prefix.

Does NOT use `shelf_router` itself. The mount is emulated through the primitive `shelf_router` uses; if
that package ever mounts differently, this rig would not notice.

Does NOT check the caller side of a prefix. `RpcHttpCallerTransport` takes the prefix as part of
`baseUrl`, which worked in both arms and was never in question.
