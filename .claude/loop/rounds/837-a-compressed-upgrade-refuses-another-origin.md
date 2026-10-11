---
round: 837
verdict: FIXED
packages: [rpc_dart_websocket, rpc_dart_conformance]
lens: RPC-18
bench: P-296 — reused
commit: yes
severity: S1 — "a security or limit bypass"
release: changelog
---

# Round 837 — a compressed upgrade refuses another origin

## Target

B-286, open since round 807, and the two KNOWN FAILING cells it holds in
the owner's invariant I-10 ("metadata stays with its origin"): websocket,
compressed, a 303 and a 307 to another origin. A failing invariant cell
outranks a new lens (methods/siblings.md, choosing a target). The lead's
reason was cost: the way out it named was a compressed handshake of our own.

## Hypothesis

dart:io's `WebSocket.connect` follows a redirect to another origin with
every header the caller set, and the only seam without our own handshake is
the `HttpClient` it is handed.

## Before

```
I-10, --run-skipped, the two known-failing cells at f8cc8234:
  websocket | compressed, a 303 to another origin   Expected: <0> Actual: <1>
  websocket | compressed, a 307 to another origin   Expected: <0> Actual: <1>
```

## Mechanism

`WebSocket.connect` opens its GET without touching `followRedirects`, whose
default follows a 3xx for a GET. The lead's remedy was also closed: read in
the SDK, `WebSocket.fromUpgradedSocket` constructs the socket with no deflate
state whatever `compression:` says, so a compressed socket can only come out
of dart:io's own handshake.

## Fix

The compressed path (and the uncapped one) hands `WebSocket.connect` its own
`HttpClient` whose `connectionFactory` refuses any connection whose scheme,
host or port differ from the target's. With a factory set, `HttpClient`
leaves TLS to it for a direct connection and tunnels through a proxy itself,
so the factory opens `SecureSocket` for https, the proxy's socket when one is
given, a plain `Socket` otherwise.

## After

```
I-10, the same two cells: pass; _knownFailing is now empty
a_redirected_upgrade_is_not_followed_test: compressed 301/303/307/308 refused
GUARD: a compressed connect to its own origin echoes 10000 characters
```

## Canary

The factory not set (`if (1 < 0)`): the four compressed WITNESSes fail,
`Expected: empty Actual: ['GET x-api-key=secret']`. Restored.

## The verdict questions

1. Only the compression flag differs from round 807's passing cells.
2. Yes: one request at the other origin against none.
3. At the other origin's server: what arrived.
4. n/a.
5. Quoted.
6. One mechanism, one canary.
7. From the cells. S1 by the rubric's words, "a security or limit bypass":
   the caller's `x-api-key` arrives at another origin, measured. The first
   draft quoted "nonconformance" as S3 and `lint` refused it (that phrase is
   S2's, and the rubric has no S3 line for a credential sent elsewhere).
   Round 807 had judged the same leak below the bar (B-276) before ratings
   quoted the rubric; it needs a redirecting server and, here, a caller who
   turned compression on.
8. The lead's own remedy was ruled out by reading the SDK, not by its text:
   `_WebSocketImpl._fromSocket` is called from `fromUpgradedSocket` with no
   deflate argument.
9. none.
10. Siblings below.
A1. n/a. A2. n/a. L1. n/a.

## Gate

`melos run analyze`, `test:unit` green (the I-10 row with no known-failing
cell).

## Siblings

- scope: transport.http-like — a redirect exists only where a client dials an HTTP origin
- websocket: fixed here
- http: clean — measured, round 807's `a_redirect_is_not_followed_test` (P-279)
- http2: read — package:http2's client has no redirect logic (round 807)

## Not fixed

- wss and a proxy through the factory are not exercised by a test: the
  factory opens them as dart:io's default path does, with the default
  `SecurityContext`, which is what the private client used before.

CHANGELOG line: "rpc_dart_websocket: with `enableCompression: true` the
upgrade no longer follows a redirect to another origin with the caller's
headers; it fails the connect."

## Links

Lens `../lenses/RPC-18-dependency-buffers-below-your-limits.md`. Bench
`../probes/P-296-what-a-redirected-websocket-upgrade-sends.md`. Lead
`../backlog/B-286-a-compressed-websocket-upgrade-follows-redirects.md`
(closed). Round `807-a-redirect-is-a-refusal.md`.
