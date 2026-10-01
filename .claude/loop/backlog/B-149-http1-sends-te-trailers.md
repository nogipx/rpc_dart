---
status: closed (round 586)
round: 586
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: packages/transport/rpc_dart_http/.dart_tool/probe/b149_what_te_trailers_reaches.dart
reason: "CONFIRMED that the header travelled and was charged to maxMetadataBytes (10 request-metadata headers -> 9), and REFRAMED: core filters `te` by name, so no handler ever saw it. Removed. The browser half is unverified and now moot"
---

# B-149 — HTTP/1.1 caller sets `te: trailers`, which nothing uses and browsers refuse

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The status travels in ordinary response headers on this wire format; `te` is a forbidden header name in browsers (XHR logs "Refused to set unsafe header" on every call).

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart:341-342`, doc `:88-91`.

## Why it matters

Console noise per call on web; a misleading comment.

## Witness a round would build

Browser test: console warnings per call.

## Fix sketch

Remove it.

## Measured — round 586

The lead's witness is a browser console, which the web gate cannot run reliably
(`B-215`). The question a VM can answer is where the header GOES, and that is the
better question:

```
before   headers delivered 10, carries `te` YES
after    headers delivered  9, carries `te` no
```

Read on the responder TRANSPORT's `incomingMessages`, over a real socket, both ends
rpc_dart. The other nine names are unchanged.

**CONFIRMED that it travelled**, on every call, counted by the transport's
aggregate `maxMetadataBytes` check. It is also hop-by-hop per RFC 9110 s7.6.1, so a
proxy strips it — no responder could rely on it even if this format had trailers,
which the caller's own class doc says it does not: *"All response headers
(including grpc-status) are in HTTP headers."*

**REFRAMED on where it stopped.** Core's `_createContextFromMessage` excludes `te`
by name, next to `content-type`, so no handler ever saw it. The lead's picture — a
useless header reaching the application — was not what happened. That filter has to
stay: `rpc_dart_http2` sends `te: trailers` and the gRPC HTTP/2 spec requires it
to. Which puts the defect exactly where the fix went: one transport sending a
header its own wire format has no use for, cleaned up downstream by a filter that
exists for the transport which needs it.

Removed, with the reasoning in its place.

## What this lead does NOT cover

- The browser claim is from the Fetch spec's forbidden-header-name list, not from a
  run. Removing the header makes it moot either way, which is the only reason this
  closes without a browser.
- No byte total: eleven characters once per request is not a limit problem and the
  round does not claim it is.

## Owner decision

—
