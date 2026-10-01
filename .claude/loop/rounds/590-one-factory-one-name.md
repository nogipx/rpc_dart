---
round: 590
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-24
bench: none — an API rename has no quantity to measure; the detector is `grep -c` for the call sites (225) and both halves are witnessed by ablation instead
budget: probes 0/5, canaries 2/5
commit: yes
release: changelog
---

# Round 590 — one factory, one name

## Target

`B-174` claim 4, the one item in the core + websocket scope that no round could take:
`RpcInMemoryTransport.pair` and `RpcChannelTransport.memoryPair` are one factory under
two public names, and picking one is a breaking rename.

**The owner decided option 2: deprecate `.pair`, keep `memoryPair`** — the name whose
class owns the implementation.

Lens RPC-24: a public surface nobody chose.

## Hypothesis

A one-line annotation. It is not: `melos run analyze` runs `--fatal-infos`, so every
internal use of a deprecated member is fatal.

## Before

```
RpcInMemoryTransport.pair   225 call sites   97 files   9 packages + docs
```

Reported to the owner before carrying it out, because the cost is ten times what the
question implied. The annotation and the migration are one change or the gate is red.

## Mechanism

`RpcInMemoryTransport` holds no implementation — `pair` forwarded to
`RpcChannelTransport.memoryPair` and always did. So the deprecation is free of
behaviour and the whole cost is the sweep.

## After

`@Deprecated` on `pair`, and 225 sites rewritten to `memoryPair` across lib, test,
example, README, docs and `.github/instructions`. The rewrite is a literal string
replacement run from a script that reports its count per file, so the diff can be
checked against the counts; the declaration itself and the CHANGELOG are excluded.

Two things the sweep turned up that a smaller change would not have:

- the class doc's own `[pair]` link is a deprecated-member use, so it is now
  `` `pair` ``
- the longer name changed line lengths in 21 files, which `format` rewrapped

## A websocket arm failed in the gate, and it is the B-224 family again

```
a_timed_out_connect_releases_its_socket   Expected a value less than <10>, Actual <20>
```

Green alone, red under the gate. It counted **every TCP descriptor this process
holds** via `lsof -p`, and `dart test` runs suites as isolates inside one process — so
the reading included every socket its neighbours had open.

Fixed by making the count its own: the black hole is RFC 5737 TEST-NET-1 and nothing
else in the repository connects there, so filtering on the address attributes the
descriptors to this test. It also made the ablation 30x faster to read — 4 s instead
of the 120 s test timeout.

## Canary

```
A. the forwarder drops its policy argument
     the policy argument still reaches the transport
       Expected: <7>
         Actual: <4096>

B. a timeout over the SHARED client, which is the pre-fix shape
     WITNESS: a connect that timed out does not keep its descriptor
       Expected: a value less than <10>
         Actual: <20>
```

A guards the deprecated forwarder, which after this sweep nothing else in the
repository calls — and a forwarder nothing calls is one a later cleanup can quietly
break while every caller who has not migrated still depends on it. That test is the
only place allowed to use the deprecated name, and it says so.

**B was first written to ablate the whole `connectTimeout` branch and the test went
red by its own 120 s timeout rather than by the assertion** — a red for the wrong
reason. Removing only the private client, keeping the timeout, is the pre-fix shape
and reads `20` in four seconds.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart +1880 ~1
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2234 / 2234, REUSE compliant
```

## Not fixed

**This commit touches 9 packages**, against the repo's one-package-per-commit
guidance. A rename sweep cannot be split without leaving the gate red in between.

**The deprecated member is not removed.** That is the next major, and the forwarder
plus its guard stay until then.

**B-174's other open item is untouched**: whether any OTHER transport aliases a sent
payload. The rule sits on `RpcTransportMessage`, which binds all of them, but only the
direct channel was ever driven.

## Links

Lead `../backlog/B-174-in-memory-payload-aliasing-and-close-asymmetry.md` — CLOSED.
Lead `../backlog/B-224-...` — closed in 589, and this round found a sixth member of its
family in `rpc_dart_websocket`.
Lens `../lenses/RPC-24-public-by-omission.md` — `applied: [590]`.
