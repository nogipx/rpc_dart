---
refines: U-19
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**, packages/transport/rpc_dart_http/lib/**]
applies: policy fields are enforced by each transport separately
breaks: a security hole on the transport nobody picked.
applied: [205]
status: confirmed (round 119, off-journal)
---

# RPC-08 — A policy field checked on one transport

## Shape

A new `RpcSecurityPolicy` field is enforced where it was written and inert at
its neighbours.

## Detector

The matrix «policy field x transport package»; for each cell, a behavioural
probe, not a grep for a mention.

## Ask

Is the field MENTIONED or ENFORCED? Does the refusal name that very field?

## Evidence

Checking that "the field is mentioned somewhere" gave full coverage, while a
behavioural probe found a whole transport where it was inert. Round 205 then
measured the channel transports: peaks of 30/3/1 against the ceilings with a
no-ceiling control, and 20 half-open streams reclaimed to 0 in 3 s.
