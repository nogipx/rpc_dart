---
round: 882
verdict: FIXED
packages: [rpc_dart_socket]
lens: RPC-21
bench: P-337 — new
commit: yes
severity: S2 — "wrong but bounded"
release: changelog
---

# Round 882 — a live socket file taken for stale

## Target

Lead B-299, taken by the owner in a manual session (not chosen by `select`).
Owner decisions for this session: one commit per lead, full gate before it;
the owner chose the FIX DESIGN below.

`packages/transport/rpc_dart_socket/lib/src/rpc_socket_server.dart`:
`RpcSocketServer._bind` (bind fails -> `_removeStaleSocket` -> rebind) and
`RpcSocketServer._removeStaleSocket`, which takes ANY `SocketException` from a
1 s probe connect as "nobody is listening" and deletes the file. Lifecycle
lens RPC-21: a second `start()` on the path of a live server.

Pre-measured by the dispatcher on 2026-10-17, before this record (no bench
registered yet; the probes are scratch, under the package's
`.dart_tool/probe/`):

- `r882_stale_socket_live_listener.dart <full|control>` (macOS): a raw
  `ServerSocket.bind(unix, backlog: 1)` never listened to; arm `full` fills
  its queue with connects until one fails, then `RpcSocketServer.start()` on
  the same path.
  - control (queue empty): intruder refused in 12 ms, live file kept.
  - full: the fill stopped at 1 queued with `Connection refused, errno = 61`;
    intruder STARTED in 2 ms, live listener's file deleted and replaced.
- `linux/r882_full_backlog_errno.dart` (dart:io only, Docker `dart:3.10.1`,
  linux/arm64): 4096 connects queued with no error, the probe connect
  SUCCEEDED, file kept. Dart on Linux drains the accept queue even with no
  listener, so the backlog never fills there. Not reproduced on Linux.

So on macOS a full accept queue yields the same errno as a dead socket, and
no errno check can tell them apart. Also unmeasured but read in the code: the
probe's 1 s timeout throws `SocketException` too, and is treated as stale.

FIX DESIGN (owner's choice): a lock file beside the socket. The server holds
an exclusive lock on a sidecar (e.g. `<path>.lock`) for its whole lifetime;
a socket file is stale only if that lock can be taken. Dart's
`RandomAccessFile.lock` is a POSIX record lock, per PROCESS, so a second
server in the SAME process needs an in-process registry of held paths too
(the existing GUARD test `a live server keeps its path` is same-process).
`stop()` releases the lock and removes the sidecar; a crash leaves the
sidecar unlocked, so recovery (the existing crash WITNESS, which spawns a
process that exits without closing) must still work. Decide and test what
happens when the sidecar cannot be created (read-only dir).

Existing tests: `packages/transport/rpc_dart_socket/test/stale_socket_file_test.dart`
(crash witness, live-server guard, not-a-socket guard, clean-stop witness).

Open for the executor: the macOS arm used a raw listener that never
accepts. For severity, measure the same against a real, LISTENING
`RpcSocketServer` whose isolate is busy (a synchronous stall in its own
process) with the default backlog: does the queue fill and the second
`start()` take the path?

Records weighed: B-299 (the lead); round 880 filed it from reading the code.

## Hypothesis

A live `RpcSocketServer` on macOS whose accept queue is full loses its socket
path to a second `start()` on the same path; with the lock-file design the
second `start()` fails and the live server keeps its path, while a crashed
server's file is still recovered.

## Before

The open question answered: a real, LISTENING `RpcSocketServer`, default
backlog, in a child process whose isolate stalls synchronously for 6 s.

```
macOS, P-337 (r882_busy_server.dart)
  arm      queued  fill error               second start()  live server after its stall
  nofill   0       -                        refused (8 ms)  reachable
  full     128     Connection refused (61)  STARTED (3 ms)  unreachable (ENOENT)   2 of 2 runs

macOS, r882_stale_socket_live_listener.dart (raw listener, backlog 1)
  full     1       Connection refused (61)  STARTED (2 ms)  file replaced
```

Linux (Docker `dart:3.10.1`, arm64): not reproduced, the raw listener's queue
took 4096 connects with no refusal (dispatcher's measurement, in `## Target`).

Also measured for the design, `linux/r882_abstract_and_lock.dart`, both OSes
alike: `RandomAccessFile.lock(FileLock.exclusive)` on a second fd in the SAME
process is GRANTED while the first fd holds it, and closing that second fd
releases the first fd's lock (a child process is then granted it). A
`@name` Unix address is abstract on Linux (no file); on macOS it is a file
in the working directory.

Probes: `packages/transport/rpc_dart_socket/.dart_tool/probe/r882_busy_server.dart`,
`r882_stale_socket_live_listener.dart`, `linux/r882_full_backlog_errno.dart`,
`linux/r882_abstract_and_lock.dart`.

## Mechanism

`_removeStaleSocket` decided "nobody is listening" from a refused probe
connect. On macOS a full accept queue refuses connects with the same errno as
a dead socket, so a live server that is busy (a stalled isolate, a connect
burst) had its socket file deleted and its path taken by the second server.

## After

```
macOS, P-337, same arms
  arm      queued  fill error               second start()                         live server after
  nofill   0       -                        refused (6 ms) "held by a running server"  reachable
  full     128     Connection refused (61)  refused (4 ms) "held by a running server"  reachable
```

The raw-listener probe still loses its file (a listener that takes no lock;
see `## Not fixed`).

Fix, `rpc_socket_server.dart`: for a Unix path `start()` first claims it —
a per-isolate set of claimed lock paths (`_claimedPaths`, symlinks of the
directory resolved), then an exclusive non-blocking lock on `<path>.lock`
held for the server's lifetime. Lock refused -> `SocketException` "held by a
running server", nothing touched. Holding the lock, a socket file still
there is from a dead server; the old probe connect stays as a second check,
so a live server that takes no lock is still spared when it answers. A
failed start and `stop()` delete the lock file, then close it (deleting
first so the next server locks a fresh file), and drop the claim. Decided
for an uncreatable lock file (a directory in its place, a read-only dir, a
foreign user's lock): `start()` throws a `SocketException` naming the lock
file and stays stopped; a retry works once the obstacle is gone. Linux
abstract (`@`) addresses skip the lock. The class doc and the package
README described the probe connect as the test of liveness; both now
describe the lock.

## Canary

Five, each switched off in place with `Edit`, each restored and green after:

- the lock (`if (1 < 0) await lock.lock(...)`): WITNESS "a live server whose
  accept queue is full keeps its path" and WITNESS "a second server refused
  in this process leaves the first one its lock" failed with
  `Expected: contains 'refused' Actual: ['ready', 'queued 128', 'taken']`.
- the in-process claim (`_claimedPaths.add` never refuses): only the second
  WITNESS failed, same text — the in-process intruder closed its fd and so
  dropped the live server's lock. The existing GUARD "a live server keeps
  its path" stayed green: it is guarded by the probe connect, not the lock.
- the release in `stop()`: WITNESS "a clean stop removes the socket file and
  its lock" failed `Expected: false Actual: <true>`, and two
  `server_lifecycle_test.dart` restarts failed with `SocketException: ... is
  held by another server in this process`.
- the release on a failed start: GUARD "a path that is not a socket is never
  deleted" (now also retries after the obstacle goes) failed with the same
  `held by another server in this process`.
- the claim dropped on a lock-file error: GUARD "a lock file that cannot be
  created fails start" failed on its retry with the same text.

The claim set is shared by every server in the isolate, so the neighbouring
step was driven through it (`r882_start_during_stop.dart`): B starting while
A's `stop()` is in flight is refused "held by another server in this
process"; after the stop B starts; A is refused while B runs and starts after
B stops; nothing is left in the directory.

Witnesses: the two full-queue tests (sensitive on macOS only; on Linux the
queue never refuses and they pass either way) and the clean-stop test.
Guards: the rest of `stale_socket_file_test.dart`.

## Gate

- `melos run analyze`: SUCCESS, 23 packages + wasm, after the last format.
- `melos run test:unit:quiet --no-select`: first run had two red tests in
  other packages under load average ~9-13 — `rpc_dart_conformance` I-3
  socket row (a TCP member; this change touches only Unix paths) and
  `rpc_dart_http2` `graceful_drain_on_stop_test`. Each passed alone (17 and
  6 tests). Second full run: 17 packages, 0 failures (socket +34,
  conformance +621 ~158, http2 +369, rpc_dart +2265 ~1). The script itself
  reported SUCCESS over the red run: B-302.
- `melos run format:check`: 0 changed. `melos run license:check`: compliant,
  3009/3009.
- Package: `fvm dart analyze lib test` clean; `fvm dart test -j 8` +34.
- Linux, Docker `dart:3.10.1` with the repo copied in:
  `stale_socket_file_test.dart` + `server_lifecycle_test.dart`, 16 passed,
  including the lock-file obstacle as root.

## Siblings

- responder: fixed here — the only server that deletes a socket file; the
  http, http2 and websocket servers bind TCP host/port only (grep of
  `ServerSocket.bind`, `InternetAddressType.unix`, `unixDomainSock` over
  `packages/*/lib`: 1 site deletes a file, this one).
- caller: n/a — a caller binds no path and deletes nothing.

## Not fixed

- **Two isolates of one process on one path.** The claim set is per isolate
  and the lock is per process, so a second isolate is granted the lock, and
  when its start fails, closing its fd drops the first server's lock; the
  first is then protected only by the probe connect again. Measured: same
  process second fd GRANTED, close releases (both OSes). A process-wide set
  needs memory shared across isolates (FFI); the class doc now says to use
  one path per process. Risk, not cost: narrow and documented.
- **A live listener that takes no lock** (another program, an older
  rpc_dart_socket) with a full queue still loses its file: the raw-listener
  probe, after the fix, `STARTED (7 ms)`. Inherent to a lock both sides
  must take.
- **The unlink race on stop**: a starter that opened `<path>.lock` before
  `stop()` deletes it and locks it after `stop()` closes it holds a lock on
  a deleted file, while a third starter locks a fresh one. Both then bind;
  one bind fails and its probe connect spares the other unless that one's
  queue is full at that moment. Not measured. Dart exposes no inode to
  check the file after locking.
- The EACCES case of B-299 (a socket owned by another user) was read, not
  run: that user's lock file is not openable, so `start()` throws before
  any probe.
- A crash leaves `<path>.lock` behind (unlocked); the next server on the
  path reuses it and its clean stop removes it.

## Links

RPC-21 (lens), P-337 (new bench), B-299 (closed), B-302 (new: the quiet gate
reports SUCCESS over failures), L-05 (the witnesses are macOS-sensitive only),
L-15 (each arm prints `queued 128` so it is seen to reach the full queue).
