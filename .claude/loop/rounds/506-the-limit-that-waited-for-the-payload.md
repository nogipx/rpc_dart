---
round: 506
verdict: FIXED
packages: [rpc_dart]
lens: RPC-17
bench: P-144 — new
commit: yes
severity: S2
---

# Round 506 — the limit that waited for the payload

## Target

The metadata size check in `core/channel_frame.dart` — twenty-second in the audit's
rank.

Lens RPC-17, *the limit fires after residency*. This is that shape in its purest
form yet: the limit is correct, the check is present, the error message is right, and
it is evaluated one line too late. Everything the check needs is in the 9-byte
header, and it sat below the test for whether the payload had arrived.

## Hypothesis

A frame whose header already declares a metadata payload over `maxMetadataBytes` is
buffered in full before it is refused.

## Before

Declared payload 10 MiB — over `maxMetadataBytes` (64 KiB), under
`maxFramedMessageBytes` (16 MiB) — fed in 64 KiB chunks:

```
METADATA flag set                accepted 10485769 bytes before refusing
CONTROL data frame, same size    accepted 10485769 bytes, NO REFUSAL
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b115_oversized_metadata_buffered.dart`

**CONFIRMED: 160x the ceiling the frame was subject to.** The refusal message is
correct and arrives — `Incoming metadata frame too large: 10485760 bytes (max:
65536)` — after the channel has been made to hold all ten megabytes.

The control is the same declared size WITHOUT the flag, which is legal and must be
accepted in full. It identifies the flag rather than the size as the cause, and it is
what keeps a small number in the after-table from being indistinguishable from a rig
that cannot feed 10 MiB.

## Mechanism

```dart
final payloadStart = offset + headerSize;
if (data.length < payloadStart + payloadLen) return null;   // incomplete: wait
...
if (isMetadata && maxMetadataLen != null && payloadLen > maxMetadataLen) throw ...;
```

`_decodeAt` is called on the reassembly buffer after every chunk. While the frame is
incomplete it returns null, the caller appends the next chunk and calls again — so a
check placed after that early return is only reachable once the payload is entirely
resident. The limit that exists to prevent the buffering was conditional on the
buffering having happened.

**Both of its inputs are header fields.** `isMetadata` comes from the flags byte and
`payloadLen` from bytes 5-8; there was never anything to wait for.

The server is the side that pays, and not by accident. `_refusedFrameHeader` in the
channel already applies the metadata ceiling from the header — but it returns null
outright when `closeOnOversizedFrame` is true, which is the SERVER's default. So the
half of the codebase that had this right was the client, and the comment there
explains the split. The audit's phrasing picked exactly that up.

## After

```
METADATA flag set                accepted 9 bytes before refusing
CONTROL data frame, same size    accepted 10485769 bytes, NO REFUSAL
```

The check moved above the completeness check, with `isMetadata` hoisted to join the
other two header reads. 9 bytes is the header: nothing of the payload is accepted.

`decodeAll`'s doc promised header-only rejection for `maxPayloadLen` and said nothing
about `maxMetadataLen` — technically accurate, and the guarantee it names was exactly
the one missing. Now stated for both.

Regression:
`test/core/an_oversized_metadata_frame_is_refused_from_its_header_test.dart`,
1 WITNESS and 2 GUARD.

## Canary

The check moved back below the completeness check, in place. The WITNESS fails:

```
Expected: <9>
  Actual: <10485769>
```

Both GUARDs stay green — which is the point of the second one. Moving a limit check
earlier is one edit away from moving it somewhere that refuses everything, and
nothing else in the file would notice; that guard drives a real, legal metadata frame
end to end and reads `/Svc/method` off the far side.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run license:check` compliant.
`analyze` failed once, on an `unnecessary_import` of `dart:typed_data` in this
round's own new test — the barrel re-exports it — and `format:check` once on the same
file; both green after.

## Not fixed

**A peer that sends the whole frame in ONE chunk still gets the peak resident.** On
`dart:io`'s WebSocket a message arrives as a single chunk, so the bytes exist before
this class sees them; `_maxBufferedFrameBytes` bounds that at 16 MiB and is untouched.
This round is about incremental delivery, which is the case where the metadata ceiling
was doing nothing at all. The two are different defences and only one of them was
missing.

**The refusal still kills the connection on the server.** `closeOnOversizedFrame:
true` is deliberate and documented — dart:io's buffering means closing is the only
lever that stops a peer repeating the peak — and this round only changes how early
the decision is made, not what it is.

**`_refusedFrameHeader` still returns null for the whole server path.** With
`_decodeAt` now refusing from the header, the server reaches the same conclusion one
layer down, so the asymmetry is no longer a memory difference — but it is still two
places implementing one rule, and the client's copy is now redundant for metadata
frames. Not merged: that is a refactor with no measured failure behind it.

## Links

Lens RPC-17. Bench P-144 (new). Lead B-115 (closed). The client-side header check in
`frame_multiplexed_channel.dart:215-232` is the sibling that already had this right.
