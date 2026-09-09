---
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_http2/lib/**]
scope: [http2]
---

# C-03 — PING flood (CVE-2019-9512) is not a defect

207 → 121 → 74 bytes per ping at 200k/800k/2.4M. The growing totals
(41 → 97 → 177 MiB) looked alarming until the per-unit figure showed heap
headroom rather than retention.

The theory about a queue of reply frames was disproven directly.

A flood of frames of any type allocates similarly: that is a matter for rate
limiting at the deployment level, not for the transport.

## Control

An attacker that DRAINS the socket: 96.7 -> 82.2 MiB, which disproves the
reply-frame-queue theory.
