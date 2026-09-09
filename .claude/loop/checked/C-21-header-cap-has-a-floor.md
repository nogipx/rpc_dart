---
round: 216
commit: 10ba2a93
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_http2/lib/**]
scope: [core, http2]
---

# C-21 — `maxHeaderValueBytes` has a floor, and below it nothing works

**Not a defect. Read this before tightening that knob in any bench.**

`maxHeaderValueBytes` bounds INBOUND header values, and rpc_dart's own request
headers are among them. A request-id is a 36-byte UUID; `application/grpc` is
16. So a cap below roughly 40 makes a server refuse every request it receives,
before any handler runs:

    cap    unimplemented   un-consumed window   a plain valid call
    8192   status 12       status 8             ok
      64   status 12       status 8             ok
      16   status 3        status 3             status 3

At 16 the third column is the tell: an ordinary, entirely valid call fails with
INVALID_ARGUMENT. Nothing in that row says anything about trailers.

## Control

The same three paths at 8192 and at 64. 64 is below every diagnosis these paths
write (40-70 characters) and above every header rpc_dart sends, so it isolates
the trailer; 16 does not, and any conclusion drawn from a run at 16 is about the
request headers instead.

## Why it is not filed as a defect

It is a misconfiguration and it fails loudly: the very first call errors, so it
cannot reach production unnoticed. The library could refuse such a policy at
construction, which would be friendlier, but nothing is silently wrong today.

## Why it is worth a record anyway

It confounds benches. Round 216 spent a probe rebuild on it — the first run of
P-08 read "status 3" on every row and looked like a finding about trailers. The
pack's rule applies exactly: a refusal is evidence only if it names the control
under test.
