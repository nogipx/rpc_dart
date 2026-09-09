---
round: 239 — where it was paid for
class: process
cost: 19 dangling links across 11 notes, then 10 notes orphaned from the index; both found by the owner, not by the migration that caused them
paths: [—]
commit: 54b4c5ab
status: active
---

# L-09 — A delete has an inbound half, and an index that does not link is not an index

Migrating notes out of a linked store broke the graph twice, in two different
ways, and neither was visible from inside the work.

**Outbound is obvious, inbound is not.** Deleting a note takes its own links
with it, so the deletion looks clean — while every `[[link]]` POINTING AT it, in
notes nobody touched, silently becomes dangling. Seventeen deletions left **19
dangling links across 11 notes**.

**Then the index itself.** Rewriting the index turned a list of markdown links
into readable prose that named the same files. Every name was correct and every
one stopped being an edge: **10 notes went to zero inbound references**,
reachable only by already knowing the filename. Prose that names a thing is not
a link to it.

**So a delete is three steps, not one:** place the content, verify it by
grepping its own numbers, then repoint everything that pointed at the old note.
And after touching an index, count inbound edges rather than reading it — the
check is ten lines and it found both faults instantly once written, including a
fresh dangler on the very next deletion.

The repo half of this corpus has `loop.py lint`, which fails on exactly these
two shapes. The private store has nobody, which is precisely why the discipline
has to be written down instead of assumed.
