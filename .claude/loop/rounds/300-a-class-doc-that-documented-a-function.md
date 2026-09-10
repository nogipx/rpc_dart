---
round: 300
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-23
bench: none
commit: yes
---

# Round 300 — a class doc that documented a function

## Target

`rpc_dart_websocket`, the whole `lib/`, at the batch unit. 299 ended by saying
core was past the point of diminishing returns and that the next round should
start on the second package of the owner's mandate rather than grind
`responder_pipeline` and `channel_transport` a third time. The detector agreed:
the package measured **45.5% comment lines**, against the 25.9% core had been
brought to and the lens's ~20% threshold.

`websocket_caller_transport.dart` was already partly swept in the working tree
by an interrupted session; this round finished the package around it, so the
file rides in the same commit.

## Hypothesis

299 predicted the adjacency shape would keep appearing, having found it in four
consecutive core files. If it is a property of the corpus rather than of core,
it appears in a transport too — on the first package outside core that is swept
whole.

## Before

Probe: `grep -rcE "^[[:space:]]*//"` and `grep -rc ""` over
`packages/transport/rpc_dart_websocket/lib`, at HEAD.

```
                              comments  total
websocket_caller_transport         230    498
rpc_websocket_channel              147    251
rpc_websocket_server               120    365
websocket_io_connections           113    199
ws_open_io                          35     59
websocket_responder_transport       18    102
ws_open_stub                        17     31
io.dart                              9     13
rpc_dart_websocket.dart              8     15

package lib total                  697   1533   45.5%
```

`websocket_caller_transport`'s HEAD figures are computed from the working-tree
diff (`--numstat`: 166 deletions, 88 insertions, of which 2 removed and 1 added
are code); the rest are measured directly.

## Mechanism

**A fifth fused doc, and the first outside core — this one on a PUBLIC class.**
In `rpc_websocket_channel.dart` the description of `RpcWebSocketChannel`, code
sample included, ran straight into `grpcStatusFromWebSocketCloseCode`'s doc with
no declaration between them. Everything attached to the function. So the
exported class — the one the library's own `library` doc tells you to construct
— had **no doc at all**, while the function carried a `RpcChannelTransport`
sample that has nothing to do with mapping close codes.

The other adjacency shape was there too, in the same file: the close-code
narrative was written **twice**, once as the function's doc and once as an
inline block in `onDone` a hundred lines below, each with its own copy of the
same measured table (1001/1008/1009/1011 all flattening to UNAVAILABLE). The
`onDone` block then changed subject mid-run — a paragraph on which codes are
reported, followed by a second paragraph making the same point again from
scratch. The duplicate now points at the function instead of restating it.

A third instance of "the same measurement in two places" spanned files:
`ws_open_io.dart` and `websocket_caller_transport.connect` each carried the full
keepalive relay table and the 995x deflate-bomb figure. The invariant is kept in
both places (that is what a caller needs); the run that proved it is in neither.

The rest followed the established rule — keep the invariant, drop the run that
proved it: the server's start/stop/start StateError, its endpoint-leak counts
(`endpoints held 3 / contracts disposed 0`), the 383.8 MiB RSS and 20-peer
keepalive tables in `websocket_io_connections`, the 16-of-16 drain table, and
`send`'s microtask-batching measurement.

## After

```
                              comments  total
websocket_caller_transport         153    420
rpc_websocket_channel               86    190
websocket_io_connections            98    184
rpc_websocket_server                82    327
ws_open_io                          24     48
websocket_responder_transport       17    101
ws_open_stub                        15     29
io.dart                              9     13
rpc_dart_websocket.dart              8     15

package lib total                  492   1327   37.1%
```

**-205 comment lines**, 45.5% -> 37.1%. Zero code lines changed.

`websocket_io_connections` stays highest at 53%: what is left is the parameter
documentation for `rpcWebSocketConnections`, whose `allowedOrigins`,
`compression` and `allowUpgrade` semantics are exactly what a caller cannot
choose without.

## Canary

The same honest limit as 295-299: `fvm dart analyze lib test` clean and 137
tests passing show the code still compiles and behaves, not that a comment is
right.

The fused-doc half does have a checkable witness, and it is what the round
turned on: revert it and `RpcWebSocketChannel`, a class exported from
`rpc_dart_websocket.dart` and named in the library doc, has zero doc lines above
its declaration, while a `RpcChannelTransport.fromChannel` code sample sits on
an `int`-returning close-code mapper.

## Gate

`melos run analyze` — 21 packages plus rpc_dart_wasm, no issues.
`melos run test:unit --no-select` — 14 packages, all passed, 0 failures.
`melos run format:check` — SUCCESS, 0 changed.
`melos run license:check` — compliant, 1296/1296.
Package: `fvm dart analyze lib test` no issues; `fvm dart test -j 8` 137 passed.

`license:check` went red first, on an untracked `.serena/` — Serena's project
config, which is agent tooling of exactly the kind `.claude/settings.json`
already is. Annotated in `REUSE.toml` beside it, with the reason it cannot carry
an inline header: Serena rewrites `project.yml` on activation. The owner asked
for the config to be set up in the same breath, so it is configured here too.

## Not fixed

`websocket_caller_transport` is still the package's largest at 153 lines. It has
now had one pass; what remains is invariant (the stale-id set, the
disconnected-vs-closed split, the single-flight) rather than narrative.

Three packages of the mandate remain, in the owner's order: http, isolate,
http2.

## Links

RPC-23 (`applied:` gains 300). The adjacency rule now has a FIFTH instance and
its first outside core, which settles the question 299 left open: it is a
property of the corpus, not of one package. What 300 adds is that the swallowed
declaration can be a PUBLIC, exported class rather than a private member — the
doc a user reads first is the one most easily lost this way, because a class
doc and the declaration under it are separated by exactly the blank line that
hides the fusion.
