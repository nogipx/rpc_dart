---
traits: dart, dart2js, isolates, native-plugin, public-package, two-sided-protocol, byte-limits, long-lived-process, several-replicas, screens, persistent-storage
damage classes: data loss, crash, hang, wrong result, security hole, unbounded growth, performance regression, DoS, wrong status, broken ordering, broken delivery, wedged stream, connection leak, wrong response code, data loss on restart, unbounded queue, broken convergence, lost causality, replica divergence, frame jank, lost input, wrong screen state, inaccessibility
---

# The trait registry — what a project can say about itself

> [References](REFERENCES.md) · declared by a project in `traits:`
> ([specs/config.md](../specs/config.md)) · asked for by an items file in
> `needs:` ([items/ITEMS.md](../items/ITEMS.md))

A **trait** is a property of a project, named once so that an item written for
one project can find another. It is a plain identifier and nothing else: matched
by set membership, never by meaning. `loop.py brief` prints an items file when
every trait in its `needs:` is one the project declared.

**This list exists to catch a TYPO, not to limit anybody.** A project may use
any name it likes — it declares the ones from here in `traits:` and its own in
`local traits:`, and `lint` refuses a name in the wrong one of those two. That
is the whole enforcement: `traits:` means "a name we share", `local traits:`
means "a name only this repository needs", and a name in neither is a mistake.

## Adding to this list

A trait earns a line here when an item that needs it has been paid for by a
round, and when the property is one another project could plausibly have. A
trait nobody's item asks for is reported by `lint` as buying nothing — that is
information, not an error: it marks a property whose knowledge has not been
written down yet.

A trait that is genuinely particular to one repository stays in that
repository's `local traits:` and never comes here. Promoting it is a
[curate](../methods/curate.md) decision, by the same test as everything else:
does it hold outside the code that paid for it?

## Damage classes

The `damage classes:` key above is a **vocabulary** for a lens's `breaks:` —
`loop.py catalog` prints it beside the project's own. Nothing reads it
mechanically; matching it against that free-text field would be a guess about
prose. Write them as bare nouns (`crash`, not `a crash`) so they sit inside a
sentence.

They live here, with the traits, because what a project can BREAK is a property
of what it IS.

## The list

**Language and runtime**

- `dart` — Dart code: pub packages, the analyzer, `async`/`Stream` idioms.
- `dart2js` — JavaScript is a compilation target, so numbers, clocks and
  `async*` cancellation behave differently from the VM.
- `isolates` — work runs in separate memory spaces with message passing.
- `native-plugin` — the project ships platform code (Swift, Kotlin, C) that the
  ordinary gate does not compile.

**Shape of the system**

- `two-sided-protocol` — two sides, configured independently, talking over a
  channel; someone else controls what arrives.
- `byte-limits` — there are ceilings on bytes or messages in flight, and
  something is charged and released against them.
- `long-lived-process` — a process that outlives a request: connections,
  restarts, state that accumulates.
- `several-replicas` — more than one copy of the data converges without a
  coordinator.
- `persistent-storage` — state survives the process, so a schema and a
  migration exist.

**Surface**

- `public-package` — the API is published, so a type becomes a compatibility
  promise the moment it is exported.
- `screens` — there is a UI with navigation, input and frames to miss.
