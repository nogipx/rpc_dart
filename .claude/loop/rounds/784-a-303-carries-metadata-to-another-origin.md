---
round: 784
verdict: DEFERRED
packages: [rpc_dart_http]
lens: RPC-18
bench: P-279 — new
commit: yes
release: none
---

# Round 784 — a 303 carries metadata to another origin

## Target

The network-audit skill's `known http1` sweep, KV-H1-04 (credentials
forwarded on redirect, CVE-2022-0451's class). `loop.py find 'redirect
followRedirects'` named no record; the transport's `lib/` sets nothing about
redirects, so it inherits dart:io's behaviour, RPC-18's shape.
KV-R-04 was set aside first: a per-connection bound times an uncapped
connection count is round 598's recorded choice (`maxConnections` default
null), not an unmeasured gap.

## Hypothesis

The caller follows a redirect to another origin and sends the call's
metadata there.

## Before

P-279:

```
  status   caller sees                          B received
  303      UNIMPLEMENTED (HTTP 404 from B)      GET  auth=null  x-secret=tenant-key
  307      UNKNOWN (HTTP 307)                   nothing
  308/301  UNKNOWN                              nothing
```

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/redirect_follow.dart`

## Mechanism

dart:io's client follows a 303 for any method, as a GET, and strips only
`authorization`, `www-authenticate`, `cookie` and `cookie2` across origins.
The caller does not set `followRedirects`.

## After

n/a.

## Canary

n/a.

## The verdict questions

1. Yes: the arms differ in the status code only.
2. Yes: B receives the header on 303 and nothing on the others.
3. At server B, the receiving side, from the request it got.
4. n/a.
5. n/a.
6. n/a.
7. DEFERRED for an owner decision: the exposure needs the trusted server
   to redirect, which puts it below the severity bar; the one-line fix is
   the owner's to take or leave.
8. KV-R-04 set aside by round 598's recorded decision, read in its record,
   and its default re-read in `rpc_websocket_server.dart` today. The web
   caller (browser fetch) was not measured.
9. None.
A1. Separate servers; the caller with defaults.
A2. Neither: a single request.
L1. n/a.

## Gate

n/a — no code change.

## Not fixed

B-276, awaiting the owner.

## Links

Lens `../lenses/RPC-18-dependency-buffers-below-your-limits.md`.
Probe `../probes/P-279-redirects-the-http-caller-follows.md`.
Lead `../backlog/B-276-the-http-caller-follows-a-303-with-its-metadata.md`.
Negative `../checked/C-68-the-lockfiles-have-no-known-advisories.md`.
