---
round: 507
verdict: FIXED
packages: [rpc_dart]
lens: RPC-17
bench: P-145 — new
commit: yes
---

# Round 507 — the copy that bought nothing

## Target

The channel receive path's first copy — twenty-third in the audit's rank, and the
first of this stretch whose subject is a COST rather than a failure.

Lens RPC-17. Not its usual reading: here nothing is unbounded and no limit fires
late. What the lens supplies is the habit of asking what a buffer is FOR, and the
answer was that on a message-aligned transport it holds nothing worth holding — the
chunk already contains whole frames and it was copied anyway.

## Hypothesis

Every inbound chunk is copied into `_buf` before decoding, including when the buffer
is empty and the chunk holds complete frames.

## Before

```
per frame                      appended
  64 B    view only              0.75 us
  64 B    copied out             0.29 us
  16 KiB  view only              1.72 us
  16 KiB  copied out             2.40 us
  1 MiB   view only            227.02 us
  1 MiB   copied out           389.76 us
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b116_copies_per_message.dart`

**CONFIRMED.** A reference `setRange` of the same megabyte runs at ~37000 MiB/s, so
the old receive path cost roughly 8x a single copy of the payload — copies plus the
allocation and zeroing of a fresh buffer each time.

**The bench had to be rebuilt once, and that is the round's first lesson.** The first
version echoed through `RpcCallerEndpoint`, which puts the JSON codec in the path; at
1 MiB the codec dominates everything the lead is about, so the measurement would have
been attributed to the wrong layer. Measuring the layer the lead names is what makes
the number mean what it says.

## Mechanism

```dart
_appendToBuffer(data);
final buffered = Uint8List.sublistView(_buf, 0, _bufLen);
(frames, consumed) = RpcChannelFrame.decodeAll(buffered, ...);
```

The buffer exists for reassembly — a frame split across chunks. On a message-aligned
transport that case does not arise, so the copy was pure overhead: in, then straight
back out as views.

## After

```
per frame                      appended      decoded in place
  64 B    view only              0.75 us         0.66 us
  64 B    copied out             0.29 us         0.27 us
  16 KiB  view only              1.72 us         0.74 us
  16 KiB  copied out             2.40 us         1.05 us
  1 MiB   view only            227.02 us         0.31 us
  1 MiB   copied out           389.76 us       191.45 us
```

`final fastPath = _bufLen == 0;` — decode straight out of `data`, and buffer only
what the decoder did not consume. Three lines plus the tail handling.

**The honest number is 2.0x, not 725x.** The `view only` row going 227 -> 0.31 us is
the copy disappearing, not throughput; nothing touches a byte there. The row that
describes a real receiver is `copied out`, and it halves. At 64 B nothing moves,
exactly as the shape predicts.

Regression: `test/transports/the_channel_decodes_in_place_test.dart`, 9 tests.

## Canary

`final bool fastPath = false;` — one line, and it restores the previous behaviour
exactly, because the `else if (consumed > 0)` compaction branch is the original code
untouched. The bench returns to `389.76 us` / `227.02 us`.

**Every test in the new file passes under that ablation, and the file says so.** The
defect is a cost, so no test can witness it; all nine are GUARDs, and they exist
because the speed-up must not be bought with a framing bug. They were labelled
WITNESS in the first draft and the ablation is what corrected that.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run test:web` SUCCESS;
`melos run format:check` SUCCESS; `melos run license:check` compliant.

**`test:web` went red once and it was a flake, established rather than assumed.** A
web-worker suite failed at the `loading` stage under parallel load. It passed alone,
passed with the change ablated, and then passed again WITH the change — so the
ablation run is what says it is not mine, not the fact that a re-run went green.

## Not fixed

**This imposes a new requirement on `IRpcChannel` implementers, and that is the real
cost of the change.** A decoded payload is now a view into the chunk rather than into
`_buf`, so a channel must not write into a `Uint8List` it has already delivered, nor
reuse one as scratch. Stated on `IRpcChannel.incoming`. Every in-repo channel already
satisfies it — the full suite across 21 packages plus the web target is the evidence
— but it is a contract change invisible to every gate, and an external implementer
who reused a buffer would see corruption rather than an error. **Flagging it for the
owner rather than deciding it is harmless.**

**A retained message now pins the whole chunk.** If a chunk carries a hundred small
frames and the receiver keeps one, the other ninety-nine are held alive by it. The
lead complains about the mirror of this (`_buf` doubling pins up to 2x), so the
property is not new, only relocated — but on a transport that batches aggressively it
could be worse than before. Not measured: the bench sends one frame per chunk.

**The SEND path is untouched**, and the lead names it too: `codec -> encode ->
_encode`, plus `_encodeMetadataPayload`'s `Uint8List.fromList(utf8.encode(...))`.
Nothing here was varied on that side.

**The gRPC 5-byte prefix still duplicates the channel frame's length**, which the
lead raises as a possible wire change. That is the owner's, as the lead itself says.

**And the honest framing of the whole round: no real transport is limited by this.**
The old path sustained 2566 MiB/s end-to-end at 1 MiB; a websocket or TCP link is one
to two orders below that. The gain is real, measured and free, and it is not a
user-visible win on any link that exists.

## Links

Lens RPC-17. Bench P-145 (new). Lead B-116 (partly closed — receive path only).
`IRpcChannel.incoming` carries the contract this relies on.
