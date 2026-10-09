---
round: 456
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-108 — new
commit: yes
severity: S2
---

# Round 456 — the registry was lenient and nothing else was

## Target

B-82. Its decision was to measure what happens today FIRST, because the two
plausible outcomes need opposite verdicts: UNIMPLEMENTED with a usable
`grpc-accept-encoding` is fine, a decompression attempt against a codec that does
not exist is not.

## Hypothesis

`RpcGrpcCompression` normalises before comparing; eleven sites outside it compare
a raw header against the lower-case constant. `identity` is the case that matters,
because it is the "no compression" sentinel.

## Before

**The lead expected a hand-built peer to be necessary. It is not** — the encoding
is selected by a header on the call CONTEXT, which is what
`_context?.getHeader(grpcEncoding)` reads, so the library's own caller reaches it:

```
own caller, grpc-encoding=identity   OK saw:x
own caller, grpc-encoding=Identity   status=13 Internal server error
```

Probe:
`packages/transport/rpc_dart_http2/.dart_tool/probe/encoding_case_matters.dart`

The hand-built peer arms are in the probe too, and they say something the lead did
not predict: **from a foreign peer the case difference is INERT.** With the
compression flag at 0, `Identity` behaves exactly like `identity`; only the
library's own SEND path turns it into a failure.

## Mechanism

Three answers to one question, two of them normalising:

```
isSupported('Identity')     true       normalises, so nothing is refused
'Identity' != 'identity'    true       so compression is switched ON
compress(enc: 'Identity')   unchanged  normalises to identity, no compression
```

So the compressed FLAG goes out on bytes nothing compressed, and the peer cannot
decompress them. The registry was lenient, the eleven comparisons were not, and
the value passed both checks in opposite directions.

## After

One accessor, `RpcGrpcCompression.isIdentity(String?)`, which also absorbs the
`== null` half that every site was spelling out. All eleven sites call it.
`Identity` reads `OK saw:x`.

Inbound metadata is NOT normalised in place, as the decision required: the
accessor answers a question, it does not rewrite what the peer sent.

## Canary

`isIdentity` made case-sensitive again — the comparison the eleven sites used to
make:

    Expected: 'saw:x'
      Actual: 'status=13'
    the registry is case-insensitive, so a capitalised identity names the same
    codec; treating it as compression sets the flag on bytes nothing compressed

**The canary is also why the witness moved packages.** Run first against a core
test over `RpcChannelTransport.pair()`, only the unit assertion failed — the
end-to-end arm passed on BOTH sides, because in one process compress and
decompress both normalise and the flag-on-uncompressed-bytes round trips
harmlessly. A test that passes either way proves nothing (canary.md item 4), so
the behavioural witness is in `rpc_dart_http2`, where the responder's parser is
built from the encoding the pipeline read and the mismatch is fatal. The core test
stays, labelled as a contract test and not a witness.

## Gate

`melos run analyze` SUCCESS. `test:unit` SUCCESS over 14 packages; `rpc_dart`
1676 and `rpc_dart_http2` 247, up four and two. `format:check` and
`license:check` SUCCESS.

The eleven edits removed the `!= null` guards that were also PROMOTING the
variable, so seven downstream uses needed `!`. Sound, because `!isIdentity(x)`
implies `x != null` — but the analyzer is what caught them, not reading.

## Not fixed

**`gzip` does not round trip either, and that is NOT about case.** Measured on
both sides of this fix:

```
own caller, grpc-encoding=gzip   status=13 Internal server error
own caller, grpc-encoding=GZIP   status=13 Internal server error
```

Both spellings fail, so the accessor cannot be the cause, and `isSupported`
returns true from the registry's own map — so a codec IS registered and the
compression path still fails. Filed as **B-91**. It is a bigger claim than this
round can support and it is not diagnosed here.

**The status for a flag/encoding contradiction is an opaque `INTERNAL: Internal
server error` with no `grpc-accept-encoding`**, where an unregistered codec gets a
precise UNIMPLEMENTED naming the remedy. That is L-10's default-deny INTERNAL
hiding a cause, and it is what made the gzip row hard to read. Noted in B-91
rather than filed twice.

## Links

- RPC-25 — one question, three answers, and the two that normalised were the
  registry's own
- P-108 — what the case of `grpc-encoding` changes
- B-82 — closed by this round
- B-91 — new, the gzip round trip
- L-10 — a hand-built peer needs the real serializer; and its other half, a
  default-deny INTERNAL hiding the cause
- Witness: `rpc_dart_http2/test/identity_case_round_trips_test.dart`
- Contract test, explicitly not a witness:
  `rpc_dart/test/core/encoding_case_does_not_change_the_codec_test.dart`
