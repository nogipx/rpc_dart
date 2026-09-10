---
round: 307
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-24
bench: none
commit: yes
---

# Round 307 — seventeen promises nobody made

## Target

The BOUNDARY half of the owner's mandate — "провести границы и почистить api" —
which rounds 293-306 did not touch. RPC-24 was derived on core in 289-292 and
has never been applied to a transport; round 300 spot-checked one barrel and
called it clean, which is not a sweep.

All four transport packages, by RPC-24's detector, in its stated order.

## Hypothesis

At least one transport publishes machinery it never chose to publish, by the
lens's mechanism: a barrel that re-exports a file wholesale, so every
declaration in it is public because nobody wrote an underscore.

## Before

Step 1, the surface — public top-level declarations reachable from each entry
point:

```
rpc_dart_websocket   4 classes + grpcStatusFromWebSocketCloseCode
rpc_dart_http        4 classes
rpc_dart_isolate     1 class + 1 typedef, + a THIRD-PARTY re-export
rpc_dart_http2       4 classes + 17 loose declarations   <- the finding
```

Step 2, who uses each http2 candidate, outside that package's `lib/`:

```
grep -rln <all 18 symbols of rpc_http2_common.dart> packages
  -> rpc_dart_http2/lib   (4 files)
  -> rpc_dart_http2/test  (8 files)
  -> two CHANGELOGs
  -> nothing else in the repo
```

Step 3, the prerequisite that cost core a round: does `lib/` import its own
public barrel?

```
grep -rln "package:rpc_dart_http2/rpc_dart_http2.dart" .../lib
  -> no matches
```

Clean, so narrowing here is a pure export-visibility change, not the internal
namespace deletion that produced 78 errors in round 290.

## Mechanism

`_index.dart` carried `export 'rpc_http2_common.dart';`. That file is HTTP/2
wire machinery — header conversion in four directions, `:path`/`:method`/
`:status` extraction, frame validation, the status mappers, the outgoing pump,
`disableNagle`, the user-agent constant — **18 public top-level declarations, of
which 17 nothing outside the package uses.**

Every one was a compatibility promise. `rpcMetadataToHttp2TrailersOnly` and
`http2ErrorCodeFromMessage` are not an API anyone asked for; the second exists
only because package:http2 does not expose an error code as a field, and it
parses one back out of an exception's message text. Publishing it promises that
parsing.

`RpcHttp2StreamError` is the one that stays, and it is genuinely public for a
reason the others are not: it is the ENVELOPE a stream-scoped error arrives in
on `incomingMessages`, so anyone subscribing to that stream can receive one and
needs the type to match on it.

The three siblings are clean, and checked rather than assumed:

- **http** — the barrel names four files, each holding exactly one public class.
- **websocket** — four classes plus `grpcStatusFromWebSocketCloseCode`, which is
  a deliberate public mapper mirroring core's `grpcStatusFromHttpStatus` and is
  exercised by the package's own tests through the public barrel.
- **isolate** — the conditional export plus
  `export 'package:isolate_manager/...' show isolateManagerCustomWorker;`. A
  third-party symbol on the surface is RPC-24's "does the entry point re-export
  an SDK library?" question in its general form. **Kept**, with the reason:
  writing a web worker requires that exact symbol, it is `show`-limited to one
  name rather than a wholesale re-export, and removing it would leave the web
  path undocumentable. Recorded so the next round does not re-litigate it.

## After

```
rpc_dart_http2 public top-level surface   21 -> 4
  RpcHttp2CallerTransport
  RpcHttp2ResponderTransport
  RpcHttp2Server
  RpcHttp2StreamError
```

**17 declarations removed from the public surface.** Zero behaviour change: the
code that uses them imports the file directly and always did.

## Canary

The blast radius was MEASURED by making the change and running the analyzer, not
predicted — which is the correction round 292 wrote into this lens after two
rounds guessed a cost of "one import per file across five packages" and the real
answer was zero.

Switch the fix off and the analyzer is silent. With it on:

```
30 errors, in 5 test files, 0 in lib/, 0 in any other package
```

Exactly the split step 2 predicted: machinery and tests-only, nothing user-
facing. The five tests now import
`package:rpc_dart_http2/src/transports/http2/rpc_http2_common.dart`, the route
three other tests in the same suite already used.

## Gate

`melos run analyze` — 21 packages plus rpc_dart_wasm, no issues.
`melos run test:unit --no-select` — 14 packages, all passed, 0 failures.
`melos run format:check` — SUCCESS, 0 changed.
`melos run license:check` — compliant, 1304/1304.
Package: `fvm dart analyze lib test` no issues; `fvm dart test -j 8` 199 passed.

## Not fixed

The THIRD part of the mandate — "навести порядок в самом коде и абстракциях" —
is still untouched. 293-306 changed no code; this round changed one export line
and five test imports. Nothing yet has looked for a duplicated abstraction, a
type leaking across a seam, or a boundary drawn in the wrong place.

That is not an RPC-23 or RPC-24 question and should not be forced into either.
It needs a lens of its own, derived rather than assumed.

## Links

RPC-24 (`applied:` gains 307). First application outside core, and it confirms
the shape travels: the mechanism is the wholesale file re-export, and it does not
care whether the package is 24k lines or 4.5k. What 307 adds is the sibling
comparison — three of four transports were already clean, so this is not a
corpus-wide property the way RPC-23's fusion turned out to be. **It is a property
of one barrel**, and the detector finds it in three greps.
