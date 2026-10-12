---
refines: —
paths: [packages/core/*/lib/**, packages/transport/*/lib/**, packages/notify/*/lib/**, packages/data/*/lib/**, packages/blob/*/lib/**]
applies: a container is capped by how many items it holds, and what one item weighs is set by someone else — a peer, a caller, a logged payload
breaks: memory exhaustion: the cap holds and the process still runs out.
applied: [764, 765, 783, 785, 803, 836, 840]
status: confirmed (round 840)
rank: 2
---

# RPC-27 — A bound counted in the wrong unit

## Shape

A queue, ring buffer, cache or history is bounded by `length > max`. The
items are strings, byte lists, maps or records whose size the code does not
choose. The cap looks like a memory bound and is not one: the worst case is
the cap times the largest item the path admits, and the largest item is
usually only bounded by a transport ceiling (16 MiB here) or not at all.

The sibling of RPC-17. There the limit is in the right unit and fires too
late; here it fires on time and counts the wrong thing.

## Detector

Every count cap over a collection in lib code:

    grep -rnE "\.length\s*(>|>=)\s*_?(max|limit|bufferSize|capacity|maxRecords|maxSize|maxEntries|_max)[A-Za-z]*" \
      packages --include='*.dart' | grep /lib/

46 sites at round 765 (7 in `rpc_dart_log/lib/src/mcp_buffer.dart`, now
paired with a byte budget). For each: what type does the collection hold,
who decides an item's size, and what bounds that size on the way in. Skip
caps over fixed-size items (ints, ids, timestamps) and over items this
code builds itself at a fixed size.

Not yet walked: `RingBufferOutput`, `LogControllerOtelOutput`,
`BufferedBroadcast`, notify's `StreamDistributor` and `TransportRouter`,
data's `ChangeJournal`, the blob adapters.

## Ask

Fill the container to its cap with items at the largest size the inbound
path admits, then again with small items (the control): how many bytes does
it hold in each arm? Count held items and charged bytes inside the process
that owns the container; RSS only as a cross-check, it also carries garbage.

## Evidence

- **Round 764** — `LogCollectorMcpBuffer` (5000 records): 1000 records of
  256 KiB held +343 / +358 MiB against +10 MiB for 100 B records.
  `../rounds/764-the-collector-counts-records-not-bytes.md`,
  `../probes/P-265-what-the-log-buffer-holds-when-records-are-large.md`.
- **Round 765** — owner chose a byte budget beside the count on both log
  buffers (64 MiB collector, 8 MiB app): held 1000 -> 255, the budget. A
  buffer that moves items between two queues keeps one byte total and
  refunds it where an item leaves for good (the ack), not where it moves.
  `../rounds/765-the-log-buffers-are-bounded-in-bytes.md`.
- **Round 803** — the inverse case: the CBOR decoder was bounded in wire
  bytes and the cost is per decoded item (an empty map is one byte and a
  heap map). +1128 MiB / 1265 ms per 16 MiB call -> +96 MiB / 138 ms with
  `RpcSecurityPolicy.maxDecodedItems`. A budget that must reach code which
  takes no policy (generated tear-offs) can ride a scope around a
  synchronous call. `../rounds/803-cbor-decode-is-bounded-in-items.md`.
- **Round 840** — a byte limit in the right unit and still wrong: the http
  body limit counted body bytes while each kept chunk was a dart:io VIEW
  holding its whole read buffer, filled by a chunk extension. 372.6 MiB held
  for 23.8 MiB counted -> 63.1 MiB. **A kept view weighs its buffer; count
  `buffer.lengthInBytes` once per buffer, not the view's length.**
  `../rounds/840-a-body-chunk-cannot-pin-its-read-buffer.md`,
  `../probes/P-311-chunk-views-pin-read-buffers.md`.
