---
refines: U-23
paths: [packages/core/rpc_dart/lib/**, packages/transport/*/lib/**]
applies: a package's public surface comes from a barrel that re-exports wholesale
breaks: "wrong result: a type nobody meant to publish becomes a compatibility promise, and the implementation starts depending on its own public API."
applied: [289, 290, 291, 292, 307]
status: confirmed (round 291)
---

# RPC-24 — Public by omission

## Shape

The public surface is not chosen. A barrel re-exports subdirectory barrels,
each of which re-exports everything declared in it, so a type is public because
nobody wrote an underscore. Machinery, half-finished helpers and whole SDK
libraries arrive on the surface together with the API.

## Detector

Three counts, in this order, because each answers whether the next is worth
doing:

1. **The surface.** Public top-level types reachable from the package's entry
   point. `grep -rhoE "^(abstract |final |base |sealed |mixin )*(class|mixin|enum|extension|typedef) [A-Z]"` over `lib/`.
2. **Who uses each candidate** — outside this package's `lib/`. Not "does it
   look internal": grep every other package plus this one's tests. The answer
   splits the list into *machinery*, *transport-authoring API*, and *tests only*,
   and only the first is hideable.
3. **Does `lib/` import its own public barrel?** If yes, the surface cannot be
   narrowed at all until that stops — see below.

Then: does the entry point re-export an SDK library?

## Ask

If this type is hidden, whose build breaks — and is that a user, a sibling
package in this repo, or only a test?

## Evidence

**`rpc_dart`, rounds 289-292.**

    public top-level types                  152 -> 139
    lib/ files importing the public barrel   11 -> 0
    SDK libraries re-exported                 1 -> 0

Step 2 changed the plan rather than confirming it. `RpcMessageParser`,
`RpcMessageHeader` and `BufferedBroadcastController` read as internals and are
not: all four transports build on them, so they are the transport-authoring API.
Thirteen others — both processors, both pipeline mixins, the responder stream
state and store, the method registry, the ping protocol — were used by nothing
but core's own tests. Hiding them broke no dependent package: 21 analysed clean.

> **A barrel the implementation imports is load-bearing in both directions.**
> Eleven files under `lib/` imported `package:rpc_dart/rpc_dart.dart`, so `hide`
> there was not an export-visibility change but a deletion from the internal
> namespace: 78 errors, 7 of them inside `lib/`, in files the edit never
> touched. The fix is an internal barrel — everything the implementation may
> use, with no view on what is public — and it is a PREREQUISITE, not a
> cleanup. Round 290 found this by breaking the build; check it first with one
> grep.

> **Measure the blast radius before planning around it.** Rounds 289 and 291
> both wrote that removing the `dart:typed_data` re-export costs "one added
> import per affected file across five packages", and both deferred it on that
> basis. Measured in round 292: zero. Everyone using `Uint8List` already
> imported it. A round's prose about the NEXT round is prose, and rule one
> applies to it.

**`rpc_dart_http2`, round 307 — the first application outside core.**

    public top-level surface                 21 -> 4
    declarations removed                           17
    errors from the change  30, in 5 TEST files, 0 in lib/, 0 in any other package

One line — `export 'rpc_http2_common.dart';` — published 18 declarations, of
which 17 nothing outside the package used: header conversion in four directions,
frame validation, the status mappers, `disableNagle`, the outgoing pump.
`http2ErrorCodeFromMessage` parses an error code back out of an exception's
message text because package:http2 exposes no field for it; publishing it
promised that parsing.

**The shape does not care about package size** (24k lines in core, 4.5k here),
but unlike RPC-23's fusion it is NOT a corpus-wide property: the other three
transports were checked and are clean. It is a property of one barrel, and three
greps find it.

> **A third-party re-export is the same question as an SDK one.**
> `rpc_dart_isolate` has `export 'package:isolate_manager/...' show
> isolateManagerCustomWorker;`. Checked and KEPT in 307: writing a web worker
> needs that exact symbol, and it is `show`-limited to one name rather than
> wholesale. Recorded so it is not re-litigated — the test is whether the
> re-export is chosen and bounded, not whether it is foreign.

## Where the boundary reports itself

Once the tests moved to the internal barrel, the analyzer flagged their public
import as redundant in all fourteen. A test that reaches internals has no
business holding the public API too, and `unnecessary_import` says so for free.
