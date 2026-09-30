---
status: open
round: 541
commit: aeebbbfb
paths: [packages/core/rpc_dart/test/core/compression_never_makes_a_message_bigger_test.dart]
probe: none
reason: "CONFIRMED by running it: six failures on `melos run test:web`, all in one file, all `Unsupported grpc-encoding: gzip`. The test has no `@TestOn('vm')` and the built-in gzip does not exist on dart2js, so it has been red on that target since the round that wrote it"
---

# B-211 — `test:web` has been red since round 513, in one file

Found while running the web target after a core change in round 541. Not that round's
target and unrelated to it — nothing there touches compression.

```
melos run test:web   +1764 ~1 -6
```

All six are `packages/core/rpc_dart/test/core/compression_never_makes_a_message_bigger_test.dart`:

```
RpcStatusException(12): Unsupported grpc-encoding: gzip. Supported: identity.
On web/dart2js the built-in gzip is unavailable; register a cross-platform codec
(e.g. RpcGzipCodec.register() from package:rpc_dart_compression).
```

Four `WITNESS` cases and two `GUARD` cases; the one case that passes is the one with
compression disabled.

**The library is behaving correctly.** The message is the library's own, it names the
remedy, and `RpcGrpcCompression.isSupported` returning false for gzip on dart2js is the
documented platform difference. What is wrong is the TEST: it asks for gzip on every
platform and has no `@TestOn('vm')`.

## Why it matters

`test:web` is one of the targets `config.md` lists under "Targets nobody runs", and a target
that is already red is a target no later round can read. Every web-relevant change since
round 513 has had to distinguish its own failures from these six, or skip the run.

## Witness a round would build

None needed — running it is the witness. The question is which fix:
**`@TestOn('vm')`** on the file, which says the behaviour under test is VM-only; or
**register `RpcGzipCodec`** from `rpc_dart_compression` in a setup, which keeps the
assertion meaningful on both platforms but makes a core test depend on another package;
or **skip the gzip cases only**, keeping the identity ones everywhere.

## Fix sketch

The third, probably: what round 513 measured is that `compressIfSmaller` must not grow a
message, and that rule is not about gzip. Whichever is chosen, the round that does it should
re-run `test:web` to a clean run, because a second red file would be invisible behind this
one.

## Owner decision

—
