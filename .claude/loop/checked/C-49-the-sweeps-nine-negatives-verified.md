---
round: 450
commit: db96aa72
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_http/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_isolate/lib/**]
probe: none — a read, nine greps over `lib/`
scope: [rpc_dart, rpc_dart_http, rpc_dart_http2, rpc_dart_websocket, rpc_dart_isolate]
---

# C-49 — the `ff930001` sweep's nine claimed negatives, verified

> **Eight hold. One is FALSE as written** and is now `B-89`. The whole list was
> checked in one pass, because the defect being checked for was "nobody checked
> it" and a partial pass reproduces that.

## What was claimed

The duplication sweep listed nine things it believed were already shared, and
therefore did not report. Nothing had ever verified that list — B-87.

## Verified shared (8 of 9)

Each is one implementation in core with the transports calling it.

```
grpc-timeout              RpcMetadata.encodeGrpcTimeout / .parseGrpcTimeout
                          core/metadata.dart:199 and one parse call site;
                          THREE encode call sites, all calling the one function
percent-encoding of       RpcMetadata.encodeGrpcMessage / .decodeGrpcMessage
grpc-message              core/metadata.dart:404; http2's caller calls encode
-bin base64               core/metadata.dart only (:187, :264-290), including
                          the padding/url-safe normalisation and its reasons
drainUntilIdle            core/drain.dart:73, called by all three servers
                          (http2, websocket, http) -- and its COUNT is extracted
                          too, which is the half B-63 item 2 was about
the 5-byte frame and      core/protocol.dart + core/parser.dart. http2's
its parser                `ensureGrpcFrame` CALLS `RpcMessageFrame.parseHeader`
                          and `.encode` rather than re-deriving them -- checked,
                          because B-78 describes it as parsing bytes itself and
                          that reads like a second implementation
backoff                   core/resilience/backoff_policy.dart. The transports
                          mention backoff in COMMENTS only; no second policy
wireStatusFor             core/errors.dart, with the platform half in
                          core/platform_error_io.dart
bufferedBytes             core only. Its ABSENCE in http2 is B-79's finding, not
                          a duplication -- the two questions are different and
                          the sweep's claim was about the second
```

## FALSE as written (1 of 9): parity alignment

The claim is *"parity alignment in `RpcStreamIdManager`"*. True of the manager —
round 360 gave it one home, and `_alignedStart`'s own comment says so: *"One home
for the alignment, or the two routes into the same concept drift — and they
had."*

**And http2 does not use `RpcStreamIdManager` at all.** It carries its own
counters and its own parity rules:

```
core, RpcStreamIdManager._alignedStart
      resumeAfter.isOdd == isClient ? resumeAfter : resumeAfter + 1
      parameterised by side

http2 caller, resumeStreamIdsAfter (:50-55)
      streamId.isOdd ? streamId : streamId + 1
      client-odd hard-coded, plus `_nextStreamId = 1` and `+= 2`

http2 responder
      `_nextStreamId = 2`
```

So one rule has three homes, and a reader who takes the sweep's word believes it
has one. No divergence has been SHOWN to bite — the http2 caller's hard-coding is
correct for a class whose `isClient` is a literal `true` — which is why this is a
lead and not a defect. Filed as **B-89**.

## Control

A negative whose evidence is a grep needs the grep to be able to come back
non-empty, and it did: the parity entry is the arm that returned a second and
third implementation. Eight entries reading "one home" against one reading
"three" is what separates this from a search that could only ever agree.

The second control is B-63's "Already extracted" list, which is the CHECKED
version of roughly the same set and was preferred wherever the two overlap.

## Do not re-read this list a fourth time

That is what the record is for. An entry that turns out not to be shared gets its
own number — `B-89` is the first — rather than being folded back in here.
