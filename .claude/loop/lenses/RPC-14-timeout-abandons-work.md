---
refines: U-17
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_isolate/lib/**]
applies: there are timeouts around operations that hold a resource
breaks: "unbounded growth: the held resource is never released. On this project the price is a leaked isolate rather than a socket: it holds ports and keeps the process from exiting."
applied: []
status: swept here (round 067, off-journal)
---

# RPC-14 — A timeout abandons the wait, not the work

The unaudited sites in isolate are the open lead
`../backlog/B-04-isolate-future-timeout-unaudited.md`.

## Shape

`Future.timeout` around an operation that holds a resource: the waiter is
released, the operation keeps holding.

## Detector

Grep `.timeout(` and match each hit against what the operation underneath holds.

## Ask

What lives on after the timeout fires, and who releases it?

## Evidence

The family has been swept.
