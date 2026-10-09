---
round: 767
verdict: FIXED
packages: [rpc_data]
lens: RPC-18
bench: P-267 — new
commit: yes
release: changelog
---

# Round 767 — a watcher that stops reading held every change

## Target

Round 766's class, swept: the server streams whose source is a broadcast
stream. `rpc_data`'s `BaseDataRepository.watch` (the only implementation
of `IDataRepository.watch`) forwards a broadcast change stream into a
`Stream.multi` listener, and `MultiStreamController.add` buffers while its
listener is paused. Reached remotely through `DataServiceResponder
.watchChanges`. The rest of the `.broadcast(` sites in lib were read: none
other feeds a remote response stream with peer-sized events (`grpc_health`
watch carries a status enum).

## Hypothesis

A remote watcher that stops reading makes the server hold every later
change to the collection.

## Before

P-267, 3000 updates of 64 KiB, changes added to the paused listener:

```
  rawpaused   added while paused 2934   SERVER rss +183 MiB
  paused      added while paused 0      +143 MiB   (DataServiceClient)
  reading     added while paused 0      +202 MiB
```

RSS is flat because the held changes are the journal's own objects; past
the journal's 5000 they are the watcher's alone (9000 updates: rawpaused
+445 against reading +381 MiB, noisy).

## Mechanism

Flow control worked: the response stream paused after 66 changes. The
`Stream.multi` listener buffered the rest. Fix in `watch`: while the
listener is paused, live changes go to a local queue bounded by
`maxPendingWatchEvents` (1024) and `maxPendingWatchBytes` (16 MiB,
estimated from each change's JSON); past either the watch ends with
`RESOURCE_EXHAUSTED` (`WATCH_OVERFLOW`), so the watcher resumes from the
cursor of the last change it received. Dropping instead would break the
watch's contract that every change after the cursor arrives. The backlog
replay is not counted: it is the journal's own events.

## After

`packages/data/rpc_data/test/a_watcher_that_stops_reading_is_bounded_test.dart`,
3 of 3 green: 300 x 128 KiB to a paused raw watcher ends its watch with
the overflow error; 50 changes through a 64 KiB stream window, paused and
resumed, all 51 arrive.

## Canary

```
  bound off       Expected: contains 'The watcher stopped reading'  Actual: 'null'
  drain off       Expected: <51>  Actual: <11>
  no fix at all   both fail
```

## The verdict questions

1. The arms differ in whether and how the child pauses.
2. Yes: 2934 against 0 added while paused.
3. In the server process, at the listener in `watch`.
4. n/a.
5. Yes, the two messages above.
6. Two halves (bound, drain on resume), two canaries.
7. FIXED from the counts.
8. RSS alone said "no server-side hold" and was wrong below the journal
   cap; ruled out by the counter, not by the RSS.
9. A buffered event that is also referenced elsewhere (a journal, a cache)
   costs nothing until the other holder drops it: count events, not RSS,
   or measure past the other holder's bound. Price: one round's wrong
   first reading.
A1. Separate processes, separate connections.
A2. Volume.
L1. The refusal is the watch's own (`WATCH_OVERFLOW`); with the default
    policy no transport limit is near.

## Gate

`melos run analyze`, `format:check`, `test:unit` green.

## Not fixed

- `DataServiceClient.watchChanges` bridges through a `StreamController`
  with no `onPause`, so a paused client never pauses the call: it grants
  credit and holds the backlog in its own memory. Not reachable by a peer;
  forwarding pause would expose honest slow clients to `WATCH_OVERFLOW`,
  which they do not resume from today.
- Data errors cross the wire as INTERNAL: `RpcDataError` is not an
  `RpcStatusException`, so a version conflict arrives as status 13
  (`r767_status.dart`). Next round.

## Links

Probe `../probes/P-267-what-the-data-server-holds-for-a-paused-watcher.md`.
Round `766-a-subscriber-that-stops-reading-held-the-topic.md`.
Lens `../lenses/RPC-18-dependency-buffers-below-your-limits.md`.
