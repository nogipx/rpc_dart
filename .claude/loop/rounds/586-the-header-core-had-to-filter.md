---
round: 586
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-23
bench: P-206 — new
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
---

# Round 586 — the header core had to filter

## Target

`B-149` — the HTTP/1.1 caller sets `te: trailers`, with the comment *"Required by
gRPC-over-HTTP/1.1 to signal trailer support."* Filed **medium** confidence,
`cost`, and its witness line asks for a browser console.

Lens RPC-23: prose beside the code that names something which cannot be true. The
class doc fifty lines above says, of this wire format: *"All response headers
(including grpc-status) are in HTTP headers."* There are no trailers here to
signal support for, and "gRPC-over-HTTP/1.1" is not a specification.

## Hypothesis

The header is sent for a reason the same file contradicts, and it goes somewhere.

## Before

```
headers delivered   10
names               [accept-encoding, content-length, content-type,
                     grpc-accept-encoding, host, te, user-agent,
                     x-request-id, x-route-service, x-trace-id]
carries `te`        YES
```

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/b149_what_te_trailers_reaches.dart`.

**The reading is taken on the responder TRANSPORT's metadata, not on the handler's
context**, and that choice is the round's one real finding — see below.

## Mechanism

`request.headers['te'] = 'trailers'` on every request. The responder builds
`RpcMetadata(requestHeaders)` from every header it received, and its aggregate
`maxMetadataBytes` check sums name and value over that list, so the header
travelled and was counted on every call.

It is also hop-by-hop (RFC 9110 s7.6.1), so a proxy strips it — no responder could
rely on it even if the format had trailers.

## Where it stopped, which the lead does not say and the fix depends on

Core's `_createContextFromMessage` excludes `te` **by name**, next to
`content-type`. So no handler ever saw the header, and the lead's framing — a
useless header reaching the application — is not what was happening.

That exclusion has to stay: `rpc_dart_http2` sends `te: trailers` and the gRPC
HTTP/2 spec requires it to. Which places the defect exactly where the fix went —
one transport sending a header its own wire format has no use for, cleaned up
downstream by a filter that exists for the transport which legitimately needs it.

## After

```
headers delivered   9
carries `te`        no
```

The other nine names unchanged.

## Canary

```
the header put back
  WITNESS no `te` reaches the responder as request metadata
    Expected: not contains 'te'
      Actual: [user-agent, te, accept-encoding, content-length,
               grpc-accept-encoding, host, content-type,
               x-route-service, x-trace-id, x-request-id]
```

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart_http +208
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2223 / 2223, REUSE compliant
```

`rpc_dart_http2 +275` unchanged is the arm that matters here: the http2 caller
still sends the header, and must.

## Not fixed

**The browser half is unverified.** The lead's "XHR logs Refused to set unsafe
header on every call" rests on the Fetch spec's forbidden-header-name list, which
is a document and not a measurement. The web gate cannot run this reliably —
`B-215` — so what the round establishes is the VM-side cost and the contradiction,
not the console noise. Removing the header makes the claim moot either way, which
is the only reason this is closable without a browser.

**No byte total.** `te: trailers` is eleven characters charged once per request
against `maxMetadataBytes`; the probe reads presence, not a sum. A header that
cheap is not a limit problem and the round does not claim it is.

**`RpcHeaders.te` stays**, and so does core's filter. Both have one legitimate
caller between them.

## Links

Lead `../backlog/B-149-http1-sends-te-trailers.md` — CLOSED.
Bench `../probes/P-206-what-te-trailers-reaches.md` — new.
Lens `../lenses/RPC-23-the-narrative-beside-the-code.md` — `applied: [586]`.
Lesson: none. The candidate — "read where a thing STOPS, not only that it travels"
— is `measurement.md` item 5 (which side was the number taken on), and the probe
record states it on the arm.
