---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/encoding_case_matters.dart
round: 456
commit: b5b5980f
paths: [packages/core/rpc_dart/lib/src/core/compression.dart, packages/core/rpc_dart/lib/src/rpc/streams/**]
status: valid
---

# P-108 — what the case of `grpc-encoding` changes

## Why it exists

B-82 says eleven sites compare a raw header against a lower-case constant while
the registry normalises. The variable is therefore the SPELLING, held against the
same codec.

## The harness, and the arm the lead did not expect

Two halves, and the second is where the defect actually lives.

**A hand-built peer** — raw http2 client against a real `RpcHttp2Server` — sending
`grpc-encoding` spelled four ways, crossed with the compression FLAG at 0 and 1.
The flag is varied because it decides whether a decompressor is looked up at all,
so case alone can be inert at 0 and biting at 1.

**The library's OWN caller**, with the encoding in the call context. The lead
assumed a hand-built peer was required; it is not, because the encoding is
selected by a context header and that is what `_context?.getHeader(grpcEncoding)`
reads.

## The numbers (round 456)

```
hand-built peer, flag 0      before and after fix
  absent / identity / Identity   all OK      <- case INERT from a peer
  nosuchcodec                    UNIMPLEMENTED, accept=identity,gzip

hand-built peer, flag 1
  absent / identity / Identity   INTERNAL "Internal server error"
  nosuchcodec                    UNIMPLEMENTED

own caller                   before          after
  grpc-encoding=identity     OK saw:x        OK saw:x
  grpc-encoding=Identity     status=13       OK saw:x
  grpc-encoding=gzip         status=13       status=13   <- B-91
  grpc-encoding=GZIP         status=13       status=13   <- B-91
```

## Reused in round 461 — and it is now the guard on the OTHER defect

`gzip` failing was B-91, which turned out to be round 455's own regression: the
frame was wrapped twice and the compression bit lost. After 457 reverted it and
461 redid the fix inside the parser, all four rows pass:

```
own caller, round 461        emitFramed: true    canary, emitFramed: false
  grpc-encoding=identity     OK saw:x            status=13
  grpc-encoding=Identity     OK saw:x            status=13
  grpc-encoding=gzip         OK saw:x            status=13
  grpc-encoding=GZIP         OK saw:x            status=13
```

**One switch reddens this bench AND P-107**, which is the evidence that the case
defect and the framing defect were one ambiguity in the parser's output shape.
So this probe is no longer only about spelling: it is the compressed-message arm
whose absence let 455 ship (L-15).

## Measures

The call's outcome: the handler's answer, or the grpc-status with its message and
whether a `grpc-accept-encoding` came with it. That last column is what separates
a precise refusal from a default-deny.

## Control

`identity` — the spelling the library itself always sends — in every arm, so a
failure on `Identity` is the case and not the path. `absent` as a second control,
because it takes the null branch rather than either spelling. And `nosuchcodec`
for contrast: it proves the refusal machinery works and is informative, which is
what makes the opaque INTERNAL on the other rows worth noticing.

## What it establishes, and what it does not

Establishes: a capitalised `identity` from the library's own caller produced
INTERNAL, because `isSupported` normalised and admitted it while the comparison
said "not identity" and switched compression on. And that from a foreign PEER at
flag 0 the same value is inert — the lead's assumption about needing a hand-built
peer was backwards.

Does NOT establish why `gzip` fails. Both spellings fail identically, before and
after the fix, so it is a different defect — B-91 — and this bench only shows the
symptom, behind an INTERNAL that names nothing.
