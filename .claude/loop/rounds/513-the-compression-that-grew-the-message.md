---
round: 513
verdict: FIXED
packages: [rpc_dart]
lens: RPC-17
bench: P-151 — new
commit: yes
severity: S3
---

# Round 513 — the compression that grew the message

## Target

Compression without a size threshold — twenty-ninth in the audit's rank, and the
first lead of the run filed at `medium` confidence rather than high.

Lens RPC-17: ask what the work is FOR. Compression is for making messages smaller.

## Hypothesis

Two, and the round's job was to separate them: that compression applied to every
message grows small ones, and that a zero-copy transport compresses across an
in-process boundary.

## Before

Incompressible payload, request frame bytes, compression off → on:

```
  32 B    42 -> 62     (+48%)
  64 B    74 -> 94
  96 B   106 -> 126
 128 B   138 -> 155
 192 B   202 -> 206
 256 B   267 -> 253    <- crossover
 512 B   523 -> 448
4096 B  4107 -> 3138
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b122_compression_threshold.dart`

**First claim CONFIRMED**, with the crossover placed between 192 B (+4) and 256 B
(−14): gzip's fixed overhead is about twenty bytes.

**Second claim REFUTED.** On `memoryPair`, both sides reporting
`supportsZeroCopy: true`, the response comes back `grpc-encoding: NONE (identity)`.
The responder does not gzip across the in-process boundary.

**The first version of this probe would have refuted the true claim too, and the
reason is worth keeping.** It used `'a' * n` as the payload — maximally compressible
— while testing whether compression makes messages BIGGER. That is the case least
likely to grow, and it duly reported a saving at 32 B. Testing growth needs
incompressible input; the repeated-character rows survive as the control.

## Mechanism

Three sites decided `useCompression` from the encoding alone —
`base_processor.dart`, `unary/caller.dart`, `unary/responder.dart` — and none of
them looked at the result.

## After

```
  32 B    42 -> 42
 192 B   202 -> 202
 256 B   267 -> 253
4096 B  4107 -> 3138
```

`RpcGrpcCompression.compressIfSmaller` returns the bytes to send and the value for
the frame's per-message compression flag; the three sites now call it.

**What makes it safe is that the flag is per MESSAGE.** Declaring
`grpc-encoding: gzip` and sending an individual message uncompressed is ordinary
gRPC, and `RpcMessageFrame`'s decoder already reads that flag on every message —
nothing new had to be taught anything.

**Deliberately NOT the lead's sketch.** It proposes a size threshold; comparing is
strictly better, and the control row says why: a 32-byte repeated payload still
compresses 42 → 33, which any threshold above 32 would throw away. A threshold also
needs a number that is right for one kind of traffic and wrong for another. The cost
of comparing is the compression work on payloads that end up sent plain.

Regression: `test/core/compression_never_makes_a_message_bigger_test.dart`,
4 WITNESS and 3 GUARD.

## Canary

`compressIfSmaller` made to keep the compressed form unconditionally. All four
WITNESS arms fail with real byte counts — `Expected: <= 42, Actual: 62`;
`<= 74, 94`; `<= 138, 155`; `<= 202, 206` — and the three GUARDs hold.

The guard that matters is *a SMALL compressible message is still compressed*: it is
what separates this fix from the threshold the lead asked for, and a threshold
implementation would fail it while passing every witness.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` compliant.

## Not fixed

**The CPU half, which is half the lead.** "Tiny messages grow and cost CPU" — the
growth is fixed, the CPU is not, and comparing actually pays slightly more: the
compression still runs on payloads that end up sent plain. Nothing here measured CPU,
so whether that matters is unknown rather than dismissed. A size threshold is the
tool for that half, and it could sit in front of the comparison rather than instead
of it.

**The zero-copy claim is refuted for `memoryPair` but not investigated further.** The
lead's mechanism — the caller never setting `grpc-accept-encoding: identity`, so the
base `identity,gzip` invites the server to gzip — is real in the sense that both
header branches in `caller_pipeline.dart` are gated on `!supportsZeroCopy`. Something
else declines to compress. What that is was not established, and a real isolate pair
was not run.

**`rpcGzipCompress`/`Decompress` still add a `Uint8List.fromList` copy**, and the
lead's note about `sink.close()` never being reached when the size limit throws
inside the chunked decoder — leaving the native zlib filter to the finaliser — is
untouched and unmeasured. That last one is a resource question, not a cost one, and
deserves its own round.

## Links

Lens RPC-17. Bench P-151 (new). Lead B-122 (closed on the growth half).
