---
round: 850
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-22
bench: none — the probe has no defect to show a control against; its valid row is the reference and each other row is checked against the gRPC rule or rpc_dart's documented lenience
commit: yes
release: none
---

# Round 850 — what a responder answers to hostile request metadata

## Target

The oracle of rounds 846-848 on the responder's request metadata, over a
raw channel (`r850_responder_metadata_oracle.dart`): fourteen ways a client
can open a stream, the status sent and whether the handler ran.

## Hypothesis

A responder answers every malformed opening with a status gRPC or rpc_dart's
documented lenience gives, and runs no handler for one it refuses.

## Before

```
scenario                        status   handler
valid                           0        ran
unknown method / service        12       -
path without slash, three
segments, empty                 3        -
grpc-encoding br, flag set      12       -   (gRPC: UNIMPLEMENTED)
grpc-encoding gzip, valid gzip  0        ran
flag set, no encoding           13       -
content-type text/plain         0        ran (contentTypeValidation is lenient by default)
grpc-timeout 0n                 4        -
grpc-timeout junk               0        ran (an unparseable timeout is no deadline)
two content-types               0        ran
data with no metadata frame     none     -   (dropped, C-10)
```

## Mechanism

None found.

## After

n/a.

## Canary

n/a — no fix.

## Gate

No library change.

## Siblings

—

## Not fixed

`grpc-timeout` is parsed leniently (a sign, whitespace, junk read as no
deadline), where grpc-go refuses a malformed one with INTERNAL; a peer that
wants no deadline can omit the header, so nothing is gained by sending junk.

## Links

Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md`. Negative
`../checked/C-85-what-a-responder-answers-to-hostile-request-metadata.md`.
