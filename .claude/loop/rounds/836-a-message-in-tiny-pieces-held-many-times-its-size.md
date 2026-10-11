---
round: 836
verdict: FIXED
packages: [rpc_dart_websocket, rpc_dart_http]
lens: RPC-27
bench: P-309 — new
commit: yes
severity: S2 — "a limit that is off but still bounds"
release: changelog
---

# Round 836 — a message in tiny pieces held many times its size

## Target

Network-audit KV-WS-03 (fragment floods) under RPC-27, ranked second, last
applied in round 803: a bound counted in the wrong unit. The websocket frame
guard bounds a message by its payload BYTES summed over fragments (round
611), and the journal has no record of what a fragment costs besides its
bytes (`find 'continuation fragment flood tiny fragments'`).

## Hypothesis

dart:io holds each fragment of an unfinished message as a separate buffer,
so a message sent as one-byte fragments costs many times its payload in heap
while staying under the byte ceiling.

## Before

```
P-309 at f8cc8234, server RSS:
  websocket   1 x 2000000 B (control)   12 MiB
  websocket   2000000 x 1 B              143 MiB (max 185), 13.7 MB on the wire
  http        1 x 2000000 B (control)   16 MiB
  http        2000000 x 1 B chunks       166 MiB, 11.7 MB on the wire
```

About 70 bytes of heap per piece, about 10x the wire bytes, held per
connection for as long as the message stays unfinished, before any check of
rpc_dart's; the connection count is unbounded by default.

## Mechanism

- websocket: dart:io's message assembler keeps every fragment; the guard
  counts `length` only, so a one-byte fragment costs one byte of the ceiling.
- http: `readBody` (server) and `_readBounded` (caller) collect into
  `BytesBuilder(copy: false)`, which keeps one list per chunk, and dart:io
  delivers each chunked-encoding chunk as its own event.

## Fix

- websocket: `WebSocketFrameGuard.maxFragmentsPerMessage = 4096`; a message
  in more fragments is refused like an oversized one (the socket is
  destroyed), and the count starts again with each message.
- http: `BodyAccumulator` copies chunks under 4 KiB into one buffer and
  hands them on at 64 KiB; a large chunk is still kept as it came, so a
  large body costs no extra copy. Used on both sides.

## After

```
  websocket   2000000 x 1 B   closed at fragment 4097, RSS 12 MiB
  websocket   4096 x 1 B      admitted, RSS 9 MiB
  http        2000000 x 1 B   RSS 42 MiB
```

Witnesses: `rpc_dart_websocket/test/websocket_frame_guard_test.dart`
("WITNESS a message in more fragments than the cap is refused", "GUARD the
fragment count starts again with each message"),
`rpc_dart_http/test/a_body_in_tiny_chunks_is_held_compactly_test.dart`
(200000 one-byte chunks held as at most 4 lists; GUARDs: bytes whole and in
order, a large chunk kept as it came).

## Canary

1. The cap off (`&& 1 < 0`): the websocket WITNESS fails, `Expected: false
   Actual: <true>`.
2. The reset off (`if (1 < 0) _messageFragments = 0`): the GUARD fails,
   `Expected: true Actual: <false>`, and so does the existing "pongs and data
   frames are not rate-limited".
3. `BodyAccumulator` keeping every chunk (`|| 1 > 0`): the http WITNESS
   fails, `Expected: a value less than or equal to <4> Actual: <200000>`.

Restored each.

## The verdict questions

1. Only the piece size differs; the payload is the same.
2. Yes: 143 and 166 MiB against 12 and 16.
3. In the server's own process (`ProcessInfo.currentRss`).
4. Four sizes on websocket around the cap; the http curve at two counts.
5. Quoted.
6. Three mechanisms (cap, reset, accumulator), three canaries. The http
   wiring (both call sites use the accumulator) is shown by the probe, not
   by a test.
7. From the numbers. S2 and not S1: the byte ceiling still bounds each
   message, about 70x, which is "a limit that is off but still bounds".
8. none.
9. none.
10. Siblings below.
A1. Defaults on both servers. A2. Volume. L1. The websocket refusal is the
    fragment cap: 4096 admitted, 4097 closed.

## Gate

`melos run analyze`, `test:unit` green; the http `web_smoke_test` on node.

## Siblings

- websocket: fixed here
- http: fixed here
- channel: clean — measured, `r836_tiny_data_frames.dart` (+21 MiB against +6 MiB, sender included); the frame channel and `RpcMessageParser` buffer contiguously
- http2: read — DATA frames go through core's `RpcMessageParser`, the parser measured on the channel; not run
- isolate: read — framed through `RpcChannelTransport` (web) or whole messages on a SendPort; not run
- wasm: read — framed through `RpcChannelTransport`, measured above; not run

## Not fixed

- The websocket client with `enableCompression` uses dart:io's own
  handshake and no guard (B-286's path).
- The http numbers after the fix (42 MiB) still include dart:io's own
  per-chunk parsing garbage; not broken down.

CHANGELOG lines: "rpc_dart_websocket: a message arriving in more than 4096
fragments is refused like an oversized one." "rpc_dart_http: a request or
response body sent in tiny chunks no longer costs many times its size in
memory."

## Links

Lens `../lenses/RPC-27-a-bound-counted-in-the-wrong-unit.md`. Bench
`../probes/P-309-a-message-in-tiny-pieces.md`. Round
`611-the-message-that-never-ends.md`.
