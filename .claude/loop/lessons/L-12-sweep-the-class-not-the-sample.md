---
round: 333-334 — where it was paid for; the owner named it after 334
class: process
cost: two rounds and an owner correction. 333 measured 58 interpolating log sites in core and guarded 16; 334 guarded 24 more and reported "~20 sites remain" as ordinary remaining work. The real surface was ~200 across core and the four transports, and the owner had asked about the class, not the sample
paths: [—]
commit: 355f773c
status: active
---

# L-12 — sweep the class, not the sample

The owner asked why log strings are built when the level discards them. Round
333 counted **58 interpolating sites in core**, guarded the **16** on the unary
per-call path, measured the win and filed the rest under "Not fixed". Round 334
guarded ~24 more and filed "~20 remain". Both records were true and both were
subsets. The actual surface — every `internal`/`trace`/`debug` call across core
and the four transports — is about **200 sites**.

Two rounds of honest numbers still added up to an under-delivery, because the
scope was never stated and kept shrinking to whatever had been done.

## The rule

**Count the class before fixing any of it, and put the count in `## Target`.**
Then either fix all of it, or state the scope up front with the reason and the
number. "Remaining work" written at the END of a round is a decision the owner
never got to make.

Minimal and complete are different axes: minimal in DEPTH (one mechanism, at the
point that renders the wrong verdict), complete in BREADTH (every instance of
that mechanism). Round 333 was right to fix only the guard idiom and wrong to
fix only the unary path.

## What the count would have shown here

Taking it properly, on the tree after 334, splits the surface in a way that
changes the work:

```
core        _logger.internal(...)      non-nullable, LogScope.noop default
                                       -> the argument ALWAYS evaluates
transports  _logger?.internal(...)     nullable
                                       -> `?.` short-circuits, so with no
                                          logger attached nothing is built
```

The two halves are not the same defect, and a count taken first would have said
so before either round chose a subset.

## Applied, round 337

The full sweep: 158 sites, counted and put in `## Target` before the first edit.
The count paid for itself twice over — it showed that the two halves are not the
same defect (nullable vs not), that three transports were not in the class at
all, and that **unary is the CHEAPEST of the four call shapes by a factor of
seven**, which is the fact that made 333's and 334's "nearly done" wrong.

## The second half — a count is taken on an AXIS, and the axis can be wrong
(round 425)

Round 415 swept this rule's own subject and tabulated it: nine sites, three
columns, one row each. Round 424 read that table, took the three rows it marked
wrong, and fixed them. **Two more instances of the same rule survived, in the two
files 424 had open**, because the table had ONE "cancel unawaited" column and a
bridge has TWO cancel paths — the consumer's, which `StreamController` awaits,
and the owner's teardown. 424 fixed the owner half at two sites; `track` and
`_wrapStream` still returned the source's cancel Future from `onCancel`, and a
consumer cancelling over a parked generator hung with nothing to bound it.

A second thing the same re-derivation found: the nine "sites of one mechanic"
were six bridges and four pumps, and `_pumpBidirectionalResponses` was a seventh
bridge the sweep does not list at all.

> **Counting the class correctly still misses half of it if the class is
> tabulated on the wrong axis. Count the PATHS into a mechanism, not the sites
> that have it** — a site is where a rule lives, a path is where it is obeyed or
> broken. And before extracting from someone's sweep, re-derive its table: a
> column heading that reads the same for two rows can name two mechanisms.

Price: one round's delay and one probe, on a rule already written down twice
(L-16) and in a comment thirty lines from one of the misses.

## The axis can also be an AUDIENCE (round 435)

Second instance of the same failure, on a different class. B-30 sweeps Cyrillic
out of a repo whose rule says "English for code, comments, and logs". The lead
counted files, round 432 corrected it to lines, and 435 found that both were
counting on the wrong axis again: **the population splits by who reads it.**

    comment in test/   a maintainer who opened the file
    comment in lib/    that, plus dartdoc on the pub.dev page
    LOG in lib/        emitted at runtime into the user's own log stream

The lead deferred `lib/` for its dartdoc surface and named `rpc_data`'s 16
files. The largest single concentration in the repo is a file it never mentions
— `rpc_notify/lib/src/stream_distributor.dart`, 176 lines, of which **39 are
runtime log messages**. That third category is the only one a user cannot avoid
by not opening a file, and no count in the lead had ever separated it.

Two further ways this axis was wrong, both cheap to check and neither checked:

- The lead's detector is a grep, and it calls that grep "both the detector and
  the check". Three of the eight files it flags are FIXTURES whose Cyrillic is
  the subject under test. A text detector returns prose and data alike.
- The rule states two populations in one sentence — no emoji, and English. They
  have different distributions: the emoji are 154 lines, every one in `test/` or
  `example/`, none in `lib/` at all.

> **Before sweeping a class, ask what makes two members of it differ in VALUE,
> not just in count.** File, line and package are the axes a tool offers;
> audience, reachability and "is this a specimen or a defect" are the ones that
> decide what to fix first, and no grep will volunteer them.

## The axis can be IMPLEMENTATIONS vs BEHAVIOURS (round 462)

425 counted sites where it should have counted paths; 435 counted files where it
should have counted audiences. 462 is the same mistake at one more remove, and it
is the cheapest of the three to make, because the wrong number is the one a lead
can get by READING.

B-77 listed three implementations of "is this content-type gRPC?" and three
verdicts. Measured, four inputs per layer:

```
                          HTTP/1.1      HTTP/2        core (channel)
(absent)                  415 REFUSED   OK            OK
text/plain                415 REFUSED   status=3      status=3
```

**Two behaviours.** The layer whose file validates NOTHING inherits the shared
one, so "no copy here" read as a third verdict when it is the second one again.

The price is not wasted effort. The owner's decision was sized to the count —
*"the three implementations collapse to ONE function, and http2 starts calling
it"* — and on a surface of two that instruction makes a live check LOOSER, because
the one genuinely divergent site is the strict one. A count taken from files would
have shipped a security loosening under a refactor's name.

> **Count the class where its effects are, not where its code is.** For anything
> two-sided — a protocol, an API contract, a permission check — the countable unit
> is the OUTCOME per input, and the file is only a place to look for candidates.
> The same run that established this also found the count was SHORT by one, which
> no comparison of the three listed copies could have shown.

Price: one round, one bench with three harnesses in it. Cheaper than the two
rounds 333/334 cost, because the count came first this time — which is the rule
already working.

## Where it does NOT apply

A round that finds ONE instance of a shape and fixes it is not under-delivering
— the sweep is what tells you whether there are others. The failure is knowing
the count and fixing part of it silently.
