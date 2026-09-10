---
round: 305
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-23
bench: none
commit: yes
---

# Round 305 — the public half of the last file

## Target

`rpc_http2_caller_transport.dart` — 675 comment lines in 1989, the single
largest file in the mandate and the last one in it.

**This round deliberately takes HALF of it**, and the split is by audience
rather than by line count: everything a caller or `dart doc` sees — the class
doc, the public factories, the fields, the constants — plus the adjacency
defect. What is left is the internal `_logger` output and inline `//` blocks in
the second half of the file.

The reason is the one 303 already recorded: a batch that cannot be read whole
in one pass is being skimmed, not swept. 1989 lines with 97 Cyrillic lines
scattered through them is more than one honest pass, and a half-attentive sweep
of the second half would leave a file whose defects had been *looked at* without
being *seen*. Saying so is cheaper than pretending otherwise.

## Hypothesis

The caller carries the same two shapes as its two siblings: a declaration
fusion, and the language defect.

## Before

```
                          comments  total   Cyrillic lines
rpc_http2_caller_transport     675   1989               97
```

## Mechanism

**The eighth declaration fusion, and the last one in the mandate.**
`_connectH2ViaProxy`'s doc — the explanation of why the CONNECT handshake keeps
a SINGLE persistent socket subscription, and what breaks if it does not
(`StateError` the moment http2 calls `socket.listen()` a second time) — ran
straight into `_proxyHandshakeTimeout`'s doc with no declaration between them.
Everything attached to the constant, and `_connectH2ViaProxy`, declared 67 lines
below and the most intricate function in the file, had **no doc at all**.

Eight instances, five packages, across every kind of declaration: a public class
(300), a private method (301), a local block (302), a private method again
(303), an alias (304), and now a static function whose doc was eaten by a
constant.

**The language defect, as predicted**, and this file had the most of it: 97
Cyrillic lines. The public surface is done — the class doc, `secureConnect`,
`viaSocket`, `connect`, and every field doc.

The rest followed the established rule: the 156.3 MiB deaf-server table, the
194.3 MiB CONTINUATION flood, the 268 MiB proxy-header OOM, the keepalive relay
table, and the failed-reconnect narrative.

## After

```
                          comments  total   Cyrillic lines
rpc_http2_caller_transport     647   1961               71
```

**-28 comment lines**, and **26 of the 97 Cyrillic lines** gone — all of the
doc-comment ones. Zero code lines changed.

Package: 1529/4569 -> 1501/4541, **33.1%**.

## Canary

The analyzer over lib plus 199 passing tests show the code still compiles and
behaves, not that a comment is right.

The fusion half has the witness round 301 established: query the LSP hover for
`_connectH2ViaProxy`. Before the fix it returns a signature with no docstring,
because the doc belongs to a constant 67 lines above.

## Gate

`melos run analyze` — 21 packages plus rpc_dart_wasm, no issues.
`melos run test:unit --no-select` — 14 packages, 0 failures.
`melos run format:check` — SUCCESS, 0 changed.
`melos run license:check` — compliant, 1302/1302.
Package: `fvm dart analyze lib test` no issues; `fvm dart test -j 8` 199 passed.

## Not fixed

**71 Cyrillic lines remain in this file**, all of them internal: `_logger`
strings and inline `//` comments between roughly line 750 and the end
(`createStream`, `releaseStreamId`, `sendMetadata`, `sendMessage`,
`finishSending`, the incoming handlers, `reconnect` and `close`). They are
operator-facing diagnostics rather than API documentation, which is why they
sort after the doc surface — and they are mechanical, not difficult.

`grep -cE "[А-Яа-яЁё]"` on the file is the check, and it should read 0 when this
is finished. The narrative trimming of that same region goes with it.

That is one more round on this file, and it finishes the mandate.

## Links

RPC-23 (`applied:` gains 305). The eighth fusion completes the argument the lens
has been building since 296: the shape is independent of the KIND of declaration
it lands on — class, method, field, local block, typedef, static function — and
independent of comment density (302) and of package (300-305). What it depends
on is a blank line between a doc and the thing below it, which nothing checks.
