---
status: closed (round 591)
round: 591
commit: 6659c0ee
paths: [packages/core/rpc_dart/lib/src/core/compression_gzip_io.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/b207_what_a_refused_bomb_leaves_behind.dart
reason: "REFUTED on its claim. The mechanism holds -- close() is skipped, 20000 of 20000 times -- but nothing accumulates: 20000 refusals grow LESS than 20000 successful decompressions. Structural, not lucky: tripping the limit requires allocating up to it, so the refusal path generates the GC pressure that runs the finaliser"
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

## Measured — round 591, REFUTED

The measurement came back negative, which is what "mostly the measurement" bought.

```
                 CONTROL   WITNESS
2000 attempts    +12 MiB   +12 MiB
20000 attempts   +30 MiB    +6 MiB
20000 attempts   +31 MiB   -53 MiB
```

`CONTROL` is 20000 successful decompressions, which reach `close()`. `WITNESS` is 20000
refusals, which skip it. **The control is the arm that grows**, every run; the third has
the witness handing 53 MiB back to the collector mid-arm.

The mechanism IS real — `_LimitedByteSink.add` throws, and `sink.close()` on the next
line is jumped over, 20000 of 20000 times. What is not real is the consequence, and the
reason is structural rather than lucky:

**To trip the limit a payload must be decompressed UP TO the limit.** A megabyte of
output accumulates in a `BytesBuilder` before the throw, so the refusal path generates
the GC pressure that runs the finaliser, every time, in proportion to the limit it is
about to breach. "At a rate the peer chooses" requires asking for a refusal cheaply, and
the refusal path does not allow that.

## The sketch's fix was priced and NOT applied

`close()` in a `finally` is free of the hazard it looked like it had — an exception from
a `finally` replaces the one in flight, and closing a gzip decoder mid-stream turned out
not to throw:

```
bomb      caller gets FormatException; close() after the throw was CLEAN
ordinary  no throw at all
```

So it could be applied. It is not, because nothing witnesses it: no arm goes red without
it, and a release measured as unnecessary is a change the next reader cannot tell from
one that matters.

## What this lead does NOT cover

- Low GC pressure, the one condition under which the claim could still hold. The probe
  cannot create it, for the structural reason above.
- The native side directly: Dart exposes no handle on an outstanding zlib filter, so RSS
  is the only observable.
- The `maxOutputBytes == null` path, which does not use the chunked sink and so has no
  `close()` to skip.

## Owner decision

—
