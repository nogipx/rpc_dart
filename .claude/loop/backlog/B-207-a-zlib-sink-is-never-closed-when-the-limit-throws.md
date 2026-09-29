---
status: open
round: 513 (named inside B-122, which said it deserves its own lead; filed in the round-540 bookkeeping pass)
commit: 6659c0ee
paths: [packages/core/rpc_dart/lib/src/core/compression_gzip_io.dart]
probe: none — the shape is a `close()` that a throw jumps over; the witness below is unbuilt
reason: "bench — a RESOURCE question rather than a cost one, which is why B-122 said it deserves its own lead: when the size limit throws inside the chunked gzip decoder, `sink.close()` is never reached and the native zlib filter waits for the finaliser"
---

# B-207 — the zlib sink is never closed when the size limit throws

Named inside B-122, which stated in as many words that this "is a resource question rather
than a cost one and deserves its own" lead. B-122 closed on the growth half without filing
it; this is the filing.

When the decompression size limit throws inside the chunked gzip decoder, `sink.close()` is
never reached, so the native zlib filter is left to a finaliser rather than released at the
throw. A peer that can trigger the limit can therefore leave one filter per attempt
outstanding, which is a peer-controlled quantity — the difference between this and the rest of
B-122.

RPC-22's shape: the refusal path is reachable by anyone, and what it COSTS the server is the
question. RPC-16's too — a check whose failure path skips a release.

## Why it matters

A native resource released only by a finaliser, at a rate the peer chooses.

## Witness a round would build

Drive the decompression limit repeatedly and read the native side: filters outstanding, or
process RSS with the finaliser deliberately not run. The control is the same number of
SUCCESSFUL decompressions, which reach `close()`.

The fix is the ordinary one — `try`/`finally` around the sink — and it is cheap enough that
the round is mostly the measurement.

## Owner decision

—
