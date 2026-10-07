---
status: open
round: 682
commit: 662aa653
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart, packages/core/rpc_dart/lib/src/codec/special_cbor.dart, packages/core/rpc_dart/lib/src/core/parser.dart]
probe: .dart_tool/probe/b254_jsview.dart
reason: "unmeasured — found by reading while fixing B-254; the browser under dart2wasm is a target no suite runs"
---

# B-256 — JS-backed bytes on the web under dart2wasm

## Seen

Round 682 measured an SDK bug: on dart2wasm, `sublist` of a JS-backed
`Uint8List` VIEW at a non-zero offset counts the offset twice
(`js_typed_array.dart:893`), so it throws or returns the wrong bytes. The wasm
guest bridge now copies at the boundary.

The browser transports get their bytes from JS too. `package:web_socket`
1.0.1, `browser_web_socket.dart:79`:
`(eventData as JSArrayBuffer).toDart.asUint8List()`. Under dart2wasm that is a
JS-backed list; `RpcFrameMultiplexedChannel` hands payloads up as views into
it, and `CborCodec` reads every text string with `sublist` -- the exact path
that failed in the guest.

## Why it matters

If it holds, every websocket call from a dart2wasm web app fails with INTERNAL
on any request or response whose payload is not at offset 0 of its chunk -- all
of them, since the frame header comes first. dart2js is not affected: its
typed arrays are native.

## What a round owes this

A witness under dart2wasm in a browser or node: a websocket echo server, a
client compiled with `dart compile wasm`. Then decide the site -- a copy in
`RpcWebSocketChannel` on the web path, or the three `sublist` calls in core
(`parser.dart:282`, `special_cbor.dart:308` and `:442`) -- with the cost
measured, and ask the owner.

The browser HTTP transports (`package:http`'s `BrowserClient`, the http1
caller) are the same question.

## Owner decision

—
