---
round: 735
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http2, rpc_dart_isolate, rpc_dart_websocket]
lens: RPC-24
bench: none — a surface count; every new file is traced to its barrel or shown absent from it
commit: yes
release: none
---

# Round 735 — no new file is public by omission

## Target

RPC-24, last applied in round 590. A type becomes public because a barrel
re-exports a file and nobody wrote an underscore or a `hide`. Files added to
`lib/` since the lens's last sweep are where an unchosen surface would have
appeared, `RawSocketPipe` (round 716) among them.

## Hypothesis

A file added to `lib/` since round 590 is reachable through a package's
public library without anyone having chosen it.

## Before

Every `.dart` file added under a package's `lib/` since `1ab3e26e`
(`git log --diff-filter=A`), traced to the public libraries:

```
  file                                       reaches the public API?
  rpc_dart core/sink_pump.dart               exported by core/_index; SinkPump in rpc_dart.dart's hide
  rpc_dart core/stream_bridge.dart           exported by core/_index; StreamBridge in hide
  rpc_dart contracts/caller_trailer.dart     part of the contracts library
  rpc_dart core/frame_headroom.dart          not exported
  rpc_dart transports/flow_controller.dart   imported by channel_transport only
  rpc_dart transports/stream_buffer_ledger   imported by channel_transport only
  http2 raw_socket_pipe.dart                 not in _index.dart's exports
  isolate web_bridge.dart, worker_policy     not in rpc_dart_isolate.dart
  websocket bounded_upgrade, server_policy   not in rpc_dart_websocket.dart
```

## Mechanism

No defect: each new file is either hidden explicitly or never exported.

## After

n/a.

## Canary

n/a — a surface count. The evidence is the table: every new file is named.

## The verdict questions

1. n/a.
2. n/a.
3. n/a.
4. The file list is git's, not a reading, so a missed file would show in it.
5. n/a.
6. n/a.
7. CLEAN.
8. None.
A1. n/a.
A2. n/a.
L1. n/a.

## Gate

No library change.

## Not fixed

New public classes added to files that were ALREADY exported are not counted
here. That is the lens's other half, and a larger count.

## Links

Lens `../lenses/RPC-24-public-by-omission.md` — `applied: [..., 735]`.
