---
round: 854
commit: 51ef9138
paths: [packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/caller.dart]
scope: serverStream and bidirectionalStream opened through RpcCallerEndpoint over a channel transport and left unlistened for 200 ms; not a caller built on BidirectionalStreamCaller directly
---

# C-88 — a streaming call sends nothing before its first listen

A code-reading sweep said the bidi caller buffers responses without limit
before the application subscribes (`BidirectionalStreamCaller` announces
the call in its constructor). Through the endpoint that window does not
exist: the call is built on the first listen (`StreamBridge`,
`subscribeOnFirstListen`), so a server has no stream to push into.

```
probe r854_unlistened_streams.dart   frames sent before listen   after listen
server stream                        0                           3
bidi                                 0                           2
```

## Control

The after-listen column: the same probe counts the call's frames once it
starts.
