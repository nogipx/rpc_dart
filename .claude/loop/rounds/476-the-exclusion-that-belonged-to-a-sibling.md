---
round: 476
verdict: FIXED
packages: [rpc_blob_sqlite]
lens: RPC-11
bench: none — the instrument is the suite's own exit status, and the fix is that the gate now runs it
commit: yes
---

# Round 476 — the exclusion that belonged to a sibling

## Target

B-92's questions 2 and 3, which need no services and which round 471 left
because it could not count the whole class:

2. Is every failure staleness, or is any of them a real defect?
3. Why is `rpc_blob_sqlite` excluded at all?

## Hypothesis

If only `rpc_data_sqlite` needs the cipher build, its sibling is excluded by
association — and joining it to the gate is what stops this recurring, which is
worth more than fixing seven assertions.

## Before

```
melos exec --scope=rpc_blob_sqlite -- fvm dart test    +30 -7
```

## Question 2 — all seven are staleness, and the scary one was a cascade

Run in ISOLATION, each failure names itself:

```
sqlite_blob_storage_adapter_test   RpcStatusException(10) Expected version 1 for d1, found 2
                                   RpcStatusException(10) ... no rows deleted
blob_service_checksum_test         RpcStatusException(15) Chunk checksum mismatch at offset 0
```

All three assert `StateError`, all three get a typed status exception — round
416, exactly as in round 470's wasm case. ABORTED and DATA_LOSS are both better
than what they replaced: `wireStatusFor` is default-deny, so a `StateError` is
redacted to INTERNAL and the caller loses the version numbers.

**The `Adapter is closed` that looked like a different defect was a cascade**,
and the trap B-92 warned about. In the full suite an earlier failure left the
adapter closed; in isolation the same test reports the mismatch. **Running the
suspicious test ALONE is what separated the two**, and it cost one command.

## The one that was not staleness

One genuine test bug, latent since the file was written:

```dart
expect(() => clientWithChecksums.putBlob(...), _throwsChecksumMismatch);
await clientWithChecksums.close();
```

`expect` with a function that returns a Future does not wait for it, so the call
was still in flight when `close()` ran on the next line — and the assertion saw
`Adapter is closed`. Now `await expectLater(...)`, at both sites in that file.

It predates round 416 and has nothing to do with it. It survived because nobody
ever ran the suite.

## Question 3 — the reason belongs to the sibling

The workspace root says why the sqlite packages are special:

> `rpc_data_sqlite` needs the MultipleCiphers build to offer encrypted databases
> at all … which surfaces as `sql_cipher_integration_test` failing on
> `PRAGMA cipher`.

That is `rpc_data_sqlite`. **`rpc_blob_sqlite` has no cipher test** — its five
files are the adapter, the RPC integration, checksums, a foreign transaction and
a web smoke test, and the suite is green with no cipher build at all.

So it sat outside the gate on a requirement that was never its own, which is why
416's sweep went stale in it unseen.

## And the sibling itself, asked the same question

The owner asked mid-round: *"а data?"* — and the same premise was stale there.

```
melos exec --scope=rpc_data_sqlite -- fvm dart test    +45 -1  ->  +46 green
```

**One failure, and it is round 416 again**: `sql_cipher_key_test` asserting
`throwsStateError` on the second `applyTo`, where the library now raises
`RpcStatusException(9)` — the key was consumed by the first call, which is
FAILED_PRECONDITION. Fixed.

**And `sql_cipher_integration_test` PASSES**, asserting `cipherAvailable` is
true. So the root comment's premise — *"user_defines are read from the WORKSPACE
ROOT only, so that declaration has no effect and the hook quietly builds plain
sqlite3"* — describes a state that the `hooks: user_defines` block now at the
root has already fixed.

**It stays excluded anyway, and the reason is different from the one recorded.**
That test asserts availability with NO skip, so on a machine where the hook
cannot build sqlite3mc the gate would go red for a missing toolchain rather than
a defect. Whether to accept that is a decision about CI, not about this package,
so the comment now says so and the exclusion stands.

## Mechanism

`rpc_blob_sqlite` removed from the ignore list of `test:unit` and of
`coverage:collect`, with the reasoning in place of the line.

## After

```
rpc_blob_sqlite   +37  All tests passed!      and now IN the gate
test:unit         15 packages, was 14
```

## Canary

The failing suite is the canary, and it was already red: `+30 -7` before, `+37`
after, same command. For the exclusion half, the gate's own package list is the
observable — `rpc_blob_sqlite` appears in `melos run test:unit` output now and
did not before.

## Gate

`melos run analyze` SUCCESS, `format:check` SUCCESS, `license:check` SUCCESS,
`test:unit --no-select` SUCCESS across **15** packages — `rpc_blob_sqlite` 37,
`rpc_dart` 1688, `rpc_dart_http2` 247, `rpc_dart_websocket` 187.

## Not fixed

**B-92 stays open** for the four members that need services: `rpc_blob_minio`,
`rpc_data_postgres`, `rpc_notify_postgres`, `rpc_notify_redis`. The registry
refuses a pull here, measured in round 471.

**`rpc_data_sqlite` stays excluded, but not for the recorded reason** — its suite
is green here including the cipher test, and what keeps it out is that the test
hard-fails rather than skips where the toolchain is missing. A gate decision for
the owner; the stale assertion in it is fixed either way.

**`rpc_dart_generator` stays excluded**, for the `build_test` reason the root
pubspec documents, which is structural rather than a service.

## Links

- RPC-11 — the package outside the gate. Five rounds; this is the first that
  moved a package back INSIDE one
- L-12 — count the class before fixing it. 471 counted, this round took the two
  members it could reach and says which four it could not
- B-92 (still open), round 471 (filed it), round 416 (where the types changed)
