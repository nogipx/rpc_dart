---
round: 301
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-23
bench: none
commit: yes
---

# Round 301 — the language server saw it too

## Target

`rpc_dart_http`, the whole `lib/`, at the batch unit — the third package of the
owner's mandate, in order, after core (293-299) and websocket (300). The
detector put it at **39.2% comment lines**, and every one of its four real files
was above 35%.

## Hypothesis

300 found the adjacency shape outside core for the first time and concluded it
is a property of the corpus. A second non-core package tests that directly: if
the conclusion holds, `rpc_dart_http` has one too, without looking for anything
special.

## Before

Probe: `grep -rcE "^[[:space:]]*//"` and `grep -rc ""` over
`packages/transport/rpc_dart_http/lib`.

```
                          comments  total
rpc_http_caller_transport      249    677
rpc_http_responder_transport   228    631
rpc_http_server                190    370
rpc_http_cors_policy            81    228
rpc_dart_http.dart               4     11

package lib total              752   1917   39.2%
```

## Mechanism

**A sixth fused doc, and this one hid a security limit.** In
`rpc_http_caller_transport.dart`, `_readBounded`'s entire doc — the function
that enforces `maxMessageLengthBytes` on a RESPONSE — was attached to
`_readErrorBody` below it, running into that function's own description with no
declaration between them. So the bound on what a hostile server, proxy or
captive portal can make this client allocate had **no doc**, while the
error-body reader's began by describing a different function's overflow
behaviour.

**The language server confirms it independently, and that is new.** Rounds
293-300 could only offer "the analyzer still passes", which does not test a
comment at all. Here the LSP hover is a direct observable:

```
before : "```dart\nFuture<Uint8List> _readBounded(...)\n```"        <- signature only
after  : the same, followed by the docstring
```

A fused doc is therefore not merely hard to read — it is INVISIBLE to every
tool that reads docs by symbol, which is what an IDE, `dart doc` and every
symbol-based agent do.

**A milder variant, three times, and it is new to the lens: PARAGRAPH fusion.**
Two paragraphs of one doc run together with no blank `///` between them, so
they render as a single paragraph and the second subject is swallowed by the
first:

- `rpc_http_server.stop()` — "…begins from a clean slate." runs straight into
  "[drainTimeout], when given, …", so the parameter's documentation reads as a
  continuation of the idempotency argument.
- `RpcHttpCallerTransport`'s constructor — the `badCertificateCallback` warning
  runs into "[policy] bounds what a RESPONSE may cost this client".
- `_reject` — the CORS rationale runs into "The request body is DRAINED before
  answering", two unrelated reasons for the same method.

Unlike the declaration fusion this loses nothing to the compiler, but it costs
the reader the same way, and it is invisible to review for the same reason: the
text is correct line by line.

The rest followed the established rule — keep the invariant, drop the run that
proved it: the 756 MiB response measurement, the 4/8/16 MiB BytesBuilder tables
(twice, in two files), the three-transport and four-transport comparison tables,
the curl `Expect: 100-continue` timings, the content-type case table, the bound
port numbers, and five cited commit shas. A doc correcting an earlier revision
of ITSELF also went — the class doc opened "This used to say streaming methods
'will fail'", which is journal addressed to a reader who has the journal.

## After

```
                          comments  total
rpc_http_caller_transport      185    613
rpc_http_responder_transport   162    565
rpc_http_server                152    332
rpc_http_cors_policy            71    218
rpc_dart_http.dart               4     11

package lib total              574   1739   33.0%
```

**-178 comment lines**, 39.2% -> 33.0%. Zero code lines changed.

Across 300-301 the two transports lost **383 comment lines**.

## Canary

Stronger than 293-300, for the fusion half: the LSP hover for `_readBounded`
returned signature only before the fix and returns the docstring after it, on
the same query. Switch the fix off and the doc disappears from every
symbol-based reader again.

For the rest, the same honest limit as before: `fvm dart analyze lib test`
clean and 123 tests passing show the code still compiles and behaves, not that
a comment is right.

## Gate

`melos run analyze` — 21 packages plus rpc_dart_wasm, no issues.
`melos run test:unit --no-select` — 14 packages, all passed, 0 failures.
`melos run format:check` — SUCCESS, 0 changed.
`melos run license:check` — compliant, 1297/1297.
Package: `fvm dart analyze lib test` no issues; `fvm dart test -j 8` 123 passed.

## Not fixed

`rpc_http_caller_transport` and `rpc_http_responder_transport` are still at 30%
and 29%. What remains in both is genuinely load-bearing: the HTTP/1.1
header-splitting limitation, the `Expect: 100-continue` trade-off, and the
streaming-degrades-to-buffering warning are all things a caller cannot choose
correctly without.

Two packages of the mandate remain, in the owner's order: isolate, http2.

## Links

RPC-23 (`applied:` gains 301). Two additions. First, the declaration fusion has
a SIXTH instance, in a third package, and the lens can now state its real cost:
it is not a readability problem but an invisibility one, and the LSP hover
proves it. Second, PARAGRAPH fusion is a distinct sub-shape worth sweeping for
separately — three instances in one package, none of which the compiler or the
analyzer can see.
