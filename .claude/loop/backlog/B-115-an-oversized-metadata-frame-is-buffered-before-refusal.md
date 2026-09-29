---
status: closed (round 506)
round: 506
commit: acefa601
paths: [packages/core/rpc_dart/lib/src/core/channel_frame.dart, packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart]
probe: P-144
reason: "closed — CONFIRMED and fixed: a declared 10 MiB metadata frame was buffered in full, 10485769 bytes against a 64 KiB ceiling, before the refusal fired. Both of the check's inputs are header fields, so it moved above the completeness check and now refuses at 9 bytes"
---

# B-115 — a metadata frame over `maxMetadataBytes` is buffered in full before it is refused

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_decodeAt` returns null for an incomplete payload BEFORE it checks `maxMetadataLen`, so a server (`closeOnOversizedFrame: true`, where `_refusedFrameHeader` is off) buffers up to the DATA ceiling (16 MiB) of a frame whose header already says it is a 64 KiB-limited metadata frame.

## The shape

`packages/core/rpc_dart/lib/src/core/channel_frame.dart:107-134`: the `maxPayloadLen` check, then
`if (data.length < payloadStart + payloadLen) return null;`, and only then the
metadata-size check. `decodeAll`'s doc promises rejection "from the header alone".

## Why it matters

256x more memory per hostile frame than the metadata limit implies, on transports
that deliver bytes incrementally (not dart:io websocket, which delivers whole
messages).

## Witness a round would build

Feed a frame header declaring a 10 MiB metadata payload, then the payload in
64 KiB chunks; observe when the refusal fires and the buffer size at that point.

## Fix sketch

Move the metadata-size check above the completeness check.

## Outcome (round 506)

**CONFIRMED and fixed**, and the estimate in "Why it matters" was close: the lead
says 256x, and at a declared 10 MiB the measurement is 160x. The real bound is the
data ceiling, so 256x is reachable at 16 MiB.

```
declared 10 MiB, fed in 64 KiB chunks     before      after
METADATA flag set                         10485769    9        <- the header alone
CONTROL data frame, same size             10485769    10485769 <- legal, accepted
```

Fixed as the sketch says. Both of the check's inputs — the metadata flag and the
declared length — are 9-byte header fields, so there was never anything to wait for;
`isMetadata` was hoisted to join the other header reads and the check moved above
`if (data.length < payloadStart + payloadLen) return null;`.

`decodeAll`'s doc promised header-only rejection for `maxPayloadLen` and said nothing
about `maxMetadataLen`, so it was accurate while naming exactly the guarantee that
was missing. Now stated for both.

**The sibling already had it right**, which is worth recording: the CLIENT path
(`_refusedFrameHeader`) applies the metadata ceiling from the header and returns null
outright when `closeOnOversizedFrame` is true — the server's default. Half the
codebase had the correct behaviour, which both confirmed the intent and said where to
look.

## Still open, and not closed by this fix

**A peer that sends the whole frame in ONE chunk.** On `dart:io`'s WebSocket a
message arrives as a single chunk, so the peak is resident before this class sees a
byte; `_maxBufferedFrameBytes` bounds that at 16 MiB and is untouched. The lead's own
"not dart:io websocket" parenthesis says the same thing.

**Two places still implement one rule.** With `_decodeAt` refusing from the header,
the client's copy is now redundant for metadata frames. Not merged — a refactor with
no measured failure behind it.

## Owner decision

—
