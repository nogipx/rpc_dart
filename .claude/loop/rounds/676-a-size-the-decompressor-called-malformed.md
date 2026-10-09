---
round: 676
verdict: FIXED
packages: [rpc_dart, rpc_dart_compression]
lens: RPC-19
bench: none — the parity matrix filed with the lead, `.dart_tool/probe/parity_matrix.dart` (row 5.stream-item-over-limit), re-run before and after
commit: yes
release: changelog
severity: S2
---

# Round 676 — a size the decompressor called malformed

## Target

The six parity leads B-248..B-253 were filed by another session as owner
questions; the owner decided all six in this session (recorded in each lead,
statuses now `decided by owner (round 676)`). This round carries out B-249,
core first in the owner's order.

One exception type carried two meanings: both gzip codecs threw
`FormatException` for an output over the limit AND for malformed input, so the
parser could only answer INTERNAL. Decided: a limit overrun is
RESOURCE_EXHAUSTED, malformed input stays INTERNAL.

Scope, counted: 4 limit throws -- the built-in `_LimitedByteSink`, and in
`RpcGzipCodec` the declared-size pre-check, the bounded-inflate abort and the
post-decode check -- plus the interface doc and the parser's comment.

## Hypothesis

On memory and isolate the caller compresses what shrinks, so the limit fires
inside the decompressor and reads as INTERNAL; the other transports check the
size before decompressing and say RESOURCE_EXHAUSTED.

## Before

```
5.stream-item-over-limit (66560 B against 65536)
  memory/isolate   13 "Compressed gRPC payload could not be decompressed: it is malformed, or it expands ..."
  websocket/http1/http2   8
```

## Mechanism

As the lead read it: `parser.dart` rethrows an `RpcException` from the
decompressor and maps everything else to 13, and the codecs threw
`FormatException` for both causes.

## Fix

The four limit throws are a RESOURCE_EXHAUSTED `RpcStatusException`; malformed
input still throws `FormatException` and still reads 13. The interface doc says
what a codec must throw for each. In `RpcGzipCodec` the post-decode size check
now runs before the trailer check: a payload whose trailer understates its
output fails both, and on the web the trailer check came first and called it
malformed.

## After

```
5.stream-item-over-limit
  memory/isolate   8 "Decompressed gzip payload exceeds limit: 66568 bytes (max: ...)"
  websocket/http1/http2   8
```

## Canary

`packages/core/rpc_dart/test/streams/an_oversized_compressed_item_is_resource_exhausted_test.dart`,
the built-in limit back to `FormatException`: `Expected: <Instance of
'RpcStatusException'> with statusCode: <8> Actual: RpcStatusException(13):
Compressed gRPC payload could not be decompressed`. Restored: green.

Five tests pinned `FormatException` for a limit overrun (four in
rpc_dart_compression, `gzip_bomb_guard_test` in core) and now pin
RESOURCE_EXHAUSTED; `isize_understates_on_web_test` on node is what showed the
trailer-first ordering. `decompress_failure_message_test` -- malformed input
reads 13 and does not name the limit -- unchanged and green.

## The verdict questions

1. Yes: the canary restores the old throw alone.
2. Yes: 13 against 8.
3. Yes: the status the caller received.
4. Not zero-valued.
5. Yes, quoted.
6. One mechanism, four sites of it; one canary on the site the witness drives.
   The three codec sites are pinned by their own updated tests.
7. Yes; the split is the owner's decision.
8. None.

## Gate

`analyze`, `test:unit` (15 packages), `format:check`, `license:check` green;
`rpc_dart_compression` on node +28.

## Not fixed

A third-party codec that signals its limit with some other type still reads
13; the interface doc now tells it what to throw. Nothing else on B-249.

## Links

Lead `../backlog/B-249-an-oversized-in-process-message-reads-as-internal.md` closed.
Decisions recorded in B-248, B-250, B-251, B-252, B-253.
Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md` -- `applied: [..., 676]`.
