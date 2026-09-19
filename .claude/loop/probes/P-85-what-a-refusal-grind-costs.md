---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/refusal_grind_cost.dart
round: 399
commit: daf55af4
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
status: valid
---

# P-85 — what a refusal grind costs, against what being served costs

## Why it exists

RPC-22's question is comparative — *which is cheaper for an attacker, being
accepted or being refused?* — and B-58 needed it answered before anyone decided
whether the framing-violation site needs the 256-violation backstop its sibling
has.

## Measures

Three numbers per operation, on ONE connection: the bytes the peer must send,
the bytes the server writes back, and wall clock. Plus the `grpc-status` the
peer was told, and how many operations the connection actually carried.

Bytes are counted by a **relay** sitting between peer and server. Neither
endpoint can report both directions on its own — the peer's socket cannot see
what the server wrote without the server's cooperation, and instrumenting the
transport would mean changing production code to measure it.

The connection is warmed and the counters zeroed before the loop, so the preface
and SETTINGS are not charged to operation 1.

## Control

`served` — 2000 real unary calls, same connection shape, same header block, the
only difference being a valid body instead of a refused one. A refusal cost
means nothing except against what an honest call costs.

`ops` is the second control, and it earns its column: the backstop-bearing arm
stops part-way, and dividing its bytes by 2000 as if it had run would understate
its per-operation cost by 6x.

## The numbers (round 399)

```
arm            ops     ms    up B/op  down B/op   amp    status
served        2000    873      164.3      128.0   0.78x   0
framing       2000    548      134.0      216.0   1.61x   8
tight msg     2000    424      134.0      131.0   0.98x   8
:method GET    300     66      133.0      162.5   1.22x   3
```

`tight msg` is `framing` with `maxHeaderValueBytes: 24`, which trims the
diagnostic. Same site — `grpc-status 8` — and the amplification disappears, so
the parser's message text is what the server is writing.

`:method GET` is the sibling refusal site, which HAS the backstop: 300 attempted,
the connection closed after the 256th violation (the extra 44 were already in
flight in a 50-wide batch).

## The arm that had to be resized, and how it was caught

The first `tight msg` used `maxHeaderValueBytes: 8` and came back
**`status 3`, 300 ops** — `validateMetadata` refusing the request's OWN headers
(`content-type: application/grpc` is 16 bytes), so it measured the headers site
with its backstop and never reached the framing site at all. The `grpc-status`
column is what said so, the same column P-84 grew for the same reason: an arm
that never reached the path it names must not be able to read as a clean one.

## What it establishes, and what it does not

Establishes: refusing is cheaper for the server than serving (548 ms against
873 for 2000) and cheaper for the peer to send (134 against 164 B/op), so a
refusal flood is strictly less damaging than the same volume of honest calls —
which is why B-58's backstop is not justified on cost. And the refusal is the
only path here where the server writes MORE than it reads.

Does not measure memory, a peer that reads none of the answers it provokes, or
several connections at once. Wall clock on one machine is a weak instrument for
CPU; the ratio against the `served` control is what it is used for, not the
absolute.
