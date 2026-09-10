<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# gRPC compatibility: the headers rpc_dart adds

rpc_dart speaks gRPC's wire format, and adds seven metadata headers of its own.
They are ordinary metadata, so a gRPC peer ignores them — but an intermediary
that **strips** unknown metadata changes behaviour without failing, and two of
these carry a protocol.

## The headers

```
x-trace-id                 correlates one call across processes
x-request-id               identifies a single request
x-route-service            routing, when a service is reached through a proxy
x-client-cancelled         the caller gave up; the responder stops work
x-cancellation-reason      why, for logs and error messages
x-rpc-window-update        flow control: per-stream credit
x-rpc-conn-window-update   flow control: connection-wide credit
```

Defined in `RpcHeaders` (`packages/core/rpc_dart/lib/src/core/rpc_headers.dart`).

## What breaks if they are stripped

**The two flow-control headers are the ones that matter.** Credit is returned to
a sender by `x-rpc-window-update` and `x-rpc-conn-window-update`. Remove them and
the sender never learns that the receiver consumed anything: it spends its
initial window and then parks, permanently. There is no error and no timeout at
the transport level — the call simply stops making progress.

The reverse case is handled: a peer that never sends any grant at all is treated
as one that predates flow control, and the sender stops metering after a grace
period rather than parking forever. That fallback keys off *never having heard*
a grant. A proxy that passes the first and drops the rest is the case it cannot
detect.

**`x-client-cancelled` stripped** means a responder keeps working on a call
nobody is waiting for, until its own deadline.

**The rest are diagnostics.** Losing them costs traceability, not correctness.

## Interop checklist

- If rpc_dart is behind a gRPC-aware proxy, allow-list `x-rpc-*` explicitly.
- A peer that is not rpc_dart never sends these, and that is fine: the grace
  period covers it.
- If throughput collapses to exactly one window's worth and stays there, suspect
  a stripped `x-rpc-conn-window-update` before suspecting the application.
