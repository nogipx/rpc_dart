---
round: 807
verdict: FIXED
packages: [rpc_dart_http, rpc_dart_websocket]
lens: RPC-18
bench: P-279 — reused
commit: yes
severity: S3
release: breaking
---

# Round 807 — a redirect is a refusal

## Target

B-276, decided by the owner 2026-10-10: fix it, a 303 becomes a refusal
like 301/307/308. The last decided lead. In the round the owner also chose,
when asked, to apply it on the web too, where a browser followed every
redirect and now reports it as a fetch error.

## Hypothesis

`RpcHttpCallerTransport` leaves `followRedirects` at its default, so dart:io
follows a 303 itself as a GET with every metadata header but
`authorization`.

## Before

P-279 at b51c7ba7:

```
  303 -> caller: HTTP 404 (12)    other origin saw: GET x-secret=tenant-key
  307 -> caller: HTTP 307 (2)     other origin saw: nothing
  308 -> caller: HTTP 308 (2)     other origin saw: nothing
  301 -> caller: HTTP 301 (2)     other origin saw: nothing
```

## Mechanism

For a POST dart:io follows 303 only (as a GET); 301, 307 and 308 come back
as responses and the caller already refused them. `x-api-key` is not on
dart:io's list of credentials it strips.

## Fix

`request.followRedirects = false` on the caller's `AbortableRequest`. On
the VM every redirect is a non-200 response (UNKNOWN); in a browser
package:http sets fetch's `redirect: 'error'`, so a redirect is a network
error (UNAVAILABLE). The README's failure table says both.

Sibling found by the same witness: the websocket caller's own handshake
(`connectBounded`, the default) opened its upgrade GET with redirects on
and followed 301, 303, 307 and 308 to another origin with the caller's
headers. `followRedirects = false` there too.

## After

```
http  P-279:  303 / 307 / 308 / 301 -> refused, other origin saw nothing
ws    P-296:  bounded (default)  301 / 303 / 307 -> nothing
              compressed         301 / 303 / 307 -> GET x-api-key=secret  (B-286)
```

Witnesses: rpc_dart_http `a_redirect_is_not_followed_test` (WITNESS 303,
GUARD 301/307/308), rpc_dart_websocket
`a_redirected_upgrade_is_not_followed_test` (301/303/307/308).

## Canary

1. http, `followRedirects = 1 > 0`: `WITNESS: a 303 is not followed`
   fails, `Expected: empty Actual: ['GET x-api-key=secret']`. A first
   attempt wrote `1 < 0 && false`, which is still false, and the witness
   stayed green; corrected and re-run.
2. websocket, the same: all four cases fail with
   `Actual: ['GET x-api-key=secret']`.

## The verdict questions

1. Yes: the GUARD statuses and the 303 differ only in the status code.
2. Yes: one request at the other origin against none.
3. At the other origin's server: what arrived.
4. n/a.
5. Quoted.
6. Two members, two canaries.
7. From the numbers.
8. No target dismissed.
9. none.
10. Siblings below.
A1. n/a. A2. n/a. L1. n/a.

## Gate

`melos run analyze`, `test:unit` (16 suites, http +242), `format:check`,
`license:check`, `test:web` (15 suites): green with the http fix. The
websocket fix followed: `analyze` and the websocket suite (+303) green.

## Siblings

- channel: n/a — no HTTP request, nothing to redirect
- http: fixed here
- http2: not measured — package:http2's client has no redirect logic, so a
  3xx is an ordinary non-200 answer; a reading, not a measurement
- websocket: fixed here (the default handshake); the compressed path is
  B-286
- isolate: n/a — no HTTP request
- wasm: n/a — no HTTP request
- caller: fixed here (http and websocket callers)
- responder: n/a — a responder does not follow redirects

## Not fixed

- B-286: `enableCompression: true` on the websocket caller still follows
  redirects (dart:io's `WebSocket.connect`, no setting for it).
- http2 not measured (Siblings).
- On the web a redirect is UNAVAILABLE, which the default retry treats as
  retryable: a caller pointed at a redirecting address retries it.

CHANGELOG line (breaking for web): "rpc_dart_http's caller no longer follows
redirects on any platform: on the VM a 303 is now refused like 301/307/308,
and in a browser every redirect fails the call (UNAVAILABLE) instead of
being followed. Point `baseUrl` at the final address. rpc_dart_websocket's
default client handshake no longer follows a redirect on the upgrade."

## Links

Lens `../lenses/RPC-18-dependency-buffers-below-your-limits.md`. Benches
`../probes/P-279-redirects-the-http-caller-follows.md`,
`../probes/P-296-what-a-redirected-websocket-upgrade-sends.md`. Leads
`../backlog/B-276-the-http-caller-follows-a-303-with-its-metadata.md`
(closed), `../backlog/B-286-a-compressed-websocket-upgrade-follows-redirects.md`
(new).
