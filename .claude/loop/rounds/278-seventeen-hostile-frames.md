---
round: 278
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-15
bench: P-28 — new
commit: yes
---

# Round 278 — seventeen hostile frames

## Target

C-02, the oldest stale negative and the weakest record in `checked/`. It read,
in full: *"A battery of nine malformed frames. The codec is clean."* No case
names, no numbers, last measured in round 46, and `loop.py stale` reports six
files changed under its paths since. RPC-15 — re-measure the loop's own record —
and the frame codec is worth it because every channel transport funnels through
it.

## Hypothesis

Some hostile frame produces an `Error` rather than an `Exception`. The receive
loop catches `Exception`; every guard in `_decodeMetadataPayload` is written as
`on FormatException` or an explicit type test, so an `Error` walks straight out
into the zone — which on a server is RPC-13's process kill from one
unauthenticated frame.

The specific candidate the old record cannot have covered: **JSON nesting
depth**, since a `StackOverflowError` is an `Error`.

## Before

Seventeen named cases through `RpcChannelFrame.decodeAll` with the default
policy's limits.

```
CONTROL  a valid metadata frame            ok: 1 frame, 26 bytes consumed

header shorter than 9 bytes               ok: 0 frames, 0 consumed
declared length 0xFFFFFFFF                RpcFrameException: payload too large
declared length just over the cap         RpcFrameException: payload too large
metadata frame just over its own cap      RpcFrameException: metadata too large
declared longer than delivered            ok: 0 frames, 0 consumed
stream id 0xFFFFFFFF                      ok: 1 frame, 12 consumed
stream id 0                               ok: 1 frame, 12 consumed
all flag bits set (0xFF)                  ok: 1 frame, 11 consumed
metadata: invalid UTF-8                   RpcFrameException
metadata: malformed JSON                  RpcFrameException
metadata: JSON is not an object           RpcFrameException
metadata: methodPath is not a string      RpcFrameException
metadata: headers is not a list           RpcFrameException
metadata: header entry is not a pair      RpcFrameException
metadata: header value is not a string    RpcFrameException
metadata: 20000-deep nesting              RpcFrameException
metadata: 4000 headers in the byte cap    ok: 1 frame, 40016 consumed
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/hostile_frames.dart`

**Eleven typed refusals, three short-reads, three legal-but-unusual frames
accepted, zero leaked `Error`s.** The depth case is refused as a malformed
header entry rather than overflowing, because Dart's JSON decoder keeps an
explicit stack instead of recursing.

## Mechanism

n/a — nothing is broken.

## After

n/a.

## Canary

n/a. The control is a well-formed metadata frame through the identical call
(accepted, 26 bytes), so every refusal is attributable to the content rather
than to the harness.

One case had to be rebuilt, and it is the useful part of this round's method:
`metadata frame just over its own cap` first declared `maxMetadata + 1` and
delivered three bytes, so the incompleteness check fired and the row read
`ok: 0 frames` — a pass produced by the wrong guard entirely. Delivering the
payload in full is what makes it test the cap it is named for.

## Gate

n/a — no code changed. `loop.py lint` green.

## Not fixed

Nothing. Two observations recorded in C-02 rather than opened as leads:

- The codec accepts `stream id 0`, `0xFFFFFFFF` and unknown flag bits. Correct —
  framing is its job, and peer-chosen ids are C-04's subject — but it means the
  codec is not where an id is judged.
- **The codec bounds metadata by BYTES and by nothing else.** 4000 headers
  inside the 64 KiB cap are decoded before `maxHeaders` — a policy field
  enforced one layer up — sees them, so every `RpcHeader` and both its Strings
  exist first.

  **This round wrote "bounded and caught, so recorded rather than pursued", and
  that was wrong.** It is reasoning where the round's own method is measurement,
  and the owner pushing back on the session stopping is what sent it back.
  Round 279 measured it: the queue's byte bound weighs a header by its
  CHARACTERS, so those objects are admitted at ~12x what the bound believes —
  186 MiB against 16 MiB, at three scales. See
  `279-a-header-weighs-more-than-its-characters.md`. A leftover dismissed in
  prose is a lead not filed.

## Links

RPC-15 (`applied:` gains 278). Bench P-28, new. C-02 rewritten from a 16-line
stub to a record with numbers.
