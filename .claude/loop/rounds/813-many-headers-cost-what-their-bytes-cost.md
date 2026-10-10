---
round: 813
verdict: CLEAN
packages: [rpc_dart_http, rpc_dart_websocket]
lens: RPC-22
bench: P-299 — new
commit: yes
severity: S3
release: none
---

# Round 813 — many headers cost what their bytes cost

## Target

Network-audit catalog KV-WS-05 (a): a request with a very large number of
headers, against both HTTP/1.1 servers. The header-count half of a header
flood had no record (`find 'many headers count parse cost'`); round 811
bounded the http server's header block by bytes and time, and B-287 holds the
websocket server's block, which belongs to the application's `HttpServer`.

## Hypothesis

Header parsing or the upgrade check costs more than linear in the header
count, or a header flood crashes or wedges a server, so one request with many
small headers costs far more than its bytes.

## Before

```
P-299 control, n = 0:  websocket 101 in 31 ms, http 200 in 24 ms, honest ok
```

## Mechanism

n/a (CLEAN). Time to the answer grows with bytes, not worse: 119 KB in 52 ms,
1.29 MB in 123 ms on the websocket side. The http server refuses at the
policy's header count (400) and closes at round 811's byte cap. The websocket
server accepts up to dart:io's 1 MiB `_headerTotalSizeLimit` (counted over
name and value bytes, about 1.4 MB on the wire) and closes past it.

## After

```
  n        wire bytes   websocket         http             honest after
  10000    119 030      101, 52 ms        400, 42 ms       ok / ok
  80000    1 029 030    101, 111 ms       closed, 22 ms    ok / ok
  100000   1 289 030    101, 123 ms       closed, 24 ms    ok / ok
  150000   1 989 030    closed, 116 ms    closed, 19 ms    ok / ok
  uncaught: none at any n
```

## Canary

The control is the flood's absence (n = 0). The bench reaches both ceilings:
http changes from 200 to 400 to closed, websocket from 101 to closed, so it
does see a limit when one fires.

## The verdict questions

1. Only the header count differs.
2. Yes: each server's answer changes at its own ceiling.
3. The first response line at the attacker; uncaught errors in the servers'
   zone; an honest call afterwards.
4. Four sizes; the time curve is read, not one point.
5. n/a (CLEAN).
6. n/a.
7. CLEAN with a control.
8. The websocket residency (about 1.4 MB per request before refusal) is
   B-287's byte bound, not a new lead.
9. none.
10. No code changed.
A1. Defaults on both servers; each refusal names its own limit.
A2. Volume (headers); latency measured per size.
L1. n/a.

## Gate

No code changed; the probe is outside the tree (`.dart_tool/probe`).

## Siblings

No code changed.

## Not fixed

- B-287: the websocket server holds up to about 1.4 MB of headers per
  request, against the http server's 4x-policy cap. This round adds the
  number to that lead.
- TLS and http2 not covered.

## Links

Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md`. Bench
`../probes/P-299-many-request-headers-against-both-servers.md`. Lead
`../backlog/B-287-the-websocket-servers-header-block-is-the-applications.md`.
