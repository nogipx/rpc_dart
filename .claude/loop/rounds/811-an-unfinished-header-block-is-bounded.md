---
round: 811
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-18
bench: P-297 — new
commit: yes
severity: S2
release: changelog
---

# Round 811 — an unfinished header block is bounded

## Target

B-285, decided by the owner after round 809: build the connection cap and
header deadline now, propose the defaults and ask before committing. The
second half of B-274 (round 806 wrote the documentation). Network-audit
catalog KV-WS-05 (handshake resource exhaustion), the HTTP/1.1 side.

## Hypothesis

dart:io holds a request header block that never ends, below every rpc_dart
limit and outside `HttpServer.idleTimeout`, for any number of connections.

## Before

```
P-297 at 68023a57, RpcHttpServer defaults:
  300 x 900 KiB unfinished headers, 20 s   +289 MiB, 0/300 closed
  300 x 1 KiB (control)                    +0 MiB,   0/300 closed
```

## Mechanism

dart:io's HTTP parser buffers a header block until `\r\n\r\n` (up to ~3 MiB
per connection) and applies no deadline to it; `idleTimeout` covers an idle
connection, not a request in progress. Nothing above sees those bytes.

## Fix

`PeerWatchingServerSocket` (round 804's socket watcher) now also bounds
each request's header block, counted on the raw bytes up to the blank line:

- in bytes, at four times what the security policy admits as one request's
  head (method path, metadata, header framing, request line) — no new
  setting; a block a little over the policy still reaches the transport
  and is answered 400 with the reason;
- in time, with a new `headerTimeout` (owner: 60 s), from the accept for
  the first request and from the first byte for a later one, so an idle
  kept-alive connection stays under dart:io's `idleTimeout`;
- optionally in count, with a new `maxConnections` (owner: off).

`RpcHttpServer` re-arms the block when a response is written. README: the
options table and the reverse-proxy section; the skill's security reference
now says what the policy still does not bound.

## After

```
P-297, RpcHttpServer defaults:
  300 x 900 KiB, 20 s          +12 MiB, 300/300 closed at once, honest call ok
  300 x 260 KiB (under bound)  +103 MiB held, closed at the deadline
  300 x 60 KiB, no deadline    0/300 closed;  with a 2 s deadline: 300/300
  maxConnections 100, 300 conns  200/300 closed; an honest call refused
                                 while it is full (why it defaults off)
```

## Canary

1. The byte bound off: `WITNESS: a header block over the policy is closed
   at once` fails, `Expected: true Actual: <false>, the server kept a 900
   KiB unfinished header block`.
2. The deadline off: `WITNESS: an unfinished header block is closed after
   headerTimeout` fails the same way.
3. The connection cap off: `WITNESS: a connection past maxConnections is
   closed` fails, "a third connection was kept with maxConnections: 2".
4. The deadline armed from the previous answer instead of the next
   request's first byte: the first keep-alive GUARD (through HttpClient)
   stayed green -- HttpClient silently redials a pooled connection the
   server closed -- so it was rewritten on a raw socket, which then failed
   "an idle kept-alive connection was cut". Restored: green.

## The verdict questions

1. The control differs only in the header size (1 KiB against 900 KiB).
2. Yes: +289 MiB / 0 closed against +0 MiB.
3. Process RSS and connections the server closed, seen by the client.
4. Each arm states how many closed; the honest call proves the server
   serves.
5. Quoted.
6. Four halves, four canaries; the fourth needed its guard rewritten.
7. From the numbers.
8. No target dismissed.
9. A client library that redials a pooled connection hides a server that
   cut it: assert keep-alive behaviour on a raw socket. Already the
   substance of L-15 (a subject that never reaches the code); none new.
10. Siblings below.
A1. The attacker is raw sockets; the server keeps its default policy.
A2. Volume and time; both varied.
L1. Yes: each witness names its own bound.

## Gate

`melos run analyze`, the unit suites with `--file-reporter` (16 packages,
http +248), `format:check`, `license:check`, `check:skills`, `test:web`
(15): green. The first unit run died of "No space left on device"; with
the owner's consent the leftover `dart_test.*` temp directories of
interrupted runs were removed and the run repeated.

An existing test split, per the canary rule for a test that measures two
situations: `aggregate_metadata_bound_test` sent 960 000 bytes of headers
and expected 400. A block that far over is now cut before it is held; a
block just over (100 000 bytes) still gets the 400 with its reason, and
both are now their own tests.

## Siblings

- channel: n/a — no HTTP header block
- http: fixed here
- http2: not measured here — its header blocks go through package:http2's
  own HPACK parser, not dart:io's HTTP/1.1 one, so this bench does not apply;
  the HTTP/2 CONTINUATION class is lens RPC-18's other evidence
- websocket: not fixed — the HttpServer is the application's; B-287
- isolate: n/a — no HTTP
- wasm: n/a — no HTTP
- caller: n/a — the bound is on the server's input
- responder: fixed here (RpcHttpServer)

## Not fixed

- B-287: the websocket server's header block (the application's
  HttpServer).
- A client may still hold up to ~270 KiB per connection for up to 60 s,
  with no count bound unless `maxConnections` is set.

## Links

Lens `../lenses/RPC-18-dependency-buffers-below-your-limits.md`. Bench
`../probes/P-297-unfinished-header-blocks-against-rpchttpserver.md`. Leads
`../backlog/B-285-the-http-servers-have-no-connection-cap-or-header-deadline.md`
(closed), `../backlog/B-287-the-websocket-servers-header-block-is-the-applications.md`
(new).
