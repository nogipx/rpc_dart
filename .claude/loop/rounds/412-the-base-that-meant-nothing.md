---
round: 412
verdict: FIXED
packages: [rpc_dart, rpc_dart_http2, rpc_dart_http, rpc_notify, rpc_dart_framework]
lens: RPC-25
bench: P-93 — new
commit: yes
---

# Round 412 — the base that meant nothing

## Target

Finishing the typing goal: the categories round 408 left unaudited, and then the
owner's own proposal — make `RpcException` abstract.

## The categories, audited

**`TimeoutException`, all 11 correct, and two of those were already decided.**
Three are call deadlines and sit directly beside `RpcDeadlineExceededException`
in the same `onTimeout`, chosen by whether a bounding deadline exists:

```dart
if (boundingDeadline != null) throw RpcDeadlineExceededException(...);
throw TimeoutException('Call timeout: $effectiveTimeout');
```

`deadline_exception_parity_test`'s header records that split as deliberate — *an
explicit `timeout:` argument is NOT a deadline*. The other eight are local
operation timeouts (connect, ping, spawn, body read), where the dart:async type
is idiomatic.

`FormatException`: 23 of 31 are in the CBOR codec, where malformed input is
exactly what that type is for. `UnsupportedError`: capability refusals.

## Hypothesis

The remaining raw `RpcException` sites are a formatting matter.

## Before

They are not. `_answerFramingViolation` classifies by TYPE and says so:

> Matched on the TYPE, never on message text: a text match for 'too large'
> misses the buffer-overflow wording and the refusal comes back as Internal.

```dart
final status = error is RpcException ? resourceExhausted : internal;
```

The intent is exact and the discriminator cannot express it. **`RpcException` is
the BASE of the whole hierarchy**, so `RpcMessageFrame.parseHeader`'s
MALFORMED-framing throws — raised on the very same path — matched it too. P-93,
two arms differing only in the five bytes of the gRPC prefix:

```
limit      grpc-status  8  "gRPC frame payload is too large: 33554432 (max: 16777216)"
malformed  grpc-status  8  "Invalid compression flag in gRPC message: 2"
```

RESOURCE_EXHAUSTED is retryable. A structurally corrupt frame was answered *try
again*, and a corrupt frame does not get less corrupt on retry.

## Mechanism

The status moved onto the type. The parser's four real limits are
RESOURCE_EXHAUSTED — the answer grpc-go and grpc-java both give for a message
larger than the maximum — and `protocol.dart`'s two malformed throws are
INTERNAL.

**The owner asked whether RESOURCE_EXHAUSTED was right, and caught a mistake.**
I had also applied it to the decompression site, where the code's own comment
had already predicted the error:

> NOT "exceeds the limit". A decompressor throws for the bomb it was asked to
> stop AND for input that is malformed, truncated or not compressed at all, and
> this catch cannot tell them apart — so naming one of them told a peer with a
> corrupt frame to send less, which cannot help.

Corrected to INTERNAL, which is also what grpc-go answers for a decompression
failure. A status is a claim about the CAUSE, and that site has two.

`_answerFramingViolation` now asks `wireStatusFor`, which **also closed a leak**:
its trailer message was `'$error'` UNCONDITIONALLY, so a foreign error's text
went to the peer past the default-deny that exists to stop exactly that.

## After

```
limit      grpc-status  8      malformed  grpc-status 13
```

And `RpcException` is abstract. That is what forced the remaining 13 raw sites
to choose:

```
UNIMPLEMENTED       unsupported grpc-encoding x2 (the gRPC spec's own answer),
                    method not registered, no transport for routing
RESOURCE_EXHAUSTED  stream ids exhausted, too many active streams x2,
                    HTTP response body over the limit
INTERNAL            registration conflicts x5, transfer-mode mismatch,
                    compressed payload without grpc-encoding, extract failure
```

## Canary

Thirteen tests in `test/errors/one_hierarchy_test.dart`. The two that matter
most for THIS round: the base cannot be constructed while `e is RpcException`
still means "ours" — abstract must not cost the catch — and `wireStatusFor`'s
second branch still serves a subclass carrying no status of its own, which is
what `RpcDataError` and `RpcWebSocketNonBinaryFrame` are.

## Gate

`melos run analyze` clean over 21 packages + wasm; `format:check` clean;
`license:check` compliant; workspace suite **SUCCESS in all 14 packages**,
rpc_dart **+1578**.

The abstract change surfaced **31 test construction sites**, which is the
visible half of the breaking cost and the reason to state it plainly.

## Not fixed

`RpcHttp2StreamError`, taken in round 413. And four types in `data/` and
`blob/`, outside the goal's scope.

## Links

- P-93 — new
- Round 408 — which named these categories as unaudited
- L-12 — the count that made this a round rather than a rename
