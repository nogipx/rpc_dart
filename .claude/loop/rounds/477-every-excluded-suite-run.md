---
round: 477
verdict: FIXED
packages: [rpc_blob_minio]
lens: RPC-11
bench: none — the instrument is each excluded suite's own exit status, and this round ran all of them
commit: yes
---

# Round 477 — every excluded suite, run

## Target

B-92's remaining four members. Round 471 declared them unreachable:

> Docker IS running here, and the minio test file documents its own command. The
> registry is what refuses … So the blocker is registry credentials.

That is wrong, and it was wrong for a reason worth writing down: **I asked for a
PULL of an image that was already on disk.**

```
docker images | grep -iE "postgres|redis|minio"
  postgres:16-alpine
  redis:7-alpine
  minio/minio:latest
  quay.io/minio/minio:RELEASE.2024-12-18T13-15-44Z
```

`docker run quay.io/minio/minio` with no tag means `:latest`, which is not the
cached tag, so it went to the registry and was refused. `docker pull minio/minio`
goes to the registry unconditionally. Neither told me anything about whether the
image was available — and one `docker images` would have.

## Hypothesis

If the images are local, all four suites can run, and B-92's class can be counted
to the end rather than left at two of six.

## Before

Three services started from the CACHED images:

```
minio     -p 9010:9000   minio/minio:latest server /data
postgres  -p 5455:5432   postgres:16-alpine     (RPC_PG_URL)
postgres  -p 5433:5432   postgres:16-alpine     (notify, hardcoded port+password)
redis     -p 6379:6379   redis:7-alpine
```

**Port 5434 was already taken by a Postgres.app**, and the adapter tests default
there — so the first run failed 20 of 20 on `Postgres.app rejected "trust"
authentication`, which reads exactly like a broken container and is not. The env
override `RPC_PG_URL` exists for this; the notify suite has no override and its
port and password are hardcoded, so it needed a second instance.

Results:

```
rpc_blob_minio        +22 -1   ->  +23
rpc_data_postgres     +20          clean
rpc_notify_postgres    +9          clean
rpc_notify_redis      +13          clean
```

## The defect

One, and it is the same class the whole lead is about:

```
s3_prefix_layout_test: an explicit expectedVersion still reads, even when immutable
  Expected: throws <Instance of 'StateError'>
   Which: threw RpcStatusException(10): Version mismatch for a: expected 99, actual 1.
```

Round 416, again. ABORTED rather than `StateError`, for that round's own reason:
`wireStatusFor` is default-deny, so a `StateError` is redacted to INTERNAL and
the caller loses the version numbers that say what to retry with.

## Mechanism

The assertion now pins the status. One site; the other three suites carried no
stale assertion at all.

## After

```
rpc_blob_minio   +23  All tests passed!
```

## The class, counted to the end

B-92 asked how many suites the gate excludes and how many went stale. All of
them have now been run:

```
rpc_blob_sqlite      +37   2 stale assertions + 1 test bug   round 476, JOINED the gate
rpc_data_sqlite      +46   1 stale assertion                 round 476, still excluded (CI)
rpc_blob_minio       +23   1 stale assertion                 this round
rpc_data_postgres    +20   clean
rpc_notify_postgres   +9   clean
rpc_notify_redis     +13   clean
rpc_dart_generator     —   structurally unrunnable in a workspace (build_test)
```

**Four of six had no staleness at all**, which is worth as much as the two that
did: the damage was concentrated in the sqlite pair, and the reason is visible —
they are the ones whose exclusion had drifted from its stated cause, so they had
been out of every gate the longest.

## Canary

The failing suite is the canary and it was already red: `+22 -1` before, `+23`
after, same command against the same live service.

## Gate

`melos run analyze` SUCCESS, `format:check` SUCCESS, `license:check` SUCCESS,
`test:unit --no-select` SUCCESS across 15 packages.

The four service suites are NOT in `test:unit` and should not be — they need a
running service, which is what that script's name means. What changed is that
they have now been run once, and the record says with which commands.

## Not fixed

**The service suites stay out of `test:unit`**, correctly. Their exclusion has a
real, current cause, unlike the sqlite pair's.

**`rpc_dart_generator` stays unrunnable** for the `build_test` reason the root
pubspec documents — a workspace centralises `package_config.json` and
`build_test` needs a per-package one. Structural, not a service.

**The containers were started by this round and are left running.** Stopping
them is one command per name (`rpc-dart-minio`, `rpc-dart-pg`,
`rpc-dart-pg-notify`, `rpc-dart-redis`); they were all started with `--rm`, so
they leave nothing behind.

## Links

- RPC-11 — sixth round on this lens, and the one that finishes the count
- L-13 — round 471's blocker was a sentence I wrote and never re-measured. Third
  time this session a recorded blocker turned out false, and the second where the
  false one was mine
- B-92 — closed; round 476 did the sqlite half
