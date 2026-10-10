---
round: 825
commit: dd400a08
paths: [packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
scope: server-stream responses refused at the caller's decode for maxDecodedItems, over the framed channel pair, with flow control on; not the responder side's request refusals, not http2
---

# C-78 — a message refused at decode returns its credit

Round 803's item budget refuses a message at decode, after the transport
has delivered it. Its bytes are credited on delivery
(`RpcFlowController.onConsumed`), before the decode, and the frames that
follow on the torn-down stream are credited too: thirty refused streams of
ten 60 KB messages leave a 256 KiB connection window whole, and an honest
1.2 MB stream passes in 9 ms. Bench
`../probes/P-306-credit-after-decode-refusals.md`.

## Control

With consumption credit removed, the honest stream alone stalls to its
deadline, so the bench sees a window that runs dry.
