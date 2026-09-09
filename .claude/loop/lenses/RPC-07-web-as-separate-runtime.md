---
refines: U-03
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: the web is a real build target (dart2js)
breaks: "wrong result: the web suite silently fails to compile a whole file, and a green run proves nothing. After that, anything, up to a crash on a target nobody ran."
applied: []
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
