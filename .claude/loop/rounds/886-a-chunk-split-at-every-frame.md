---
round: 886
verdict: FIXED
packages: [rpc_dart]
lens: RPC-27
bench: none — the bench is the existing matrix row "I-3 an oversized message that never finishes is refused | socket" run on Linux (Docker, dart:3.10.1), plus a size sweep in a scratch test (`i3_probe_test.dart`, kept outside the tree); the sweep is promoted to the unit witness
commit: yes
severity: S2 — "a limit that is off but still bounds"
release: changelog
---

# Round 886 — a chunk split at every frame

## Target

Not chosen from `next`: CI went red on `bab44fe6` (GitHub Actions, ubuntu
24.04) in one matrix cell, I-3 "an oversized message that never finishes is
refused | socket", on its valid neighbour: "a message at the limit: status
14 ... The stream closed before the peer sent a status". The same cell is
green on macOS (5 of 5). A red on CI with an invariant behind it comes before
a lens. Records weighed: round 645 and the commit `27fded18` (a chunk spanning
two frames) touch the same code; B-229 and round 636 (a payload pins its
chunk) bear on whether decoding more frames from a view of one chunk pins it;
read in current code: a payload that waits is copied out of its chunk, so the
loop below pins nothing new.

## Hypothesis

`RpcFrameMultiplexedChannel._onData` checks its reassembly cap against
buffered prefix plus the whole chunk, after splitting off only the first
frame. When a byte stream coalesces two or more small frames in front of a
message near the limit, the rest is still over the cap and the connection is
closed, though no frame exceeds the limit. Fails to hold if the cell passes on
Linux with the split unchanged, or fails at sizes far below the limit.

## Before

Linux (Docker), server `maxMessageLengthBytes` 64 KiB unless stated, one
unary call per fresh server, outcome at the caller:

```
transport  limit    size     outcome
websocket  64 KiB   1024     ok
websocket  64 KiB   32768    ok
websocket  64 KiB   65472    ok
websocket  64 KiB   65536    ok
socket     64 KiB   1024     ok
socket     64 KiB   32768    ok
socket     64 KiB   65472    status 14, stream closed before a status
socket     64 KiB   65536    status 14, stream closed before a status
socket     16 MiB   65472    ok        <- control: the same bytes under the default cap
socket     16 MiB   65536    ok
I-3 | socket cell: 8 of 8 runs red on Linux, 5 of 5 green on macOS
```

Instrumented (prints in a copy inside the container, never in the tree): the
server receives ONE chunk of 65809 bytes, the 8-byte preface and frames of
48, 267 and 65486 bytes, and fails with "Incoming frame buffer overflow: 65753
bytes (max: 65550)". Over websocket the same frames arrive as separate chunks
(56, 267, 65486).

Probe: `i3_probe_test.dart` (scratch, copied into the conformance package in
the container) — the size sweep above.

## Mechanism

The cap bounds bytes the channel buffers, but it was read off a chunk, whose
size the kernel picks. Splitting off one frame fixed two frames per chunk
(round of `27fded18`); three is enough to defeat it.

## After

The split runs while the rest is over the cap and its first frame is
complete; the cap then bounds only the incomplete frame at the end, which is
what gets copied. Linux (Docker): every row of the sweep `ok`; the I-3 file
5 of 5 green; the whole conformance matrix `+649 ~146`, no failures.

Cost: only a chunk over the cap takes the loop. 63 MiB of empty frames in one
chunk decodes in 3346 ms against 2220 ms for the same bytes in 1 MiB chunks,
which the channel already accepted; peak reassembly 0 bytes in both.

## Canary

The `while` switched back to the single `if`:

- WITNESS `a maximal frame behind two small frames in one chunk is delivered`
  (`a_chunk_spanning_two_frames_is_not_an_overflow_test.dart`): "Expected:
  empty Actual: [" (the RpcFrameException).
- `GUARD: what a split chunk leaves to buffer still meets the cap`
  (`oversized_frame_is_per_call_test.dart`): "Expected: [11, 13] Actual:
  [11]". With the fix it is the guard that the incomplete tail is still
  refused past an explicit `maxBufferedBytes`.

Restored: both green.

Two existing tests changed. The old guard "a chunk still over the cap past
its first frame closes" asserted the defect itself, so it became the guard
above. `oversized_chunk_not_copied_test` fed 64 MiB of zeros, which are valid
empty frames, so it waited for a refusal that no longer comes; its input is
now one frame the message limit admits and the buffer cannot hold, which is
what it measures (the buffer is not grown for a chunk it refuses).

## Gate

`melos run analyze` (after the last format, L-24), `melos run
test:unit:quiet --no-select`, `melos run format:check`, `melos run
license:check`: green. The two changed test files on dart2js (`-p node`):
`+18`. The conformance matrix on Linux: green.

## Siblings

- channel: fixed here — the frame channel is where the cap lives; the
  in-memory member is green in the Linux matrix after the fix.
- http: clean — `i2_message_up_to_the_limit_test.dart` and
  `i3_memory_per_peer_test.dart` rows for http, green on Linux before (CI log
  of `bab44fe6`) and after; its responder bounds the body, not chunks of this
  channel.
- http2: clean — the same two test files, http2 rows green on Linux before
  and after.
- websocket: clean — probe `i3_probe_test.dart`, every size `ok` at 64 KiB
  before the fix (one websocket message is one chunk); the same two test
  files green after.
- isolate: clean — `i2_message_up_to_the_limit_test.dart` isolate rows green
  on Linux before and after; a SendPort message is one chunk.
- wasm: clean — `i2_message_up_to_the_limit_test.dart` wasm rows green on
  Linux before and after; the bridge delivers one message per chunk.

## Not fixed

—

## Links

RPC-27; I-2, I-3; round 645, B-229, round 636; L-20, L-24.
