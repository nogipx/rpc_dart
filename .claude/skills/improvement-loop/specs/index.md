# Schema: a directory index

Path: `<DIR>/<DIR>.md` — the name matches the directory, one word, upper case.
Created together with the directory, immediately, even if empty.

It consists of exactly three parts, in this order:

1. **A heading** — what this directory is, in one line.
2. **A link to `../LOOP.md`** for the shared rules and links. Do not restate any
   of them: an index that explains the model will diverge from its three copies.
3. **A list of records, one line each**, all lines of one shape:

   ```
   - **[<ID>](<file>)** <status or round> — <the point in one phrase>
   ```

Plus any caveats true of this directory alone, if there are any. Shared ones do
not belong here.

**The next free number is not in the index.** It is computed as the maximum plus
one; ask `loop.py status`.

**The line order is the rank.** For the backlog and the lenses it is
meaningful — what to take first — and `loop.py next` reads it. For rounds,
negatives, benches and lessons it runs newest first.

**The files are the source of truth, not the index.** A file with no line, or a
line with no file, is a defect in the index; `lint` finds it and it is fixed in
the same round.
