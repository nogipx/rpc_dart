---
round: 289
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-04
bench: none
commit: yes
---

# Round 289 — what the core actually exports

## Target

The owner's refactor mandate, first package: `rpc_dart`. Doc comments,
boundaries, API. Boundaries first, because they decide which doc comments are
even worth writing — documenting a type that should not be public is work spent
in the wrong place.

## Hypothesis

`lib/rpc_dart.dart` is three lines: `dart:typed_data`, `logger.dart`,
`src/_index.dart`. `src/_index.dart` re-exports every subdirectory wholesale. So
the public surface is not designed, it is whatever happens to be declared
without an underscore.

## Before

Public top-level types reachable from `package:rpc_dart/rpc_dart.dart`:

```
total                                    152
```

Grouped by whether a user of the library can act on them:

```
pipeline / endpoint machinery             ~15   RpcResponderStreamState,
                                                RpcResponderStreamStore,
                                                RpcResponderMethodRegistry,
                                                RpcResponderMethodBinding,
                                                StreamProcessor, CallProcessor,
                                                RpcCallerPipelineMixin,
                                                RpcResponderPipelineMixin,
                                                RpcResponderPingHandler,
                                                RpcEndpointPingProtocol,
                                                RpcEndpointPingExchange,
                                                RpcEndpointPingResult,
                                                BufferedBroadcastController,
                                                RpcMessageParser,
                                                RpcMessageHeader, RpcLongTimer

logging                                   ~18   LogScope, LogController,
                                                LogConfig, LogFilter, LogOutput,
                                                LogRecord, LogSpan, LogSpanStart,
                                                LogSpanHandle, LogEvent,
                                                LogRedactor, SamplingConfig,
                                                SamplingState, RpcLogLevel,
                                                ConsoleFormat, ConsoleOutput,
                                                RingBufferOutput, SpanStatus
                                                + 3 span typedefs

the whole of dart:typed_data             re-exported by line 8
```

Two of those are the finding.

**`BufferedBroadcastController` and `RpcResponderStreamState` are public**, and
this loop used both from probes — which is how the leak was noticed. They are
the responder pipeline's internals; a user has nothing to do with either, and
every one of their methods is a way to corrupt a live connection.

**The logger is exported twice over.** There is a whole `rpc_dart_log` package,
and core still puts eighteen logging types plus three typedefs on its own
surface via `logger.dart`. An application configuring logging has two doors and
no statement about which is the one.

## Mechanism

`export 'src/_index.dart'` is a wholesale re-export of nine subdirectory
barrels, each of which is itself wholesale. Nothing in that chain expresses
intent, so "public" means "somebody forgot an underscore".

## After

n/a — this round measured and planned; it changed no code.

## Canary

n/a.

## Gate

n/a — no code changed. `loop.py lint` green.

## Not fixed

Everything. The plan below is in the order it has to happen, and none of it is
started in this round, because each step breaks downstream packages until its
follow-up lands and a half-applied boundary is worse than none.

1. **Machinery out of the barrel** — scoped after this round, by measuring who
   actually uses each type outside core's `lib/`:

   ```
   used by another package   RpcMessageParser (rpc_http2 caller + responder,
                             which do their own gRPC framing)
                             BufferedBroadcastController (all four transports)
   used by core's TESTS only 13 files, incl. RpcResponderStreamState,
                             RpcResponderStreamStore, the two pipeline mixins,
                             RpcResponderPingHandler, RpcEndpointPing*,
                             StreamProcessor, CallProcessor, RpcLongTimer,
                             RpcResponderMethodRegistry/Binding
   ```

   So `RpcMessageParser` and `BufferedBroadcastController` are not machinery at
   all — they are the transport-authoring API, and they STAY. The rest is
   hideable from `lib/rpc_dart.dart` with `hide`, and the ~13 test files move to
   importing `package:rpc_dart/src/_index.dart` in the same commit.

   Not executed here: it is one atomic edit across fourteen files, and half of
   it leaves the tree red.
2. **One logging door — DECIDED: core owns logging** (owner, in the session
   after this round). So the ~18 logging types stay on core's surface and
   `rpc_dart_log` is the one that has to justify what it adds; nothing to remove
   here, and the doc comments in step 4 say which door is the door.
3. **`dart:typed_data` stops being re-exported.** Every transport currently gets
   `Uint8List` from `package:rpc_dart/rpc_dart.dart` by accident. Removing it is
   one added import per affected file across five packages — mechanical, but it
   cannot be split across rounds without leaving the tree red.
4. **Then, and only then, the doc comments** for whatever survives on the
   surface.

The 152 is the number the rest of this mandate is measured against.

## Links

RPC-04 (`applied:` gains 289) — a capability reachable through a wrapper is the
same shape as a type reachable through a barrel nobody curates.
