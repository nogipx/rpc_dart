---
status: closed (round 630)
round: 630
commit: e78818bf
paths: [packages/core/rpc_dart/lib/src/core/metadata.dart]
probe: none — audit probe `packages/core/rpc_dart/.dart_tool/probe/correct_wire_codec_units.dart`, not yet registered
reason: "FIXED in round 630: the message is encoded a character at a time and a character crossing the cap is left out whole; every case decodes to a prefix on VM and node. Previously: bench — encodeGrpcMessage trims the encoded text without respecting UTF-8 sequence boundaries, so a long non-ASCII message arrives as a non-prefix ending in U+FFFD"
---

# B-237 — a trimmed message splits a character

Found by the independent audit of 2026-10-02 (protocol), reproduced before
filing.

## Measured

```
'Ж' x 200            encoded 1023   decoded 171 chars   prefix false   tail U+FFFD
'x' x 1020 + 'Ж'     encoded 1023   decoded 1021        prefix false   tail U+FFFD
ASCII 1100           encoded 1024   decoded 1024        prefix true
```

Same on node. A Cyrillic character costs 6 encoded characters, so any Russian
message over ~170 characters hits this under the default cap. `forTrailer`'s doc
and `audit_trailer_survives_header_cap_test` promise a prefix; the test is ASCII.

## Fix direction

Trim at a UTF-8 sequence boundary: back off over continuation bytes (`%8x`-`%Bx`)
and the lead byte they belong to.

## Owner decision

—
