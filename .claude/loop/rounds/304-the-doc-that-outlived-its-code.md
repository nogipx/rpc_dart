---
round: 304
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-23
bench: none
commit: yes
---

# Round 304 — the doc that outlived its code

## Target

`rpc_http2_responder_transport.dart`, the second batch of the http2 package
(303 took server, common and the header guard). At 1081 lines it is a batch on
its own; the caller transport is 1989 and is round 305.

## Hypothesis

303 found the language defect in the server. The responder is its sibling, from
the same author and the same period, so it carries the same thing — and the
adjacency shape besides.

## Before

```
                          comments  total      %
rpc_http2_responder_transport  349   1081   32.3
```

## Mechanism

**A doc that outlived the code it described.** The file ends with

```dart
typedef _OutgoingPump = RpcHttp2OutgoingPump;
```

carrying a 29-line doc comment — the full backpressure argument, the
websocket-vs-http2 comparison table, the `addStream` explanation — whose last
two lines read *"The backpressured writer now lives in `rpc_http2_common.dart`
as [RpcHttp2OutgoingPump]"*. The class moved to `rpc_http2_common.dart` in an
earlier round and **took its doc with it**; what stayed behind was a verbatim
copy on the alias, plus a note saying the real one is elsewhere.

So the same explanation existed twice, in two files, and the copy was attached
to a one-line typedef. This is the round-297 duplication shape with a cause the
lens had not recorded: a doc left behind by a MOVE. The alias now says only what
is true of the alias, plus the one fact neither file stated — why this transport
cannot fall back to the rpc-level window (it rides on `x-window-update` metadata
frames, which a real gRPC client reads as trailers).

**The language defect, as predicted.** Same as the server: class doc, field
docs, and the log strings — `'Ошибка в соединении HTTP/2'`, `'Освобождение
stream'`, `'Закрытие HTTP/2 серверного транспорта'` and a dozen more, all
operator-facing output. Also an `assert` whose message was Russian, which is
what a developer sees when the assertion fires. All English now.

**A comment describing a method that does not exist**: `// Удален дублирующий
метод bind() - используйте RpcHttp2Server` — "the duplicate bind() method was
removed". A note about a deletion, addressed to a reader of a diff that is years
old.

The rest followed the established rule: the 24.2 MiB upload table, the 68 KiB
connection-window cancel table, the 20-requests-0-answered pin, the grpcurl
transcript, the 404715-message runaway handler, the GOAWAY drain table.

## After

```
                          comments  total      %
rpc_http2_responder_transport  252    961   26.2
```

**-97 comment lines**, 32.3% -> 26.2%. Zero code lines changed.
Cyrillic in the file: **0**.

Package: 1626/4689 -> 1529/4569, **32.6%**, from 36.5% at the start of 303.

## Canary

The analyzer over lib plus 199 passing tests show the code still compiles and
behaves, not that a comment is right.

The duplication half has a real witness: `RpcHttp2OutgoingPump`'s doc in
`rpc_http2_common.dart` and the typedef's doc were the same text in two files.
Restore the old wording and a reader editing one has no way to know the other
exists — which is exactly how the copy survived the move.

## Gate

`melos run analyze` — 21 packages plus rpc_dart_wasm, no issues.
`melos run test:unit --no-select` — 14 packages, all passed, 0 failures.
`melos run format:check` — SUCCESS, 0 changed.
`melos run license:check` — compliant, 1301/1301.
Package: `fvm dart analyze lib test` no issues; `fvm dart test -j 8` 199 passed.

## Not fixed

`rpc_http2_caller_transport.dart` — 675 comment lines in 1989, the single
largest file in the mandate, and the last one. It holds the remaining Cyrillic
in the package. Round 305.

## Links

RPC-23 (`applied:` gains 304). The lens gains a CAUSE for its duplication shape,
which it previously recorded only as an observation: **a doc left behind when
its code moves**. The move takes the doc, the alias keeps a copy, and nothing
notices because both copies are correct. Worth sweeping for explicitly around
any `typedef`, re-export or thin wrapper — those are what a move leaves behind.
