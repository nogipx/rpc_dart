---
refines: U-03
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: the web is a real build target (dart2js)
breaks: "wrong result: the web suite silently fails to compile a whole file, and a green run proves nothing. After that, anything, up to a crash on a target nobody ran."
applied: [219, 227]
status: confirmed (round 090, off-journal)
---

# RPC-07 — The web as a separate runtime

## Shape

Code that is green on the VM and broken on dart2js.

## Detector

`melos run test:web`; literals above 2^53; cancelling an `async*`;
`Random.secure`; codecs available only on the VM; clock resolution.

## Ask

Which files did the web suite silently fail to compile?

## Evidence

An `int.parse` of a literal above 2^53 throws THE WHOLE FILE out of the web
suite without a single message.

Round 219 counted what the gate actually runs, which is the first thing to know
before trusting it. `melos run test:web`, exit 0, twelve suites:

    rpc_dart, rpc_dart_compression (20), rpc_dart_grpc_reflection (95)
        the WHOLE suite, on node
    opentelemetry 4, websocket 4, http 3, log 3, rpc_data 3, blob 2,
    blob_webdav 1, data_sqlite 2, blob_sqlite 2
        one hand-written smoke file each
    isolate 6
        three files, on CHROME, serialised

> **Three packages are covered; nine have a build-and-construct check.** That is
> not an oversight — the rest of those suites bind sockets, which node cannot —
> but "web is covered" is true only of core, compression and reflection.

And the census does NOT establish that the guard would catch this lens's bug
classes: nothing was ablated to see whether a planted 2^53 overflow or `async*`
cancel turns anything red. That is `../backlog/B-18-web-guard-is-a-census-not-a-sweep.md`,
and it is why this lens stays `confirmed` rather than `swept here`.
