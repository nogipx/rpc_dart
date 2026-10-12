---
round: 840
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-27
bench: P-311 — new
commit: yes
severity: S1 — "a security or limit bypass"
release: changelog
---

# Round 840 — a body chunk cannot pin its read buffer

## Target

Through network-audit, KV-H1-01 (a body read before the limit) and KV-WS-01
on the caller. The websocket caller's `enableCompression` was NOT measured:
its README states it inflates without limit and is opt-in, which is prose,
not a ruling, so it stays a candidate. `RpcWebSocketServer`'s own
`maxConnections` was run through P-310 (all seven endings served at cap 2)
without an ablation, so it is a note, not a negative. Taken: round 836's
`BodyAccumulator`, the newest code on a pre-auth path. It keeps chunks of
4096 bytes and up without a copy, and dart:io (`http_parser.dart`, `BODY`
state) hands body data as `Uint8List.view` of its socket read buffer, while
`CHUNK_SIZE_EXTENSION` skips any number of bytes to the CR.

Class counted (L-12), inbound accumulators in core and the transports:
`BodyAccumulator` on the server's request body and the caller's response
body, and `_readErrorBody` on the caller (`BytesBuilder(copy: false)`, 8 KiB
counted, chunks unbounded in number). `error_details.dart` and the two
`bodyBuffer`s build our own outbound bytes; `compression_gzip_io.dart` holds
zlib's own output. Three sites, all fixed.

## Hypothesis

A request body under `maxMessageLengthBytes` holds memory near its size.
Fails if a peer can make each counted chunk hold a read buffer of bytes the
limit never counts.

## Before

```
arm               counted    sent      held by accumulators  RSS peak
pad 0, 3 conn     23.8 MiB   23.9 MiB  23.9 MiB              +30.3 MiB
pad 60000, 3 conn 23.8 MiB   372.7 MiB 372.6 MiB             +458.0 MiB
pad 60000, 1 conn  7.9 MiB   124.2 MiB     -                 +136.7 MiB
```

15.6x the counted body is held, under an 8 MiB limit, before any handler or
auth runs; it scales with connections (1 conn +136.7, 3 conn +334.4 MiB RSS).

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/r840_pinned_body.dart`.

## Mechanism

Each kept chunk is a view, and a view keeps its whole read buffer reachable.
A chunk extension fills the read with bytes the parser skips, so the limit
counts 4 KiB per read while the accumulator holds 64 KiB.

## After

```
arm               counted    held by accumulators  large chunks copied  RSS peak
pad 0, 3 conn     23.8 MiB   24.2 MiB              315392 B             +7.6 MiB
pad 60000, 3 conn 23.8 MiB   63.1 MiB              23203840 B           +112.7 MiB
```

Views are kept only while the buffers they hold stay within twice the bytes
collected; past that a chunk is copied, so what is held is at most three
times what is counted. An honest body copies 1.3% of its bytes (the start of
the first read), not all of it: copying every view smaller than its buffer
would add a copy of every chunked body, a speed trade the owner has not been
asked about.

## Canary

Witness `packages/transport/rpc_dart_http/test/a_body_chunk_cannot_pin_its_read_buffer_test.dart`.

- Copy rule off (`1 < 0 &&` before the budget test): "WITNESS a chunk at the
  end of a mostly unused read is copied" failed with `held 13107200 bytes for
  819200 collected`; GUARD green.
- The other neighbour, every view smaller than its buffer copied: "GUARD reads
  made of body are kept as views, not copied" failed with `Expected: a value
  greater than or equal to <624> Actual: <40>`; WITNESS green.

Both also pass under dart2js (`-p node`).

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(rpc_dart_http +257, rpc_dart +2202 ~1, conformance +512 ~150);
`format:check` SUCCESS; `license:check` compliant.

## Siblings

- http: fixed here
- http2: n/a — DATA reaches the core parser, which copies a partial message into its own buffer and copies a waiting whole-message view out (`_ownedPayload`, round 636); padding is at most 255 bytes a frame
- websocket: n/a — every byte of a read is a frame header, a payload counted toward the message, or a control frame of at most 125 bytes, rate-limited (round 713); no field carries uncounted bytes of unbounded length
- channel: n/a — the core parser copies, as for http2
- isolate: n/a — a message arrives as its own object; no shared read buffer
- wasm: n/a — frames cross the bridge as their own byte arrays; no shared read buffer
- caller: fixed here (`_readErrorBody` and the response body)
- responder: fixed here (the request body)

## Not fixed

- The bound is three times the counted body, not one: copying every view
  would make it one at the price of a copy of every honest chunked body.
  That trade is the owner's.
- RSS peaks stay above the held bytes while the attack runs: the extension
  bytes pass through memory as garbage (372 MiB sent), which no accumulator
  can prevent.

## Links

Lens `../lenses/RPC-27-a-bound-counted-in-the-wrong-unit.md`. Bench
`../probes/P-311-chunk-views-pin-read-buffers.md`. Round
`836-a-message-in-tiny-pieces-held-many-times-its-size.md` (the
accumulator), round `636-the-byte-that-held-a-megabyte.md` (the same shape in
core).
