#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
#
# SPDX-License-Identifier: MIT
"""Improvement-loop bookkeeping: .claude/loop/ is checked by a script, not by memory.

EVERY COMMAND REPORTS FACTS. The only judgement in here is the round cap, kept
because an unattended agent asked "should we continue?" always says yes.
Choosing what to work on is the agent's.

    loop.py init     lay out .claude/loop/ (refuses if it already exists)
    loop.py status   next round number, last round, leads, owner decisions,
                     lenses, benches, lessons, and whether the cap is reached
    loop.py next     the state a round chooses FROM, in no order and naming no
                     target: lenses with status, `applied:` history and what
                     each has ever produced, swept lenses whose files have
                     moved, open leads and their reasons, valid benches
    loop.py brief    the three per-round checklists — measurement, canary,
                     tests — each with this project's trait-gated items merged
                     in, and every item it held back named
    loop.py lint     data integrity per specs/: fields, links in both
                     directions, indexes, round commits, gate permissions;
                     and the skill's OWN graph — every file reachable from
                     SKILL.md, no dangling link
    loop.py stale    what has aged against the code: sweeps, negatives, leads,
                     benches and lessons, by their sha and paths; plus
                     directories no lens covers
    loop.py yield    rounds taken and rounds FIXED, per lens — so curate ranks
                     the set on evidence instead of on feel
    loop.py catalog  every defect shape, with what each applies to (lenses mode)
    loop.py review   the seven verdict questions, plus the trait-gated ones
    loop.py selftest this file's own checks, against a fixture in a temp dir
    loop.py evals    the scenarios in evals/, each one agent to act and one to
                     grade, in a throwaway repo. Costs real invocations; takes
                     an id to run just one. Never part of the gate

NOTHING HERE GUESSES AT PROSE. Every value this file reads comes from a place a
schema declares: a frontmatter key, a fenced `gate` block, a file name listed in
a constant. Where a regex appears it parses a DECLARED field by an anchored
grammar; it never searches a document for something that looks like an answer.

Standard library only. Run from the repository root, or pass --root.
lint and selftest exit code: 0 clean, 1 errors found.
"""
from __future__ import annotations

import argparse
import ast
import builtins
import contextlib
import fnmatch
import io
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

DIRS = {
    "lenses": "LENSES.md",
    "rounds": "ROUNDS.md",
    "backlog": "BACKLOG.md",
    "checked": "CHECKED.md",
    "probes": "PROBES.md",
    "lessons": "LESSONS.md",
}
VERDICTS = ("FIXED", "CLEAN", "DEFERRED", "INCONCLUSIVE", "RETRACTED")

# Each skill directory has an index named after it. SKILL.md links the indexes,
# an index lists its files, and the walk from SKILL.md must reach everything.
SKILL_DIRS = {
    "catalog": "CATALOG.md",
    "methods": "METHODS.md",
    "specs": "SPECS.md",
    "references": "REFERENCES.md",
    "evals": "EVALS.md",
    "items": "ITEMS.md",
}

# Machine fields live in frontmatter, prose in `## Section` blocks. Frontmatter
# keys and section headings are compared lower-cased.
ROUND_FRONT = ["round", "verdict", "packages", "lens", "bench", "commit"]
# Accepted on old records, required on none. A step satisfied nominally every
# time is worse than no step, and a budget reported from memory is not evidence.
ROUND_OPTIONAL = ["budget", "review"]
ROUND_SECTIONS = ["target", "hypothesis", "before", "mechanism", "after",
                  "canary", "gate", "not fixed", "links"]
LENS_FRONT = ["refines", "paths", "applies", "breaks", "applied", "status"]
LENS_SECTIONS = ["shape", "detector", "ask", "evidence"]
LENS_OPTIONAL: list[str] = []
BACKLOG_FRONT = ["status", "round", "commit", "paths", "probe", "reason"]
# Optional, opt-in: marks a lead as work a round STARTED and did not finish, so
# `next` can say so and the round can weigh it against opening a new lens. See
# specs/backlog-item.md.
BACKLOG_OPTIONAL = ["continuation"]
BACKLOG_SECTIONS = ["owner decision"]
CHECKED_FRONT = ["round", "commit", "paths", "scope"]
CHECKED_SECTIONS = ["control"]
PROBE_FRONT = ["file", "round", "commit", "paths", "status"]
PROBE_SECTIONS = ["measures", "control"]
LESSON_FRONT = ["round", "class", "cost", "paths", "commit", "status"]
LESSON_SECTIONS: list[str] = []
# A shape says WHEN it bites and WHAT it breaks. `lenses` mode reads both to
# decide whether to instantiate it; nothing else about a shape is used.
CATALOG_FRONT = ["applies", "breaks"]
SKILL_ROOT = Path(__file__).resolve().parent.parent

# The checklists a round reads, keyed by the name a pack gives its own half.
# DECLARED, not discovered: `brief` and `review` open exactly these paths and
# concatenate them WHOLE. There is no extraction step, so there is nothing for a
# heading or a fence to get wrong.
#
# The design this replaced cut the operative part out of a longer document with
# `re.search(r"```\n(.*?)```")` -- the FIRST fence in the file. One example block
# added above the questions would have made `review` print the example instead,
# and the output would still have looked like a prompt, so nothing downstream
# could have noticed. The files now hold items and nothing else, and what paid
# for each item lives in the `-why` file beside it.
BRIEF_PARTS = (
    ("measure", "methods/measurement.md"),
    ("canary", "methods/canary.md"),
    ("tests", "methods/tests.md"),
)
REVIEW_PART = ("review", "references/review.md")

ID_RE = re.compile(r"^([A-Z]+-\d+)-[^/]+\.md$")
ROUND_FILE_RE = re.compile(r"^(\d+)-[^/]+\.md$")
ROUND_H1_RE = re.compile(r"^# Round (\d+) — (.+)$")
# Fullmatch it: the field holds an ID and nothing else. Searching would take the
# first ID out of any prose someone wrote there.
ONLY_ID_RE = re.compile(r"([A-Z]+-\d+)")
# `commit:` on a lead, negative, bench or lesson holds a sha and nothing else,
# so it is fullmatch-ed: searching would take the first hex-looking run out of
# any sentence.
ONLY_SHA_RE = re.compile(r"[0-9a-f]{7,40}")
# `off-journal` — a round that happened but whose record does not exist:
# setup.md allows starting the journal partway. Such a reference is not checked
# for a file, but it must sit BELOW the journal's first round, or the marker
# could bury a record that went missing recently.
LENS_STATUS_RE = re.compile(
    r"^(derived|confirmed \(round \d+(?:, off-journal)?\)|"
    r"swept here \(round \d+, (?:[0-9a-f]{7,40}|off-journal)\)|"
    r"retracted \(round \d+(?:, off-journal)?\))")
SWEPT_RE = re.compile(r"swept here \(round (\d+), ([0-9a-f]{7,40})\)")
SWEPT_OFF_RE = re.compile(r"swept here \(round (\d+), off-journal\)")
BACKLOG_STATUS_RE = re.compile(
    r"^(open|awaiting owner|closed \(round \d+\)|"
    r"decided by owner \(round \d+\))")
PROBE_STATUS_RE = re.compile(r"^(valid|stale \([0-9a-f]{7,40}\)|broken \(round \d+\))")
LESSON_STATUS_RE = re.compile(r"^(active|promoted to skill \([^)]+\)|obsolete \(round \d+\))")
LESSON_CLASSES = ("bench", "toolchain", "fixture", "metric", "process")
BUDGET_RE = re.compile(r"probes (\d+)/(\d+), canaries (\d+)/(\d+)")
# `none` may carry a reason after an em dash; on a FIXED round it must, because
# a round with no bench cannot answer Q2 of the verdict check.
# Named groups, so adding an alternative cannot shift what `group(n)` means.
BENCH_RE = re.compile(r"^(?:none(?P<reason> — .+)?|(?P<probe>P-\d+) — (?:reused|new))$")
MD_LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
REVIEW_RE = re.compile(r"^(subagent|self|claude -p)\b")
EMPTY = {"", "—", "-", "n/a", "none"}


# ---------------------------------------------------------------- utilities

class Report:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []
        self.infos: list[str] = []

    def error(self, msg: str) -> None:
        self.errors.append(msg)

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)

    def info(self, msg: str) -> None:
        self.infos.append(msg)

    def dump(self) -> int:
        for m in self.errors:
            print(f"ERROR  {m}")
        for m in self.warnings:
            print(f"warn   {m}")
        for m in self.infos:
            print(f"info   {m}")
        print(f"lint: {len(self.errors)} errors, {len(self.warnings)} warnings")
        return 1 if self.errors else 0


def git(root: Path, *args: str) -> str | None:
    try:
        out = subprocess.run(["git", *args], cwd=root, capture_output=True,
                             text=True, check=False)
    except FileNotFoundError:
        return None
    if out.returncode != 0:
        return None
    return out.stdout


ROUND_FIELD_RE = re.compile(r"^(?:(?P<off>off-journal)\s+)?(?P<n>\d+)\b|^—")


def round_key(value: object) -> str | None:
    """The round a record belongs to, read from a DECLARED POSITION.

    Grammar, anchored at the start of the field:

        234                 a round with a file
        234 — commentary    the same, with prose after the em dash
        off-journal 77      a real round from before the journal; no file
        —                   genuinely unknown

    Anchored, so the number is where the grammar says it is or the field does
    not parse. Anything after it is free text and is never read.
    """
    m = ROUND_FIELD_RE.match(str(value).strip())
    if not m or not m.group("n"):
        return None
    return None if m.group("off") else str(int(m.group("n")))


def parse_scalar(value: str) -> str | list[str]:
    value = value.strip()
    if value.startswith("[") and value.endswith("]"):
        return [v.strip() for v in value[1:-1].split(",") if v.strip()]
    if len(value) > 1 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def parse_doc(text: str) -> dict:
    """Frontmatter plus `## Section` blocks.

    The frontmatter is a subset of YAML and nothing more: `key: scalar`,
    `key: [a, b]`, or `key:` with a `- item` list below. Nothing nested: a
    value is a string or a list of strings. Everything else is prose in
    sections, and the parser does not touch its structure (fenced blocks with
    columns of numbers).
    """
    front: dict[str, str | list[str]] = {}
    sections: dict[str, str] = {}
    lines = text.splitlines()
    i = 0
    if lines and lines[0].strip() == "---":
        i = 1
        key: str | None = None
        while i < len(lines) and lines[i].strip() != "---":
            line = lines[i]
            i += 1
            if not line.strip():
                continue
            if key is not None and line.lstrip().startswith("- "):
                cur = front.get(key)
                items = cur if isinstance(cur, list) else ([] if cur in ("", None) else [cur])
                items.append(line.lstrip()[2:].strip())
                front[key] = items
                continue
            m = re.match(r"^([^:#\-\[\]{}][^:]{0,60}):[ \t]*(.*)$", line)
            if not m:
                continue
            key = m.group(1).strip().lower()
            front[key] = parse_scalar(m.group(2)) if m.group(2).strip() else []
        i += 1
    name: str | None = None
    buf: list[str] = []
    for line in lines[i:]:
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            if name is not None:
                sections[name] = "\n".join(buf).strip()
            name = m.group(1).strip().lower()
            buf = []
            continue
        if name is not None:
            buf.append(line)
    if name is not None:
        sections[name] = "\n".join(buf).strip()
    fields = {k: (", ".join(v) if isinstance(v, list) else v) for k, v in front.items()}
    fields.update(sections)
    return {"front": front, "sections": sections, "fields": fields,
            "has_front": bool(lines) and lines[0].strip() == "---"}


def require_fields(rep: "Report", kind: str, ent: dict, front: list[str],
                   sections: list[str]) -> None:
    """Mandatory frontmatter keys and mandatory sections."""
    for name in front:
        if name not in ent["front"]:
            rep.error(f"{kind}/{ent['path'].name}: no `{name}:` key in the frontmatter")
    for name in sections:
        if name not in ent["sections"]:
            rep.error(f"{kind}/{ent['path'].name}: no `## {name.capitalize()}` section")
        elif not ent["sections"][name].strip():
            rep.error(f"{kind}/{ent['path'].name}: section `## {name.capitalize()}` is empty")


def unknown_front(rep: "Report", kind: str, ent: dict, allowed: list[str]) -> None:
    for name in ent["front"]:
        if name not in allowed:
            rep.warn(f"{kind}/{ent['path'].name}: frontmatter key `{name}:` is not in the schema "
                     f"({', '.join(allowed)}) — a typo, or a second home for a fact")


def h1(text: str) -> str:
    for line in text.splitlines():
        if line.startswith("# "):
            return line
    return ""


def entity_files(dirpath: Path, index_name: str) -> list[Path]:
    if not dirpath.is_dir():
        return []
    return sorted(p for p in dirpath.glob("*.md") if p.name != index_name)


def index_links(index_path: Path) -> dict[str, str]:
    """ID -> file name, from `**[ID](file)**` lines."""
    if not index_path.exists():
        return {}
    return dict(re.findall(r"\*\*\[([^\]]+)\]\(([^)]+)\)\*\*", index_path.read_text()))


def split_list(value: str) -> list[str]:
    if value.strip() in EMPTY:
        return []
    return [v.strip() for v in re.split(r"[,;]\s*", value) if v.strip()]


def front_list(front: dict, key: str) -> list[str]:
    """A declared key's value as a list, from the frontmatter and only there.

    Use this, not `["fields"]`: `parse_doc` merges frontmatter with `## Section`
    headings, so a `## Damage classes` section would answer for a
    `damage classes:` key and the section's prose would win.

    Handles both spellings of a value — `needs: a, b` and a `- ` block list —
    which arrive from `parse_doc` as a string and as a list.
    """
    value = front.get(key, "")
    if isinstance(value, list):
        return [v.strip() for v in value if v.strip() and v.strip() not in EMPTY]
    return split_list(value)


def round_numbers(loop: Path) -> list[int]:
    nums = []
    for p in entity_files(loop / "rounds", DIRS["rounds"]):
        m = ROUND_FILE_RE.match(p.name)
        if m:
            nums.append(int(m.group(1)))
    return sorted(nums)


def parse_config(loop: Path) -> dict:
    cfg = {"unattended": None, "gate": [], "budget": {}, "packs": [],
           "traits": [], "local_traits": [],
           "classes": [], "after_commit": [], "commit_lang": "English",
           "reply_lang": "English"}
    path = loop / "config.md"
    if not path.exists():
        return cfg
    text = path.read_text()
    m = re.search(r"^unattended:\s*(yes|no)\s*$", text, re.M | re.I)
    if m:
        cfg["unattended"] = m.group(1).lower() == "yes"
    m = re.search(r"```gate\n(.*?)```", text, re.S)
    if m:
        cfg["gate"] = [l.strip() for l in m.group(1).splitlines()
                       if l.strip() and not l.strip().startswith("#")]
    for key in ("probes", "canaries", "round cap"):
        km = re.search(rf"^{key}:\s*(\d+)\s*$", text, re.M | re.I)
        if km:
            cfg["budget"][key] = int(km.group(1))
    for key, dest in (("traits", "traits"), ("local traits", "local_traits")):
        m = re.search(rf"^{key}:[ \t]*(.*)$", text, re.M | re.I)
        if m and m.group(1).strip():
            cfg[dest] = split_list(m.group(1))
    m = re.search(r"^packs:[ \t]*(.*)$", text, re.M | re.I)
    if m and m.group(1).strip():
        cfg["packs"] = split_list(m.group(1))
    m = re.search(r"^damage classes:[ \t]*(.*)$", text, re.M | re.I)
    if m and m.group(1).strip():
        cfg["classes"] = split_list(m.group(1))
    m = re.search(r"^commit language:[ \t]*(.*)$", text, re.M | re.I)
    if m and m.group(1).strip():
        cfg["commit_lang"] = m.group(1).strip()
    m = re.search(r"^reply language:[ \t]*(.*)$", text, re.M | re.I)
    if m and m.group(1).strip():
        cfg["reply_lang"] = m.group(1).strip()
    m = re.search(r"```after-commit\n(.*?)```", text, re.S)
    if m:
        cfg["after_commit"] = [l.strip() for l in m.group(1).splitlines()
                               if l.strip() and not l.strip().startswith("#")]
    return cfg


def body(text: str) -> str:
    """A document without its frontmatter.

    The `---` fence on line 1 is a structural delimiter the schema declares, the
    same one `parse_doc` reads; stripping it is not an interpretation of the
    content. Everything after it is concatenated verbatim.
    """
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return text.rstrip("\n")
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return "\n".join(lines[i + 1:]).strip("\n")
    return text.rstrip("\n")


def registry_traits() -> list[str]:
    """The shared trait vocabulary, from the skill's own registry.

    Its only job is to catch a TYPO. A project may use any name it likes, but a
    name outside this list has to be declared as `local traits:` on purpose,
    which is the difference between "I meant a new trait" and "I mistyped one".
    """
    p = SKILL_ROOT / "references" / "traits.md"
    if not p.exists():
        return []
    return front_list(parse_doc(p.read_text())["front"], "traits")


def effective_traits(cfg: dict) -> set[str]:
    return set(cfg["traits"]) | set(cfg["local_traits"])


def item_files(loop: Path) -> list[tuple[str, Path]]:
    """(key, path) for every items file, in the skill and in the project.

    An items file is `items/<key>-<slug>.md`. The key names the checklist it
    extends and comes from the file NAME, which is the declaration. A `-why.md`
    is a story, never an item.
    """
    out: list[tuple[str, Path]] = []
    for base in (SKILL_ROOT / "items", loop / "items"):
        if not base.is_dir():
            continue
        for key in ("measure", "canary", "tests", "review"):
            for f in sorted(base.glob(f"{key}-*.md")):
                if not f.name.endswith("-why.md"):
                    out.append((key, f))
    return out


def load_items(loop: Path, cfg: dict) -> tuple[dict, list[dict]]:
    """Items the project's TRAITS admit, and the ones they do not.

    Per FILE, not per item: the file is concatenated whole, so nothing here
    parses the body. A file whose items would need different traits is SPLIT --
    `tests-dart.md` and `tests-dart2js.md` -- and both are found by the glob.

    Returns (included, skipped). `skipped` is not a detail: an item that
    silently fails to arrive is the failure mode of this whole design, so every
    caller prints it.
    """
    have = effective_traits(cfg)
    included: dict[str, list[dict]] = {k: [] for k in ("measure", "canary", "tests", "review")}
    skipped: list[dict] = []
    for key, f in item_files(loop):
        needs = front_list(parse_doc(f.read_text())["front"], "needs")
        rec = {"key": key, "path": f, "needs": needs,
               "missing": [n for n in needs if n not in have]}
        (skipped if rec["missing"] else included[key]).append(rec)
    return included, skipped


def declared_needs(loop: Path) -> set[str]:
    """Every trait any items file asks for — so lint can find one nobody defines."""
    out: set[str] = set()
    for _, f in item_files(loop):
        out |= set(front_list(parse_doc(f.read_text())["front"], "needs"))
    return out


def damage_classes(loop: Path, cfg: dict) -> list[str]:
    """A vocabulary for a lens's `breaks:`, from the trait registry.

    Nothing reads these mechanically. They are words for whoever writes a lens,
    and for the severity bar in `config.md` that decides what a round may take.
    """
    p = SKILL_ROOT / "references" / "traits.md"
    out = front_list(parse_doc(p.read_text())["front"], "damage classes") if p.exists() else []
    out += cfg["classes"]
    seen: list[str] = []
    for c in out:
        if c not in EMPTY and c not in seen:
            seen.append(c)
    return seen


def catalog_forms(loop: Path) -> list[dict]:
    """EVERY catalog shape. Nothing filters this list, and nothing should.

    Which shapes are worth instantiating is `lenses` mode's judgement, taken
    from each shape's `applies:`. The script carries no key to make it with,
    because a filter here can only subtract.
    """
    out: list[dict] = []
    for d in (SKILL_ROOT / "catalog", loop / "catalog"):
        if not d.is_dir():
            continue
        for f in sorted(d.glob("U-*.md")):
            text = f.read_text()
            m = ID_RE.match(f.name)
            out.append({"id": m.group(1) if m else f.stem,
                        "applies": str(parse_doc(text)["front"].get("applies", "")).strip(),
                        "title": h1(text)[2:], "path": f})
    return out


def allow_rules(root: Path) -> list[str]:
    rules: list[str] = []
    for name in ("settings.json", "settings.local.json"):
        p = root / ".claude" / name
        if not p.exists():
            continue
        try:
            data = json.loads(p.read_text())
        except json.JSONDecodeError:
            continue
        rules += data.get("permissions", {}).get("allow", []) or []
    return rules


def covered(cmd: str, rules: list[str]) -> bool:
    for r in rules:
        if r == "Bash":
            return True
        m = re.match(r"^Bash\((.*)\)$", r)
        if not m:
            continue
        pat = m.group(1)
        if pat.endswith(":*"):
            if cmd.startswith(pat[:-2]):
                return True
        elif pat == cmd or fnmatch.fnmatch(cmd, pat):
            return True
    return False


def glob_match(path: str, pattern: str) -> bool:
    """`**` — any nested directories; `*` — within one segment."""
    regex = re.escape(pattern)
    regex = regex.replace(r"\*\*/", "(?:.*/)?").replace(r"\*\*", ".*")
    regex = regex.replace(r"\*", "[^/]*").replace(r"\?", "[^/]")
    return re.fullmatch(regex, path) is not None


# ---------------------------------------------------------------- loading

def load(loop: Path) -> dict:
    data = {kind: {} for kind in DIRS}
    for kind, index_name in DIRS.items():
        for p in entity_files(loop / kind, index_name):
            text = p.read_text()
            if kind == "rounds":
                m = ROUND_FILE_RE.match(p.name)
                key = (round_key(m.group(1)) or p.name) if m else p.name
            else:
                m = ID_RE.match(p.name)
                key = m.group(1) if m else p.name
            doc = parse_doc(text)
            data[kind][key] = {"path": p, "text": text, "h1": h1(text),
                               "fields": doc["fields"], "front": doc["front"],
                               "sections": doc["sections"],
                               "has_front": doc["has_front"]}
    return data


# ---------------------------------------------------------------- lint

def skill_index_for(p: Path) -> Path | None:
    """The index that owns `p`, or None when nothing does (SKILL.md itself)."""
    rel = p.relative_to(SKILL_ROOT)
    parts = rel.parts
    if len(parts) == 1:
        return None                                  # SKILL.md is the root
    index = SKILL_DIRS.get(parts[0])
    if index is None:
        return None
    if rel.name == index:
        return SKILL_ROOT / "SKILL.md"
    return SKILL_ROOT / parts[0] / index


# An interpreter allowed by NAME allows every program written on the command
# line; allowed by PATH it allows one script. `-c` matches the first and not the
# second, which is the whole difference.
INTERPRETERS = ("python3", "python", "node", "dart", "perl", "ruby", "bash", "sh")


def bare_interpreters(rules: list[str], where: str, rep: "Report") -> None:
    """Reject `Bash(python3:*)` and friends: they permit `python3 -c "..."`.

    Such a rule reads like "the script may run" and means "any program may
    run", which is worse than no rule because everyone believes it. Allow the
    interpreter by PATH, never by name.
    """
    for rule in rules:
        m = re.fullmatch(r"Bash\(([^\s:)]+)\s*:\s*\*\)", rule.strip())
        if m and m.group(1) in INTERPRETERS:
            rep.error(
                f"{where}: rule `{rule}` allows ANY program on the command line "
                f"(`{m.group(1)} -c ...`), not just the script — name the script's "
                "path: Bash(python3 <path>/scripts/loop.py:*)")


def script_names(rep: "Report") -> None:
    """Names loop.py READS that nothing in loop.py BINDS.

    Python resolves a global when the line executes, so a name deleted from
    under a caller survives the diff, the import, `lint` and every command that
    does not reach that branch. It surfaces as a NameError mid-round.

    Deliberately conservative about what counts as bound: every Store name
    anywhere inside a function counts as that function's local, nested scopes
    included. That under-reports and never invents a defect, which is the trade
    a checker in a gate wants -- a false error gets the whole check muted.
    """
    src = (SKILL_ROOT / "scripts" / "loop.py").read_text()
    try:
        tree = ast.parse(src)
    except SyntaxError as exc:
        rep.error(f"skill scripts/loop.py:{exc.lineno}: does not parse ({exc.msg})")
        return

    def bound_in(node: ast.AST) -> set[str]:
        names: set[str] = set()
        for n in ast.walk(node):
            if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store):
                names.add(n.id)
            elif isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                names.add(n.name)
            elif isinstance(n, ast.arg):
                names.add(n.arg)
            elif isinstance(n, ast.ExceptHandler) and n.name:
                names.add(n.name)
            elif isinstance(n, ast.Import):
                names.update((a.asname or a.name).split(".")[0] for a in n.names)
            elif isinstance(n, ast.ImportFrom):
                names.update(a.asname or a.name for a in n.names)
            elif isinstance(n, (ast.Global, ast.Nonlocal)):
                names.update(n.names)
        return names

    module = set(dir(builtins)) | {"__file__", "__name__", "__doc__"}
    for stmt in tree.body:
        module |= bound_in(stmt)

    for fn in [n for n in ast.walk(tree)
               if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]:
        known = module | bound_in(fn)
        for n in ast.walk(fn):
            if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load) and n.id not in known:
                rep.error(f"skill scripts/loop.py:{n.lineno}: `{fn.name}` reads `{n.id}`, "
                          "which nothing in the file binds — NameError when that line runs")

    # The MIRROR of the check above, and it found one the moment it was written:
    # `resolve_script` had outlived the detector scripts deleted in September
    # 2026, and it still took a `packs` dict in a shape the traits redesign had
    # replaced. A dead function is not a crash, which is exactly why nothing
    # notices it -- and one that takes an obsolete shape is a trap for whoever
    # calls it next believing it current.
    #
    # Top-level functions only, and only at zero Load references: a method, a
    # nested helper or anything reached dynamically is out of scope. It
    # under-reports by design, because a false error here gets the whole check
    # muted.
    used: set[str] = set()
    for n in ast.walk(tree):
        if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load):
            used.add(n.id)
        elif isinstance(n, ast.Attribute):
            used.add(n.attr)
    for stmt in tree.body:
        if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)) and stmt.name not in used:
            rep.error(f"skill scripts/loop.py:{stmt.lineno}: `{stmt.name}` is defined and "
                      "never read — delete it, or it rots into a trap for whoever "
                      "calls it next believing it current")
        # Constants too, and that gap was not hypothetical: `CATALOG_FRONT` --
        # the schema for the 23 files the whole catalog is made of -- sat here
        # declared and enforced by nothing, and the function-only version of
        # this check walked straight past it.
        elif isinstance(stmt, ast.Assign):
            for t in stmt.targets:
                if (isinstance(t, ast.Name) and t.id.isupper() and len(t.id) > 2
                        and t.id not in used):
                    rep.error(f"skill scripts/loop.py:{stmt.lineno}: `{t.id}` is defined "
                              "and never read — a schema nothing enforces is worse "
                              "than no schema, because everyone believes it")


def skill_graph(rep: "Report") -> None:
    """The skill's own files form ONE connected graph, and lint says so.

    Three properties, one per defect this was written after measuring: every
    link resolves, every file is reachable from SKILL.md (`evals/` was reachable
    from nothing), and no cross-reference names a step by number (two had
    drifted onto the wrong step).
    """
    files = sorted(SKILL_ROOT.rglob("*.md"))
    root_md = SKILL_ROOT / "SKILL.md"
    if root_md.exists():
        # `allowed-tools` grants permissions exactly like permissions.allow, and
        # is the copy that travels with the skill into every repository.
        for line in root_md.read_text().splitlines():
            if line.startswith("allowed-tools:"):
                entries = [t.strip() for t in line.split(":", 1)[1].split(",")]
                bare_interpreters(entries, "SKILL.md allowed-tools", rep)
                break
    if not root_md.exists():
        rep.error("SKILL.md: missing — the skill has no root")
        return

    edges: dict[Path, set[Path]] = {}
    for p in files:
        text = p.read_text()
        out: set[Path] = set()
        for raw in MD_LINK_RE.findall(text):
            target = raw.split("#", 1)[0].strip()
            # `<DIR>/<file>` in a schema is a placeholder, not a link.
            if not target or "://" in target or "<" in target:
                continue
            try:
                resolved = (p.parent / target).resolve()
            except OSError:
                continue
            # Links into the project's own data (../../loop/...) are not the
            # skill's graph and are not checked here.
            if SKILL_ROOT not in resolved.parents:
                continue
            if not resolved.exists():
                rep.error(f"skill {p.relative_to(SKILL_ROOT)}: dangling link «{target}»")
                continue
            out.add(resolved)
        edges[p] = out

    # Every directory has an index, because that is what SKILL.md links and what
    # the reachability walk below descends through.
    #
    # NOT checked: that a leaf links BACK to its index. The journal's
    # "links run both ways" rule earns its keep because the reverse edge carries
    # information nothing else does — a lens's `applied:` would otherwise take a
    # grep over every round. A leaf naming its own directory's index carries
    # none: the path already says it. Leaves may still open with a breadcrumb,
    # and most do, but as a convenience for whoever lands there by grep, not as
    # a rule. An unenforceable convenience is not a lint error.
    absent: set[Path] = set()
    for p in files:
        index = skill_index_for(p)
        if index is None or index.exists() or index in absent:
            continue
        absent.add(index)
        rep.error(f"skill {index.relative_to(SKILL_ROOT)}: index missing")

    seen = {root_md}
    stack = [root_md]
    while stack:
        for nxt in edges.get(stack.pop(), ()):
            if nxt not in seen:
                seen.add(nxt)
                stack.append(nxt)
    for p in files:
        if p not in seen:
            rep.error(f"skill {p.relative_to(SKILL_ROOT)}: unreachable from SKILL.md")

    # Every path `brief` and `review` will concatenate exists and has content.
    # The concatenation is by DECLARED path, so its only failure mode is a file
    # renamed or emptied under it -- and that failure is silent at the point it
    # matters, because a missing pack half just makes the checklist look short.
    for key, rel in (*BRIEF_PARTS, REVIEW_PART):
        p = SKILL_ROOT / rel
        if not p.exists():
            rep.error(f"skill {rel}: declared in BRIEF_PARTS/REVIEW_PART for "
                      f"`{key}`, but the file does not exist — `loop.py "
                      f"{'review' if key == 'review' else 'brief'}` would print a gap")
        elif not p.read_text().strip():
            rep.error(f"skill {rel}: empty — the `{key}` checklist would print nothing")

    # The evaluations are the skill's source of truth for whether it works, and
    # there is no runner for them, so the least they must be is well-formed and
    # present. Anthropic's authoring guidance asks for at least three.
    evals = SKILL_ROOT / "evals" / "evals.json"
    if not evals.exists():
        rep.error("skill evals/evals.json: missing — a skill with no evaluations "
                  "has no way to show it works")
        return
    try:
        parsed = json.loads(evals.read_text())
    except json.JSONDecodeError as exc:
        rep.error(f"skill evals/evals.json: not valid JSON ({exc.msg} at line {exc.lineno})")
        return
    items = parsed if isinstance(parsed, list) else parsed.get("evals", [])
    if len(items) < 3:
        rep.error(f"skill evals/evals.json: {len(items)} scenario(s); "
                  "the authoring guidance asks for at least three")
    seen_ids: set[object] = set()
    for e in items:
        eid = e.get("id", "?")
        for key in ("id", "name", "prompt", "expected_output"):
            if not str(e.get(key, "")).strip():
                rep.error(f"skill evals/evals.json: scenario {eid} has no `{key}`")
        if eid in seen_ids:
            rep.error(f"skill evals/evals.json: duplicate scenario id {eid}")
        seen_ids.add(eid)


def lens_verdicts(data: dict) -> dict[str, list[str]]:
    """lens ID -> the verdict of every round that declared it. One home.

    `next` and `yield` both report from this, so they cannot disagree about what
    a lens has produced -- which they could while `next` printed only `applied:`
    and the counts lived one command away.

    `fullmatch`, not `search`: `lens:` holds one ID and nothing else, and lint
    enforces exactly that. Searching would have quietly taken the first ID out
    of any sentence somebody wrote in the field.
    """
    took: dict[str, list[str]] = {}
    for ent in data["rounds"].values():
        f = ent["fields"]
        m = ONLY_ID_RE.fullmatch(f.get("lens", "").strip())
        if m:
            took.setdefault(m.group(1), []).append(f.get("verdict", "").strip())
    return took


def cmd_yield(root: Path, loop: Path) -> int:
    """What each lens has produced: rounds taken, and how many ended FIXED.

    A fact, decided by nobody. Rank the set on it rather than on which shape
    feels clever.
    """
    if not loop.is_dir():
        print(f"no {loop} — data not laid out: setup mode (loop.py init)")
        return 1
    data = load(loop)
    took = lens_verdicts(data)

    rows = []
    for lid in data["lenses"]:
        vs = took.get(lid, [])
        fixed = sum(1 for v in vs if v == "FIXED")
        rows.append((fixed, len(vs), lid, data["lenses"][lid]["fields"].get("status", "")))
    rows.sort(key=lambda r: (-r[0], r[1], r[2]))

    print(f"{'lens':9} {'rounds':>6} {'FIXED':>6}   status")
    for fixed, n, lid, st in rows:
        note = "  <- never applied" if n == 0 else ""
        print(f"{lid:9} {n:>6} {fixed:>6}   {st[:38]}{note}")
    tot_f = sum(r[0] for r in rows)
    tot_n = sum(r[1] for r in rows)
    print(f"\n{len(rows)} lenses, {tot_n} applications, {tot_f} ended FIXED"
          f" ({(100*tot_f//tot_n) if tot_n else 0}%)")
    print("A lens applied repeatedly with no FIXED is a candidate for demotion,")
    print("not proof the code is clean — say which in the curate pass.")
    return 0


def journal_commit_sprawl(root: Path, loop: Path, rep: "Report") -> None:
    """Consecutive commits that touch ONLY the journal: a round committing as it goes.

    One commit per round (methods/reporting.md). Only the last few commits are
    checked; nobody can act on older ones.
    """
    rel = loop.relative_to(root) if loop.is_relative_to(root) else loop
    out = git(root, "log", "-6", "--format=%h\t%s", "--name-only")
    if out is None:
        return
    commits: list[tuple[str, str, list[str]]] = []
    sha = subject = ""
    files: list[str] = []
    for line in out.splitlines():
        if "\t" in line and not line.startswith(str(rel)):
            if sha:
                commits.append((sha, subject, files))
            sha, subject = line.split("\t", 1)
            files = []
        elif line.strip():
            files.append(line.strip())
    if sha:
        commits.append((sha, subject, files))

    def journal_only(c: tuple[str, str, list[str]]) -> bool:
        return bool(c[2]) and all(f.startswith(str(rel)) for f in c[2])

    for newer, older in zip(commits, commits[1:]):
        # ANY two journal-only commits in a row, whatever they touch. A first
        # version required them to edit the same record, on the reasoning that
        # two different rounds each committing once look the same -- and the
        # owner rejected that: consecutive journal commits are always one piece
        # of work as far as a reader is concerned, and splitting them is what
        # makes the journal unreadable. One round, one commit, no exceptions.
        #
        # An ERROR, not a warning, and that distinction was measured too: as a
        # warning it fired twice on consecutive rounds, was read both times and
        # reasoned past both times. Enforcement that depends on judgement
        # depends on the thing that already failed.
        if journal_only(newer) and journal_only(older):
            rep.error(
                f"commits {older[0]} and {newer[0]} both touch nothing outside "
                f"{rel}/ — consecutive journal commits are ALWAYS one commit: "
                "squash with `git reset --soft` and recommit, or amend if the "
                "older one is HEAD")
            return


def round_rigour(rep: "Report", pname: str, verdict: str, bench: "re.Match | None",
                 sections: dict) -> None:
    """The questions the verdict check asks, applied to the NEWEST round only.

    A round with no bench cannot answer Q2 -- *did a control show the bench can
    SEE the defect* -- so `bench: none` has to say why none was possible.

    Newest round only: a lint that opens with dozens of errors about finished
    work is a lint everybody learns to pipe away, and nobody can act on those
    anyway. On the round being written, these arrive while the answer can still
    change.

    Nothing here reads prose. "Is there a digit in this section" and "does the
    bench field carry a reason" are both facts about a declared place.
    """
    if verdict != "FIXED":
        return
    if bench is not None and not bench.group("probe") and not bench.group("reason"):
        rep.error(
            f"rounds/{pname}: FIXED with `bench: none` and no reason. A round with "
            "no bench cannot answer Q2 of the verdict check — did a control show "
            "the bench can SEE the defect. Either name the bench, or write "
            "`none — <why a bench was not possible here>` (a grep detector with an "
            "ablation, a doc-audit count, a refactor round)")
    for name in ("before", "after"):
        sec = sections.get(name, "")
        if sec and not re.search(r"\d", sec):
            rep.warn(
                f"rounds/{pname}: `## {name.capitalize()}` holds no number. A number "
                "is the usual form of evidence and the sharpest one, but it is not "
                "the only one: an ablation that kills a guard, a witness failing "
                "with a real message, a sweep that names every site can each carry "
                "a finding. What the bar demands is evidence that is CONFIRMED — "
                "something was varied and the outcome changed. A warning, because "
                "whether this record clears that bar is a judgement and the script "
                "does not make judgements")


def cmd_lint(root: Path, loop: Path) -> int:
    if not loop.is_dir():
        print(f"no {loop} — setup mode: loop.py init")
        return 1
    return lint_report(root, loop).dump()


def lint_report(root: Path, loop: Path, skill: bool = True) -> "Report":
    """Every check, as a Report the caller can read instead of print.

    `selftest` reads it: a rule whose failure nobody has ever seen is a rule
    nobody knows is wired up. With `skill=False` the skill's own graph and this
    file's AST are skipped, so a fixture journal is judged on its own data.
    """
    rep = Report()
    for name in ("LOOP.md", "config.md"):
        if not (loop / name).exists():
            rep.error(f"{name}: missing")

    data = load(loop)
    # Numeric keys only. `load` keys a round file whose name is off the schema
    # by its FILE NAME, so `min`/`max` with `key=int` meet "one.md" and raise --
    # lint would crash on the very file it is there to report.
    numbered = [k for k in data["rounds"] if k.isdigit()]
    cfg = parse_config(loop)
    if cfg["unattended"] is None:
        rep.error("config.md: no `unattended: yes|no` line")
    if not cfg["gate"]:
        rep.error("config.md: no ```gate block with the gate commands")
    for cmd in cfg["gate"]:
        if "<" in cmd or ">" in cmd:
            rep.error(f"config.md: placeholder «{cmd}» in the gate block — the gate is not set")
    for key in ("probes", "canaries", "round cap"):
        if key not in cfg["budget"]:
            rep.error(f"config.md: no `{key}: N` line under «Round budget»")
    # --- traits: three set operations, no interpretation of anything
    if cfg["packs"]:
        rep.error("config.md: `packs:` is gone — a project declares what it IS "
                  "(`traits:`), not which bundles to switch on. Replace it with "
                  "`traits:` and, for a name the skill's registry does not have, "
                  "`local traits:`. See specs/config.md")
    registry = set(registry_traits())
    have = effective_traits(cfg)
    if not have:
        rep.error("config.md: no `traits:` line — with none declared, `brief` prints "
                  "only the universal items and every domain item is held back")
    for t in cfg["traits"]:
        if registry and t not in registry:
            rep.error(f"config.md: `traits:` names «{t}», which is not in the skill's "
                      "registry (references/traits.md). If it is deliberate, move it to "
                      "`local traits:`; that line is what tells a new trait from a typo")
    for t in cfg["local_traits"]:
        if t in registry:
            rep.error(f"config.md: `local traits:` names «{t}», which the registry "
                      "already defines — use `traits:` so the name means the same "
                      "thing here as everywhere else")
    asked = declared_needs(loop)
    for t in sorted(have - asked):
        rep.info(f"trait «{t}» is declared but no items file needs it — it buys "
                 "nothing until an item asks for it")
    for name in sorted(asked - have - registry):
        rep.warn(f"an items file needs «{name}», which is in no registry and in no "
                 "config — nothing can ever satisfy it")
    # `front`, not `fields`: `parse_doc` merges frontmatter with `## Section`
    # headings, so a `## Needs` section would answer for a `needs:` key.
    for s in catalog_forms(loop):
        front = parse_doc(s["path"].read_text())["front"]
        for fld in CATALOG_FRONT:
            if fld not in front:
                rep.error(f"catalog/{s['path'].name}: no `{fld}:` key — a shape says "
                          "WHEN it bites and WHAT it breaks, and `lenses` mode reads "
                          "both to decide whether to instantiate it")
        for fld in front:
            if fld not in CATALOG_FRONT:
                rep.error(f"catalog/{s['path'].name}: `{fld}:` is not in the schema "
                          f"({', '.join(CATALOG_FRONT)}) — nothing reads it, so it "
                          "will go stale unnoticed")
        # The ID in the HEADING against the ID in the file name. Comparing the
        # name against an id parsed out of that same name can only ever agree.
        h = h1(s["path"].read_text())
        if not h.startswith(f"# {s['id']} — "):
            rep.error(f"catalog/{s['path'].name}: heading must start with "
                      f"`# {s['id']} — `, not «{h[:40]}»")

    for key, f in item_files(loop):
        front = parse_doc(f.read_text())["front"]
        if "needs" not in front:
            rep.warn(f"items/{f.name}: no `needs:` key — it will be merged into the "
                     f"`{key}` checklist of EVERY project. If that is right, say so "
                     "with `needs:` and an empty value")
        # The BODY, not the raw text: the frontmatter is stripped before the
        # file is concatenated, so a heading below it still lands in the
        # checklist while `text.lstrip()` sees only `---`.
        text = body(f.read_text())
        if text.lstrip().startswith("#") or "](" in text:
            rep.error(f"items/{f.name}: holds a heading or a link — an items file is "
                      "concatenated whole into a checklist or a prompt, so it holds "
                      "items and nothing else. Move the prose to its `-why` file")

    # --- names, headings, indexes
    for kind, index_name in DIRS.items():
        dirpath = loop / kind
        if not dirpath.is_dir():
            rep.error(f"{kind}/: directory missing")
            continue
        index_path = dirpath / index_name
        if not index_path.exists():
            rep.error(f"{kind}/{index_name}: index missing")
            links = {}
        else:
            links = index_links(index_path)
            # A journal written before the padding rule was dropped lists its
            # rounds as `[001]` while the file key normalises to `1`. Without
            # this, every old round reads as "file with no line in ROUNDS.md".
            if kind == "rounds":
                links = {(round_key(k) or k): v for k, v in links.items()}
            itext = index_path.read_text()
            if "LOOP.md" not in itext:
                rep.error(f"{kind}/{index_name}: no link to ../LOOP.md")
            if re.search(r"^Next free number", itext, re.M):
                rep.error(f"{kind}/{index_name}: keeps a «next free number» — "
                          "a second home for a fact, status computes the number")
            for line in itext.splitlines():
                if line.lstrip().startswith("|"):
                    rep.warn(f"{kind}/{index_name}: table — forbidden by index.md")
                    break
        for lid, fname in links.items():
            if not (dirpath / fname).exists():
                rep.error(f"{kind}/{index_name}: line [{lid}]({fname}) with no file")
        for key, ent in data[kind].items():
            p = ent["path"]
            fre = ROUND_FILE_RE if kind == "rounds" else ID_RE
            if not fre.match(p.name):
                rep.error(f"{kind}/{p.name}: name off schema "
                          f"({'N-slug.md' if kind == 'rounds' else 'ID-N-slug.md'})")
                continue
            if key not in links:
                rep.error(f"{kind}/{p.name}: file with no line in {index_name}")
            elif links[key] != p.name:
                rep.error(f"{kind}/{index_name}: [{key}] points at {links[key]}, the file is {p.name}")
            if not ent["has_front"]:
                rep.error(f"{kind}/{p.name}: no frontmatter — the file must start with `---`")
            for line in ent["text"].splitlines():
                if line.lstrip().startswith("|"):
                    rep.warn(f"{kind}/{p.name}: table — forbidden by the schema, numbers go in ```")
                    break
            if kind == "rounds":
                m = ROUND_H1_RE.match(ent["h1"])
                if not m:
                    rep.error(f"rounds/{p.name}: heading is not `# Round N — topic`")
                elif round_key(m.group(1)) != key:
                    rep.error(f"rounds/{p.name}: number in the heading {m.group(1)} != {key}")
                verdict = str(ent["fields"].get("verdict", "")).strip()
                if verdict not in VERDICTS:
                    rep.error(f"rounds/{p.name}: `verdict: {verdict or '—'}` is not one of {VERDICTS}")
                if round_key(ent["fields"].get("round", "")) != key:
                    rep.error(f"rounds/{p.name}: `round:` does not match the number in the file name ({key})")
            else:
                if not ent["h1"].startswith(f"# {key} — "):
                    rep.error(f"{kind}/{p.name}: heading must start with `# {key} — `")

    # --- fields and links
    lens_rounds: dict[str, set[str]] = {}
    for lid, ent in data["lenses"].items():
        f = ent["fields"]
        require_fields(rep, "lenses", ent, LENS_FRONT, LENS_SECTIONS)
        unknown_front(rep, "lenses", ent, LENS_FRONT + LENS_OPTIONAL)
        st = f.get("status", "")
        if st and not LENS_STATUS_RE.match(st):
            rep.error(f"lenses/{ent['path'].name}: status «{st}» is off the lens.md schema")
        if f.get("paths", "").strip() in EMPTY:
            rep.error(f"lenses/{ent['path'].name}: `paths:` empty — the sweep cannot be aged")
        # `breaks:` is free text and nothing checks it: matching a damage-class
        # vocabulary against it would be a guess about prose.
        first_round = min(numbered, key=int, default=None)

        def check_round(num: str, marked: bool, where: str) -> None:
            if num in data["rounds"]:
                return
            if not marked:
                rep.error(f"lenses/{ent['path'].name}: {where} refers to round {num}, no file "
                          "— either write the record or mark it «off-journal»")
            elif first_round is not None and int(num) >= int(first_round):
                rep.error(f"lenses/{ent['path'].name}: {where} marks round {num} as «off-journal», "
                          f"but the journal starts at {first_round} — that is a missing record, not history")

        applied = set()
        for tok in split_list(f.get("applied", "")):
            # `off-journal 77` is valid here, as it is in `status:`: a lens can
            # have been applied in a round that predates the journal. Read both
            # halves from the declared grammar rather than testing `round_key`
            # alone, which returns None for the off-journal form.
            m_tok = ROUND_FIELD_RE.match(tok.strip())
            if not m_tok or not m_tok.group("n"):
                rep.error(f"lenses/{ent['path'].name}: `applied:` holds a non-round: «{tok}»")
                continue
            num, marked = m_tok.group("n"), bool(m_tok.group("off"))
            if not marked:
                applied.add(num)
            check_round(num, marked, "`applied:`")
        lens_rounds[lid] = applied
        m = re.search(r"round (\d+)", st)
        if m:
            check_round(round_key(m.group(1)), "off-journal" in st, "the status")
        if st.startswith("confirmed") and f.get("evidence", "").strip() in EMPTY:
            rep.error(f"lenses/{ent['path'].name}: confirmed, but `## Evidence` is empty")

    have_git = git(root, "rev-parse", "--git-dir") is not None
    newest = max(numbered, key=int, default=None)
    for rn, ent in data["rounds"].items():
        f = ent["fields"]
        pname = ent["path"].name
        require_fields(rep, "rounds", ent, ROUND_FRONT, ROUND_SECTIONS)
        unknown_front(rep, "rounds", ent, ROUND_FRONT + ROUND_OPTIONAL)
        verdict = f.get("verdict", "").strip()
        commit = f.get("commit", "").strip().lower()
        if commit and commit not in ("yes", "no"):
            rep.error(f"rounds/{pname}: `commit:` must be `yes` or `no`, not «{f.get('commit')}»")
        if verdict == "FIXED" and commit != "yes":
            rep.error(f"rounds/{pname}: FIXED, but `commit:` is not `yes`")
        if verdict == "FIXED":
            # `## Canary` stays an ERROR, and the softening of the number rule is
            # exactly why. Switching the fix off in place and watching the
            # witness fail IS the variation that makes evidence confirmed; on a
            # round whose finding is not a quantity it is the ONLY confirmation
            # there is. Relaxing the number and the canary together would have
            # left "FIXED" meaning nothing was checked at all.
            for name in ("after", "canary", "gate"):
                if f.get(name, "").strip().lower() in EMPTY:
                    rep.error(f"rounds/{pname}: FIXED, but `## {name.capitalize()}` is empty or n/a")
        # Numbers in `## Before` have to survive rendering: a paragraph glues
        # consecutive lines into one and the columns interleave.
        before = ent["sections"].get("before", "")
        if len([l for l in before.splitlines() if l.strip()]) >= 2 and "```" not in before:
            rep.warn(f"rounds/{pname}: `## Before` is longer than a line but has no ``` — "
                     "rendering will glue the numbers into one paragraph")
        bm = BUDGET_RE.search(f.get("budget", ""))
        if f.get("budget") and not bm:
            rep.error(f"rounds/{pname}: `budget:` off the form `probes n/N, canaries n/N`")
        elif bm:
            pu, pb, cu, cb = (int(x) for x in bm.groups())
            cfg_b = cfg["budget"]
            if "probes" in cfg_b and pb != cfg_b["probes"]:
                rep.warn(f"rounds/{pname}: probe budget {pb} != {cfg_b['probes']} from config.md")
            if "canaries" in cfg_b and cb != cfg_b["canaries"]:
                rep.warn(f"rounds/{pname}: canary budget {cb} != {cfg_b['canaries']} from config.md")
            if (pu > pb or cu > cb) and verdict not in ("INCONCLUSIVE", "DEFERRED"):
                rep.error(f"rounds/{pname}: budget exceeded ({f['budget']}) with verdict {verdict}, not INCONCLUSIVE")
        sm_ = BENCH_RE.match(f.get("bench", "").strip())
        if f.get("bench") and not sm_:
            rep.error(f"rounds/{pname}: `bench:` must be `P-N — reused`, `P-N — new`, "
                      "`none` or `none — <why no bench was possible>`")
        elif sm_ and sm_.group("probe") and sm_.group("probe") not in data["probes"]:
            rep.error(f"rounds/{pname}: bench {sm_.group('probe')} not found in probes/")
        if newest is not None and rn == newest:
            round_rigour(rep, pname, verdict, sm_, ent["sections"])
        if f.get("review") and not REVIEW_RE.match(f["review"].strip()):
            rep.error(f"rounds/{pname}: `review:` must start with `subagent`, `self` or `claude -p`")
        if commit == "yes" and have_git:
            # Ask whether the round's own FILE is committed, not whether some
            # commit message mentions the number.
            #
            # Two grep versions failed here, in opposite directions. `--grep
            # "Round NNN "` -- case-sensitive, trailing space -- matched neither
            # this repo's `round 233 - ...` convention nor a body ending at the
            # number, so eight false warnings stood for ~35 rounds and trained
            # everyone to pipe the warning block away. Making it loose then
            # broke the other way within minutes: a commit whose message merely
            # DISCUSSED round 201 satisfied the check for round 201.
            #
            # The record and its round are committed together, so `git log` on
            # the file answers the actual question exactly, with nothing to
            # guess and no wording to depend on.
            found = git(root, "log", "-1", "--format=%h", "--",
                        str(ent["path"].relative_to(root)))
            if not (found or "").strip():
                rep.warn(f"rounds/{pname}: `commit: yes`, but the record itself "
                         "is not committed yet")
        # fullmatch, not search: `lens:` holds an ID and nothing else. `search`
        # would accept "RPC-15 because the migration is its own record", quietly
        # taking the first ID it met and ignoring whatever followed.
        lens_ref = f.get("lens", "").strip()
        lm = ONLY_ID_RE.fullmatch(lens_ref)
        if not lm:
            rep.error(f"rounds/{pname}: `lens:` must be exactly one ID "
                      f"like `RPC-3`, not «{lens_ref[:40]}»")
        else:
            lid = lm.group(1)
            if lid.startswith("U-"):
                rep.warn(f"rounds/{pname}: lens {lid} is a catalog shape, not instantiated into the set")
            elif lid not in data["lenses"]:
                rep.error(f"rounds/{pname}: lens {lid} not found in lenses/")
            elif rn not in lens_rounds.get(lid, set()):
                rep.error(f"lenses/{data['lenses'][lid]['path'].name}: round {rn} used this lens, "
                          f"but its `applied:` does not list it")
        # The `## Links` section is NARRATIVE, and scanning it for IDs made every
        # ID mentioned in a sentence a checked obligation -- a fact extracted
        # from prose and then enforced. What a round actually used is already
        # declared in `lens:` and `bench:`, both checked above; the section is
        # for a human following the trail. Dropped rather than promoted to a
        # frontmatter key: another key is ceremony, and this one caught nothing
        # the declared fields did not.

    for kind, front, secs, status_re in (
            ("backlog", BACKLOG_FRONT, BACKLOG_SECTIONS, BACKLOG_STATUS_RE),
            ("checked", CHECKED_FRONT, CHECKED_SECTIONS, None)):
        optional = BACKLOG_OPTIONAL if kind == "backlog" else []
        for iid, ent in data[kind].items():
            f = ent["fields"]
            pname = ent["path"].name
            require_fields(rep, kind, ent, front, secs)
            unknown_front(rep, kind, ent, front + optional)
            if kind == "backlog" and f.get("continuation", "").strip():
                if not _is_continuation(f) and f["continuation"].strip().lower() not in ("no", "false"):
                    rep.error(f"backlog/{pname}: `continuation: {f['continuation']}` "
                              "is not yes/no — it decides whether the loop takes this "
                              "before a new lens")
                if _is_continuation(f) and not f.get("status", "").startswith("open"):
                    rep.error(f"backlog/{pname}: `continuation: yes` on a lead that is "
                              f"«{f.get('status', '')}» — only an OPEN lead can be continued")
            if status_re and f.get("status") and not status_re.match(f["status"]):
                rep.error(f"{kind}/{pname}: status «{f['status']}» is off schema")
            rnd = f.get("round", "")
            rk = round_key(rnd)
            if rk and rk not in data["rounds"]:
                rep.error(f"{kind}/{pname}: `round: {rk}`, no round file")
            if not rk and "not re-measured" not in rnd and "off-journal" not in rnd:
                rep.error(f"{kind}/{pname}: `round:` needs a round number, "
                          "«off-journal N» for one that predates the journal, "
                          "or «(not re-measured)» when it is genuinely unknown")
            if not ONLY_SHA_RE.fullmatch(f.get("commit", "").strip()):
                rep.error(f"{kind}/{pname}: `commit:` must be exactly a sha — "
                          "ageing is computed from it")
            if f.get("paths", "").strip() in EMPTY:
                rep.error(f"{kind}/{pname}: `paths:` empty — ageing cannot be computed")
            if kind == "checked" and f.get("control", "").strip() in EMPTY:
                rep.error(f"checked/{pname}: a negative without a control is hope, not a negative")
            if kind == "backlog" and f.get("reason", "").strip() in EMPTY:
                rep.error(f"backlog/{pname}: `reason:` is empty")

    for pid, ent in data["probes"].items():
        f = ent["fields"]
        pname = ent["path"].name
        require_fields(rep, "probes", ent, PROBE_FRONT, PROBE_SECTIONS)
        unknown_front(rep, "probes", ent, PROBE_FRONT)
        st = f.get("status", "")
        if st and not PROBE_STATUS_RE.match(st):
            rep.error(f"probes/{pname}: status «{st}» is off the probe.md schema")
        rk = round_key(f.get("round", ""))
        if rk and rk not in data["rounds"]:
            rep.error(f"probes/{pname}: `round: {rk}`, no round file")
        if not ONLY_SHA_RE.fullmatch(f.get("commit", "").strip()):
            rep.error(f"probes/{pname}: `commit:` must be exactly a sha")
        if f.get("paths", "").strip() in EMPTY:
            rep.error(f"probes/{pname}: `paths:` empty")
        if f.get("control", "").strip() in EMPTY:
            rep.error(f"probes/{pname}: a bench without a control is not valid")
        fpath = f.get("file", "").strip()
        if fpath in EMPTY:
            rep.error(f"probes/{pname}: `file:` is empty")
        elif st.startswith("valid") and not (root / fpath).exists():
            rep.warn(f"probes/{pname}: probe file {fpath} not found on disk (probe outside git?)")

    for lid_, ent in data["lessons"].items():
        f = ent["fields"]
        pname = ent["path"].name
        require_fields(rep, "lessons", ent, LESSON_FRONT, LESSON_SECTIONS)
        unknown_front(rep, "lessons", ent, LESSON_FRONT)
        st = f.get("status", "")
        if st and not LESSON_STATUS_RE.match(st):
            rep.error(f"lessons/{pname}: status «{st}» is off the lesson.md schema")
        if f.get("class") and f["class"].strip() not in LESSON_CLASSES:
            rep.error(f"lessons/{pname}: `class:` is not one of {LESSON_CLASSES}")
        rk = round_key(f.get("round", ""))
        if not rk:
            if "off-journal" not in f.get("round", ""):
                rep.error(f"lessons/{pname}: `round:` with no number — a lesson "
                          "with no round was not paid for (use «off-journal N» "
                          "for one paid before the journal)")
        elif rk not in data["rounds"]:
            rep.error(f"lessons/{pname}: `round: {rk}`, no round file")
        if f.get("cost", "").strip() in EMPTY or not re.search(r"\d", f.get("cost", "")):
            rep.error(f"lessons/{pname}: `cost:` with no number — without a cost it is not a lesson")
        if not ONLY_SHA_RE.fullmatch(f.get("commit", "").strip()):
            rep.error(f"lessons/{pname}: `commit:` must be exactly a sha")

    # --- round numbering
    nums = round_numbers(loop)
    for a, b in zip(nums, nums[1:]):
        if b != a + 1:
            rep.warn(f"rounds/: gap in the numbering between {a} and {b}")

    # --- permissions
    rules = allow_rules(root)
    if cfg["unattended"]:
        for cmd in cfg["after_commit"]:
            if not covered(cmd, rules):
                rep.error(f"unattended: after-commit command «{cmd}» is not covered by permissions.allow")
        for cmd in cfg["gate"]:
            if not covered(cmd, rules):
                rep.error(f"unattended: gate command «{cmd}» is not covered by permissions.allow "
                          "in .claude/settings.json — it will ask for permission and kill the round")
        if not covered(f"python3 {Path(__file__).resolve()} status", rules):
            rep.warn("unattended: no rule covers `python3 .../scripts/loop.py` — "
                     "status/lint/stale/next will ask for permission")
    bare_interpreters(rules, ".claude/settings.json", rep)

    # The journal names the skill by PATH, in backticks rather than as a
    # markdown link, so `skill_graph` -- which walks links and stops at the
    # skill's own boundary -- cannot see these. They break silently the moment
    # the skill directory is renamed.
    for md in sorted(loop.rglob("*.md")):
        for raw in re.findall(r"`([^`]*skills/[^`]*)`", md.read_text()):
            ref = raw.strip().rstrip("/")
            if "<" in ref:
                continue                       # a placeholder, not a path
            target = (root / ref) if ref.startswith(".claude/") else (md.parent / ref)
            if not target.exists():
                rep.error(f"{md.relative_to(loop)}: names «{raw}», which does not "
                          "exist — a path to the skill, written as prose, that "
                          "nothing else checks")

    if skill:
        skill_graph(rep)
        script_names(rep)
        journal_commit_sprawl(root, loop, rep)
    return rep


# ---------------------------------------------------------------- selection

def changed_files(root: Path, sha: str, paths: list[str]) -> list[str] | None:
    if git(root, "cat-file", "-e", f"{sha}^{{commit}}") is None:
        return None
    specs = [f":(glob){p}" for p in paths]
    out = git(root, "diff", "--name-only", sha, "HEAD", "--", *specs)
    if out is None:
        return None
    return [l for l in out.splitlines() if l.strip()]


def _is_continuation(fields: dict) -> bool:
    """Whether a lead is unfinished work rather than blocked work.

    Opt-in and explicit. Absent means "not a continuation", so importing a
    backlog cannot silently starve the lens set.
    """
    return fields.get("continuation", "").strip().lower() in ("yes", "true")


def swept_stale(root: Path, ent: dict) -> list[str] | None:
    """For a `swept here` lens: files changed along its paths since the sweep sha."""
    m = re.match(r"swept here \(round \d+, ([0-9a-f]{7,40})\)", ent["fields"].get("status", ""))
    if not m:
        return None
    paths = split_list(ent["fields"].get("paths", ""))
    return changed_files(root, m.group(1), paths) if paths else []


def backlog_rank(loop: Path, data: dict) -> list[str]:
    """Line order in BACKLOG.md is the rank; leads with no line go last."""
    order = list(index_links(loop / "backlog" / DIRS["backlog"]).keys())
    rest = [bid for bid in data["backlog"] if bid not in order]
    return [bid for bid in order if bid in data["backlog"]] + sorted(rest)


def pending_decisions(loop: Path, data: dict) -> list[str]:
    """Leads the owner has answered and no round has carried out yet.

    The STATUS decides, not the section. `decided by owner` means answered and
    not yet carried out; `awaiting owner` means still waiting, whatever the
    section holds. A decision stays outstanding until the lead is `closed`.

    `## Owner decision` is an archive, not the signal: a lead whose decision
    turned out unbuildable keeps the old text under a "superseded" note, because
    the reasoning is still worth reading. Matching on "the section is non-empty"
    would read a retired decision as a live one.

    Ranked by BACKLOG.md, per the rule that order lives in the index.
    """
    out = []
    for bid in backlog_rank(loop, data):
        f = data["backlog"][bid]["fields"]
        if not f.get("status", "").startswith("decided by owner"):
            continue
        if f.get("owner decision", "").strip() in EMPTY:
            continue                      # decided, but nobody wrote it down
        out.append(bid)
    return out


def stop_condition(root: Path, loop: Path, data: dict, cfg: dict) -> tuple[bool, str]:
    """The ONLY thing the script decides, and only because unattended runs need
    it: an agent asked "should we continue?" always says yes.

    Everything else is a fact for the round to weigh. Facts belong here;
    choices do not.

    The cap is a round NUMBER, not a file count. Comparing it against the count
    made it unreachable for a journal that starts partway -- 30 files numbered
    201-230 would not have tripped a cap of 230 until round 430. Found at round
    230, by the cap failing to fire.
    """
    nums = round_numbers(loop)
    n = max(nums) if nums else 0
    cap = cfg["budget"].get("round cap")
    if cap is not None and n >= cap:
        return True, f"round cap reached (round {n} of {cap})"
    left = f"{cap - n} to the cap at {cap}" if cap is not None else "no cap set"
    return False, f"round {n}, {left}. What to do next is the agent's call, not this script's"

def cmd_status(root: Path, loop: Path) -> int:
    if not loop.is_dir():
        print(f"no {loop} — data not laid out: setup mode (loop.py init)")
        return 1
    data = load(loop)
    nums = round_numbers(loop)
    nxt = (nums[-1] + 1) if nums else 1
    print(f"Next round: {nxt}")
    if nums:
        last = data["rounds"][str(nums[-1])]
        verdict = last["fields"].get("verdict", "?")
        packages = last["fields"].get("packages", "")
        print(f"Last round: {last['h1'][2:]} — {verdict}"
              + (f" — {packages}" if packages else ""))
        print(f"  Not fixed: {last['fields'].get('not fixed', '—')}")
    else:
        print("Last round: none — the loop has not started")

    if not data["lenses"]:
        print("Lenses: no set — lenses mode")
    else:
        by = {"derived": [], "confirmed": [], "swept here": [], "retracted": [],
              "off schema": []}
        never = []
        for lid, ent in data["lenses"].items():
            st = ent["fields"].get("status", "")
            key = next((k for k in by if st.startswith(k)), "off schema")
            by[key].append(lid)
            if not split_list(ent["fields"].get("applied", "")):
                never.append(lid)
        print("Lenses: " + ", ".join(f"{k} {len(v)}" for k, v in by.items() if v))
        if never:
            print(f"  never applied: {', '.join(never)}")

    # One home for "which decisions are outstanding": `next` reports from this
    # same list, so status cannot disagree with it.
    outstanding = pending_decisions(loop, data)
    decisions = [f"{data['backlog'][b]['h1'][2:]}: "
                 f"{data['backlog'][b]['fields']['owner decision']}"
                 for b in outstanding]
    waiting, open_ = [], []
    for bid, ent in data["backlog"].items():
        if bid in outstanding:
            continue
        f = ent["fields"]
        st = f.get("status", "")
        title = ent["h1"][2:]
        if st.startswith("awaiting owner"):
            waiting.append(title)
        elif st.startswith("open"):
            open_.append(f"{title} — {f.get('reason', '')}")
    print(f"Owner decisions not yet carried out: {len(decisions)}"
          + (" — THE ROUND'S FIRST TARGET" if decisions else ""))
    for d in decisions:
        print(f"  {d}")
    print(f"Awaiting owner: {len(waiting)}")
    for w in waiting:
        print(f"  {w}")
    print(f"Open leads: {len(open_)}")
    for o in open_:
        print(f"  {o}")
    print(f"Negatives: {len(data['checked'])}")
    valid = [pid for pid, e in data["probes"].items() if e["fields"].get("status", "").startswith("valid")]
    print(f"Benches: {len(data['probes'])}, valid {len(valid)}"
          + (f" ({', '.join(valid)})" if valid else ""))
    active = [l for l, e in data["lessons"].items() if e["fields"].get("status", "").startswith("active")]
    print(f"Lessons: {len(data['lessons'])}, active {len(active)} — read lessons/LESSONS.md")
    cfg = parse_config(loop)
    stop, why = stop_condition(root, loop, data, cfg)
    print(f"Stop: {'YES' if stop else 'no'} — {why}")
    return 0


# ---------------------------------------------------------------- next

def cmd_next(root: Path, loop: Path) -> int:
    if not loop.is_dir():
        print(f"no {loop} — data not laid out: setup mode (loop.py init)")
        return 1
    data = load(loop)
    cfg = parse_config(loop)
    nums = round_numbers(loop)
    print(f"Round: {(nums[-1] + 1) if nums else 1}")
    if not data["lenses"]:
        print("No lens set — do lenses mode first; a round has nothing to choose from")
        return 2
    stop, why = stop_condition(root, loop, data, cfg)
    if stop:
        print(f"Stop: YES — {why}. Do not start a round; if launched from /loop, cancel the job.")
        return 2
    print("")
    print("THE SCRIPT DOES NOT CHOOSE. Below is state, not a ranking: no order")
    print("is implied and no target is named. Decide from it, and write what you")
    print("took and why into the round's `## Target`.")
    print("")

    dec = pending_decisions(loop, data)
    if dec:
        print("OWNER DECISIONS written and not yet carried out:")
        for d in dec:
            print(f"  {d} — {data['backlog'][d]['h1'][2:]}")
        print("")

    # The counts are here because the decision they inform is made here: a lens
    # applied three times for nothing and a lens never applied read identically
    # from `applied:` alone.
    took = lens_verdicts(data)
    print("LENSES — status, the rounds that applied them, and what they produced:")
    for lid in sorted(data["lenses"]):
        f = data["lenses"][lid]["fields"]
        ap = split_list(f.get("applied", ""))
        vs = took.get(lid, [])
        fixed = sum(1 for v in vs if v == "FIXED")
        print(f"  {lid:8} {f.get('status', ''):34} {len(vs)} round(s), {fixed} FIXED"
              f"   applied: {', '.join(ap) if ap else 'never'}")

    aged = []
    for lid in sorted(data["lenses"]):
        ch = swept_stale(root, data["lenses"][lid])
        if ch:
            aged.append((lid, len(ch)))
    if aged:
        print("")
        print("SWEPT LENSES WHOSE PATHS HAVE MOVED SINCE (git, not memory):")
        for lid, n in aged:
            print(f"  {lid:8} {n} file(s) changed")

    leads = [(b, e) for b, e in sorted(data["backlog"].items())
             if e["fields"].get("status", "").startswith(("open", "awaiting owner"))]
    if leads:
        print("")
        print("OPEN LEADS — reason, and whether a round left them unfinished:")
        for bid, e in leads:
            f = e["fields"]
            cont = " [continuation: unfinished, not blocked]" if _is_continuation(f) else ""
            print(f"  {bid:6} {f.get('status', '')[:14]:15} {f.get('reason', '')[:58]}{cont}")

    print("")
    print("VALID BENCHES — reuse one on the same paths rather than rebuilding:")
    for pid in sorted(data["probes"]):
        pe = data["probes"][pid]
        if pe["fields"].get("status", "").startswith("valid"):
            print(f"  {pid:6} {pe['fields'].get('paths', '')[:72]}")
    b = cfg["budget"]
    print(f"Budget (count them yourself; past either one the verdict is INCONCLUSIVE): "
          f"{b.get('probes', '?')} bench rebuilds, {b.get('canaries', '?')} canary attempts")
    included, skipped = load_items(loop, cfg)
    print("Traits: " + (", ".join(sorted(effective_traits(cfg))) or "none declared"))
    if skipped:
        print(f"Items held back for a trait this project does not declare: {len(skipped)}"
              " — `loop.py brief` names them")
    print(f"Commit language: {cfg['commit_lang']}")
    print(f"Reply language: {cfg['reply_lang']}")
    # No per-lens reading named here: the detector, the paths and the refined
    # catalog shape all live in the lens's own file, and naming one would be
    # choosing.
    active = [l for l, e in data["lessons"].items() if e["fields"].get("status", "").startswith("active")]
    if active:
        print(f"Lessons in force ({len(active)}): lessons/LESSONS.md")
    print("Read: `loop.py brief` — the three checklists with this project's items "
          "merged in; specs/round.md (the record's shape); the chosen lens's file "
          "and the `refines:` shape it names. At the verdict, `loop.py review`.")
    return 0


# ---------------------------------------------------------------- stale

def cmd_stale(root: Path, loop: Path) -> int:
    if not loop.is_dir():
        print(f"no {loop} — data not laid out")
        return 1
    if git(root, "rev-parse", "--git-dir") is None:
        print("no git — ageing cannot be computed")
        return 1
    data = load(loop)
    rows: list[tuple[str, str, str, list[str] | None, str]] = []

    for lid, ent in data["lenses"].items():
        st = ent["fields"].get("status", "")
        m = SWEPT_RE.match(st)
        if not m:
            if SWEPT_OFF_RE.match(st):
                rows.append(("sweep", lid, "—", None,
                             "off-journal sweep: the code at sweep time is unknown, re-measure"))
            continue
        paths = split_list(ent["fields"].get("paths", ""))
        changed = changed_files(root, m.group(2), paths) if paths else []
        rows.append(("sweep", lid, m.group(2), changed, ""))
    for kind, label in (("backlog", "lead"), ("checked", "negative"),
                        ("probes", "bench"), ("lessons", "lesson")):
        for iid, ent in data[kind].items():
            f = ent["fields"]
            if kind == "backlog" and not f.get("status", "").startswith(("open", "awaiting")):
                continue
            if kind == "probes" and not f.get("status", "").startswith("valid"):
                continue
            if kind == "lessons" and (not f.get("status", "").startswith("active")
                                      or f.get("paths", "").strip() in EMPTY):
                continue
            sm = ONLY_SHA_RE.fullmatch(f.get("commit", "").strip())
            paths = split_list(f.get("paths", ""))
            if not sm:
                rows.append((label, iid, "—", None, ""))
                continue
            rows.append((label, iid, sm.group(0), changed_files(root, sm.group(0), paths) if paths else [], ""))

    stale_n = 0
    for label, iid, sha, changed, note in rows:
        suffix = f" — {note}" if note else ""
        if changed is None:
            print(f"{label:9} {iid:10} sha {sha}: not found or not set — ageing cannot be computed{suffix}")
        elif changed:
            stale_n += 1
            head = ", ".join(changed[:5]) + (" …" if len(changed) > 5 else "")
            print(f"{label:9} {iid:10} STALE: {len(changed)} since {sha[:8]}: {head}{suffix}")
        else:
            print(f"{label:9} {iid:10} fresh: nothing changed along its paths since {sha[:8]}{suffix}")
    print(f"stale: {stale_n} of {len(rows)} records have aged")

    # directories no lens covers
    tracked = (git(root, "ls-files") or "").splitlines()
    globs = [p for ent in data["lenses"].values()
             for p in split_list(ent["fields"].get("paths", ""))]
    if tracked and globs:
        dirs: dict[str, list[int]] = {}
        for f in tracked:
            parts = f.split("/")
            if len(parts) < 2 or parts[0].startswith(".") or parts[0] in ("test", "tests", "docs", "doc", "example", "examples"):
                continue
            d = "/".join(parts[:2])
            cov = any(glob_match(f, g) for g in globs)
            dirs.setdefault(d, [0, 0])
            dirs[d][0] += 1
            dirs[d][1] += int(cov)
        uncovered = [d for d, (n, c) in sorted(dirs.items()) if c == 0]
        if uncovered:
            print("Directories with no lens at all (a reason to redo the set's derivation):")
            for d in uncovered:
                print(f"  {d}/  ({dirs[d][0]} file(s))")
    return 0


# ---------------------------------------------------------------- catalog / review

def cmd_catalog(root: Path, loop: Path) -> int:
    cfg = parse_config(loop)
    have = effective_traits(cfg)
    print("Traits: " + (", ".join(sorted(have)) or "none declared"))
    print("Damage classes (a vocabulary for `breaks:`; nothing reads them): "
          + ", ".join(damage_classes(loop, cfg)))
    forms = catalog_forms(loop)
    print(f"Shapes ({len(forms)}) — ALL of them; nothing here is hidden from you.")
    print("Weigh each shape's `applies:` against this project and instantiate the")
    print("ones that fit. That judgement is yours; the script holds no key to make it.")
    for s in forms:
        print(f"  {s['title']}")
        print(f"      applies: {s['applies']}")
        print(f"      {s['path']}")
    return 0


def assemble(key: str, rel: str, included: dict) -> str:
    """The universal half of a checklist, then every items file the traits admit.

    Whole files, concatenated in a declared order, minus their frontmatter. The
    only thing this knows about a document is its PATH; it never looks inside
    one to decide what part of it to take, because an extraction step that goes
    wrong still produces output that LOOKS right.
    """
    core = SKILL_ROOT / rel
    out = [body(core.read_text())] if core.exists() else []
    for rec in included.get(key, []):
        text = body(rec["path"].read_text()).strip()
        if text:
            out.append(text)
    return "\n".join(x for x in out if x.strip()) + "\n"


def report_skipped(skipped: list[dict], keys: tuple[str, ...]) -> None:
    """What did NOT print, and which trait would have let it.

    An item that silently fails to arrive is the failure mode of the trait
    design -- a shorter checklist looks exactly like a complete one. So this is
    never optional output, and it names the trait rather than the pack: the
    trait is the thing a project can decide to declare.
    """
    rows = [s for s in skipped if s["key"] in keys]
    if not rows:
        return
    print("")
    print(f"Held back ({len(rows)}), each waiting on a trait this project does not declare:")
    for s in sorted(rows, key=lambda r: (r["key"], r["pack"])):
        print(f"  {s['key']:8} {s['pack']}/{s['path'].name} — needs {', '.join(s['missing'])}")
    print("If one of those traits does describe this project, add it to `traits:` "
          "in config.md (or to `local traits:` if the skill's registry has no "
          "name for it) — the item is written and waiting.")


def cmd_brief(root: Path, loop: Path) -> int:
    """The per-round checklists, universal plus this project's, in ONE read.

    One command instead of eight file opens, and the domain half cannot arrive
    without its universal half.
    """
    cfg = parse_config(loop)
    included, skipped = load_items(loop, cfg)
    have = sorted(effective_traits(cfg))
    print("Traits: " + (", ".join(have) if have
                        else "NONE declared — only the universal items print. "
                             "If that is wrong, config.md is not finished."))
    print("")
    for key, rel in BRIEF_PARTS:
        print(f"===== {key} =====")
        print(assemble(key, rel, included).rstrip("\n"))
        print("")
    whys = ", ".join(rel[:-3] + "-why.md" for _, rel in BRIEF_PARTS)
    print("What paid for each item — open one when that item is the one biting, "
          f"not once per round: {whys}, and the same names beside each pack item.")
    report_skipped(skipped, tuple(k for k, _ in BRIEF_PARTS))
    return 0


def cmd_review(root: Path, loop: Path) -> int:
    cfg = parse_config(loop)
    included, skipped = load_items(loop, cfg)
    print(assemble(REVIEW_PART[0], REVIEW_PART[1], included), end="")
    report_skipped(skipped, (REVIEW_PART[0],))
    return 0




# What `init` writes into a fresh `.claude/loop/`. Must satisfy what `lint`
# demands, or `setup` mode hands a new repository a config that is red on sight.
CONFIG_TEMPLATE = """# Loop settings

Schema — `specs/config.md` in the skill. The places below are read by
`loop.py` and their format is exact: the `unattended:` line, `traits:`,
`local traits:`, the ```gate block, the `commit language:` and
`reply language:` lines, and the three «Round budget» lines.

## Mode

unattended: no

## Traits

What this project IS. Every items file under a pack directory declares the
traits it needs, and `loop.py brief` merges the ones this list covers; it then
names every item it held back, so nothing is lost in silence.

Names from the skill's registry (`references/traits.md`) go on the first line.
A property the registry has no name for goes on the second, together with an
items file that needs it in `.claude/loop/items/` — that is how a project
extends the vocabulary instead of bending an existing name to fit.

traits:
local traits:

Own damage classes — comma separated, optional, read by nobody; they are a
vocabulary for whoever writes a lens's `breaks:`.

damage classes:

## Language

Two independent settings. Drop either line and it is English.
`commit language` is the round commit's subject and body; `reply language` is
the round report in chat.

commit language: English
reply language: English

## Toolchain

<what runs the build and the tests; wrappers for the pinned SDK version; known
launch traps and their safe forms>

## Gate

The exact sequence before a commit, one command per line:

```gate
<command 1>
<command 2>
```

## Probes

<where they go and why: import resolution, exclusion from analysis, gitignore>

## After the commit

Commands for an unattended run after a successful round commit (push,
notification); empty means nothing. Covered by permissions.allow like the gate.

```after-commit
```

## Round budget

The first two are limits the round applies to itself — nothing counts them for
you. Past them with no valid number the verdict is INCONCLUSIVE, not CLEAN.
`round cap` is the one number the script enforces.

probes: 3
canaries: 2
round cap: 30

## Targets nobody runs

<another compiler, the native layer, devices, generators — the command and what
it finds>

## Severity bar

<which damage classes are worth a round right now>

## Out of scope

<what the loop is not for>

## Standing owner requirements

<what holds in every round>

## Known flakes

<by name; if none, say so>
"""

LOOP_TEMPLATE = """# LOOP.md — map of the evidence-loop data

Data of a find-and-fix loop; the rules live in the `evidence-loop`
skill (SKILL.md, specs/, methods/). Navigation only here.

## Six entities

- **Lens** — a hypothesis generator: what to look for and how. `lenses/`, index `lenses/LENSES.md`.
- **Round** — what was measured, fixed, and with which verdict. `rounds/`, index `rounds/ROUNDS.md`.
- **Lead** — the unfinished: a deferral, a wait on the owner, a bench with no number. `backlog/`, index `backlog/BACKLOG.md`.
- **Negative** — measured, clean, nothing to do. `checked/`, index `checked/CHECKED.md`.
- **Bench** — a probe whose control proved it can see the defect; reused. `probes/`, index `probes/PROBES.md`.
- **Lesson** — a rule for working with this code that a round paid for. `lessons/`, index `lessons/LESSONS.md`.

## Who points at whom

```mermaid
flowchart LR
    R[round] -->|lens:| L[lens]
    L -->|applied:| R
    R -->|bench:| P[bench]
    B[lead] -->|round:| R
    C[negative] -->|round:| R
    P -->|round:| R
    S[lesson] -->|round:| R
    R -->|## Links| B
    R -->|## Links| C
```

## Where to go with a question

- Run a round — the skill, default mode; start with `loop.py status`.
- The next round's number — `loop.py status` (the maximum in `rounds/` plus one).
- Has this been checked? — `checked/CHECKED.md` and the `swept here` lens statuses.
- Where a claim came from — by ID: `grep -rn "<ID>" .claude/loop/`.
- What awaits the owner — `loop.py status`; to answer, write into the
  `## Owner decision` section of the lead's file, leave the status alone.
- What has aged against the code — `loop.py stale`.
- The state the next round chooses from — `loop.py next`. It names no target.
- Is there a ready bench for this surface — `probes/PROBES.md` or `loop.py next`.
- What we learned on this code — `lessons/LESSONS.md`.

## What to trust with care

<fill in at setup: unrecovered history, «not re-measured» records, sweeps never
run, a lens set no round has checked>
"""

INDEX_TITLES = {
    "lenses": "Lens set of the project — what to look for and how",
    "rounds": "Round journal — newest first",
    "backlog": "Leads — the unfinished; line order is the rank",
    "checked": "Negatives — measured clean, nothing to do",
    "probes": "Benches — probes whose control proved they see the defect",
    "lessons": "Lessons — rules for working with this code, paid for by a round",
}


def cmd_init(root: Path, loop: Path) -> int:
    if loop.exists():
        print(f"{loop} already exists — no laying out on top of data")
        return 1
    loop.mkdir(parents=True)
    (loop / "LOOP.md").write_text(LOOP_TEMPLATE)
    (loop / "config.md").write_text(CONFIG_TEMPLATE)
    for kind, index_name in DIRS.items():
        (loop / kind).mkdir()
        (loop / kind / index_name).write_text(
            f"# {INDEX_TITLES[kind]}\n\nRules and links — [../LOOP.md](../LOOP.md).\n\n")
    print(f"laid out: {loop}")
    print("next: fill in config.md per specs/config.md, permissions in "
          ".claude/settings.json, lenses mode, then loop.py lint")
    return 0


# ---------------------------------------------------------------- evals

# The verdict goes LAST, and is read from the last line. Asked for it first, a
# judge labelled a run PASS and then argued, correctly, that it failed: the
# label is written before the reasoning that would decide it. Reasoning first,
# then the token, and the parser takes the final `VERDICT:` line. Anything else
# -- no verdict, an unparseable one -- counts as a failure, never as a pass.
JUDGE = """You are grading one scenario from a skill's evaluation set.

Below are: what the skill was asked to do, what a correct outcome looks like,
what changed on disk, and what the agent actually said.

Grade ONLY against the expectation. The agent's reasoning does not count, only
what it did and what it reported. Do not be generous: if the expectation names
something specific and it is absent, that is a failure.

## Asked
{prompt}

## A correct outcome
{expected}

## What changed on disk
{facts}

## What the agent said
{output}

---

First write one short paragraph comparing what was expected against what
happened, quoting the evidence. THEN, on the very last line and nothing after
it, write exactly one of:

VERDICT: PASS
VERDICT: FAIL
"""
VERDICT_RE = re.compile(r"^VERDICT:\s*(PASS|FAIL)\s*$", re.M)


# A journal for a scenario that ships the fixture PROJECT: the gate runs its
# suite, and `byte-limits` is the trait that fits it -- a ceiling with something
# charged and released against it -- so the domain items about charge points
# arrive with the checklist.
PROJECT_CONFIG = (
    "unattended: no\ntraits: byte-limits\n"
    "commit language: English\nreply language: English\n"
    "## Toolchain\n\n`python3`, no installation needed.\n\n"
    "## Gate\n\n```gate\npython3 -m unittest discover -s .\n```\n"
    "```after-commit\n```\n"
    "## Probes\n\n`probe_*.py` at the repository root; overwrite, do not delete.\n\n"
    "## Severity bar\n\nAnything that leaks a bounded resource.\n\n"
    "probes: 3\ncanaries: 2\nround cap: 50\n")


def eval_fixture(dest: Path, scenario: dict) -> Path:
    """A throwaway repository: the skill, a journal, and optionally the project.

    With `"project": true` the fixture carries `evals/project/` -- a router with
    a bounded queue whose `fail` path never returns the slot it charged, and a
    suite of four tests that all pass without noticing. That is what makes a
    scenario about FINDING something runnable: a synthetic journal holds no
    defect, so an agent asked to hunt in one has nothing to find.
    """
    skill_dst = dest / ".claude" / "skills" / SKILL_ROOT.name
    skill_dst.parent.mkdir(parents=True)
    shutil.copytree(SKILL_ROOT, skill_dst)
    if scenario.get("project"):
        for f in sorted((SKILL_ROOT / "evals" / "project").glob("*.py")):
            shutil.copy(f, dest / f.name)
        scenario.setdefault("fixture", {}).setdefault("config.md", PROJECT_CONFIG)
    loop = dest / ".claude" / "loop"
    if scenario.get("fixture") is not None:
        build_fixture(loop, **scenario["fixture"])
    (dest / ".claude" / "settings.json").write_text(json.dumps(
        {"permissions": {"allow": [
            f"Bash(python3 {skill_dst / 'scripts' / 'loop.py'}:*)",
            "Bash(python3 -m unittest:*)", "Bash(python3 probe_:*)"]}}, indent=2))
    return loop


def disk_facts(loop: Path, before: set) -> str:
    """Ground truth for the judge, so a verdict can quote the disk.

    Includes the fixture project's own suite: a round that claims FIXED while
    the suite is red, or that never made it green, is a failure whatever the
    record says.
    """
    after = {p.name for p in (loop / "rounds").glob("*.md")}
    added = sorted(after - before)
    facts = [f"round files added: {', '.join(added) if added else 'none'}",
             f"rounds/ now holds {len(after)} file(s)"]
    repo = loop.parent.parent
    if (repo / "router.py").exists():
        out = subprocess.run(["python3", "-m", "unittest", "discover", "-s", "."],
                             cwd=repo, capture_output=True, text=True, check=False)
        tail = (out.stderr or out.stdout).strip().splitlines()
        facts.append(f"the project's suite now: {tail[-1] if tail else '?'}")
        src = (repo / "router.py").read_text()
        facts.append("router.fail still leaks the slot: "
                     + ("yes" if "_pending.remove" not in src.split("def fail")[-1]
                        else "no, it now releases"))
        facts.append(f"test files present: "
                     f"{', '.join(sorted(p.name for p in repo.glob('test_*.py')))}")
    return "\n".join(facts)


def run_claude(prompt: str, cwd: Path, timeout: int) -> tuple[bool, str]:
    try:
        out = subprocess.run(
            ["claude", "-p", prompt, "--permission-mode", "bypassPermissions",
             "--output-format", "text"],
            cwd=cwd, capture_output=True, text=True, timeout=timeout, check=False)
    except FileNotFoundError:
        return False, "the `claude` CLI is not on PATH"
    except subprocess.TimeoutExpired:
        return False, f"no answer within {timeout}s"
    if out.returncode != 0:
        return False, (out.stderr or out.stdout)[-400:]
    return True, out.stdout


def cmd_evals(root: Path, loop: Path) -> int:
    """Run the scenarios in evals/evals.json: one agent to act, one to grade.

    Every run costs two real agent invocations and works inside a THROWAWAY
    repository in a temporary directory, with `--permission-mode
    bypassPermissions`, because the agent has to write files there. Never part
    of `lint` or the gate.

    A scenario with no `fixture` is SKIPPED and counted as skipped, never as a
    pass: most scenarios need the agent to find a real defect, and a defect is
    not something a synthetic journal can hold.
    """
    path = SKILL_ROOT / "evals" / "evals.json"
    items = json.loads(path.read_text()).get("evals", [])
    wanted = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2].isdigit() else None
    if wanted:
        items = [e for e in items if str(e.get("id")) == wanted]
    # Wired means it can be stood up: a `fixture` key (`{}` is the default
    # journal, and is falsy, so test membership and not truth) or `project`,
    # which brings the fixture repository and a journal with it.
    def wired(e: dict) -> bool:
        return "fixture" in e or bool(e.get("project"))

    runnable = [e for e in items if wired(e)]
    skipped = [e for e in items if not wired(e)]

    print(f"{len(runnable)} scenario(s) to run, {len(skipped)} without a fixture.")
    print("Each run is two real agent invocations in a throwaway repo in a "
          "temporary directory, with permissions bypassed there.")
    if not runnable:
        print("Nothing to run. Add a `fixture` to a scenario to make it runnable.")
    passed, failed = [], []
    for e in runnable:
        tmp = Path(tempfile.mkdtemp(prefix=f"eval-{e['id']}-"))
        try:
            fl = eval_fixture(tmp, e)
            before = {p.name for p in (fl / "rounds").glob("*.md")}
            print(f"\n=== {e['id']} {e['name']}")
            ok, out = run_claude(e["prompt"], tmp, e.get("timeout", 600))
            if not ok:
                failed.append((e, f"the agent did not run: {out}"))
                print(f"  ERROR  {out[:200]}")
                continue
            ok, verdict = run_claude(
                JUDGE.format(prompt=e["prompt"], expected=e["expected_output"],
                             facts=disk_facts(fl, before), output=out[-6000:]),
                tmp, 300)
            if not ok:
                failed.append((e, f"the judge did not run: {verdict}"))
                print(f"  ERROR  {verdict[:200]}")
                continue
            marks = VERDICT_RE.findall(verdict)
            if not marks:
                failed.append((e, f"the judge wrote no VERDICT line: {verdict.strip()[:200]}"))
                print("  FAIL   no verdict line — counted as a failure, not a pass")
            elif marks[-1] == "PASS":
                passed.append(e)
                print("  PASS")
            else:
                failed.append((e, verdict.strip()))
                print(f"  FAIL   {verdict.strip()[:300]}")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    print(f"\nevals: {len(passed)} passed, {len(failed)} failed, "
          f"{len(skipped)} skipped for want of a fixture")
    for e in skipped:
        print(f"  skipped  {e['id']} {e['name']}")
    for e, why in failed:
        print(f"  FAILED   {e['id']} {e['name']}: {why.splitlines()[0][:160]}")
    return 1 if failed else 0


# ---------------------------------------------------------------- selftest

FIXTURE = {
    "config.md": (
        "unattended: no\ntraits: dart\n"
        "commit language: English\nreply language: English\n"
        "```gate\ntrue\n```\n"
        "```after-commit\n```\n"
        "probes: 3\ncanaries: 2\nround cap: 50\n"),
    "LOOP.md": "# LOOP.md\n\nfixture\n",
    "lenses/LENSES.md": "# Lenses\n\n[../LOOP.md](../LOOP.md)\n\n"
                        "**[X-1](X-1-fix.md)** derived\n",
    "lenses/X-1-fix.md": (
        "---\nrefines: U-01\npaths: lib/**\napplies: always\nbreaks: a crash\n"
        "applied: 1\nstatus: derived\n---\n\n# X-1 — fixture\n\n"
        "## Shape\n\ns\n\n## Detector\n\nd\n\n## Ask\n\na\n\n## Evidence\n\ne\n"),
    "rounds/ROUNDS.md": "# Rounds\n\n[../LOOP.md](../LOOP.md)\n\n"
                        "**[1](1-one.md)** FIXED\n",
    "rounds/1-one.md": (
        "---\nround: 1\nverdict: FIXED\npackages: p\nlens: X-1\n"
        "bench: P-1 — reused\ncommit: yes\n---\n\n# Round 1 — fixture\n\n"
        "## Target\n\nt\n\n## Hypothesis\n\nh\n\n## Before\n\n```\n41 MiB\n```\n\n"
        "## Mechanism\n\nm\n\n## After\n\n4 MiB\n\n## Canary\n\nfailed: boom\n\n"
        "## Gate\n\ngreen\n\n## Not fixed\n\n—\n\n## Links\n\nX-1\n"),
    "backlog/BACKLOG.md": "# Leads\n\n[../LOOP.md](../LOOP.md)\n\n"
                          "**[B-1](B-1-lead.md)** open\n",
    "backlog/B-1-lead.md": (
        "---\nstatus: open\nround: 1\ncommit: abc1234\npaths: lib/**\n"
        "probe: none\nreason: cost\n---\n\n# B-1 — fixture\n\n"
        "## Owner decision\n\n—\n"),
    "checked/CHECKED.md": "# Negatives\n\n[../LOOP.md](../LOOP.md)\n\n"
                          "**[C-1](C-1-clean.md)** clean\n",
    "checked/C-1-clean.md": (
        "---\nround: 1\ncommit: abc1234\npaths: lib/**\nscope: all\n---\n\n"
        "# C-1 — fixture\n\n## Control\n\nmechanism removed, number differed\n"),
    "probes/PROBES.md": "# Benches\n\n[../LOOP.md](../LOOP.md)\n\n"
                        "**[P-1](P-1-bench.md)** valid\n",
    "probes/P-1-bench.md": (
        "---\nfile: tool/p.dart\nround: 1\ncommit: abc1234\npaths: lib/**\n"
        "status: valid\n---\n\n# P-1 — fixture\n\n## Measures\n\nbytes\n\n"
        "## Control\n\nmechanism removed\n"),
    "lessons/LESSONS.md": "# Lessons\n\n[../LOOP.md](../LOOP.md)\n\n"
                          "**[L-1](L-1-lesson.md)** active\n",
    "lessons/L-1-lesson.md": (
        "---\nround: 1\nclass: bench\ncost: 2 rebuilds\npaths: lib/**\n"
        "commit: abc1234\nstatus: active\n---\n\n# L-1 — fixture\n"),
}


def build_fixture(loop: Path, **override: str) -> None:
    """A journal that lints clean, with named files replaced or deleted.

    `override` takes `path=text`, or `path=None` to leave the file out.
    """
    for rel, text in {**FIXTURE, **override}.items():
        p = loop / rel
        if text is None:
            continue
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)


def cmd_selftest(root: Path, loop: Path) -> int:
    """This file's own checks, against a fixture — NOT against the live journal.

    It is a subcommand rather than a `tests/` directory with its own runner for
    one reason, and it is rule zero: the allowlist grants `python3 <path to
    loop.py>`, so a second script would need a second permission rule in every
    repository, for a command only whoever edits the skill ever runs. Reachable
    through the one allowed entry point, it costs nothing to keep runnable.

    What it covers is what has actually broken here: names deleted from under a
    caller (twice in one commit, one of which killed `setup` mode on its first
    command), a field parsed by looking for a digit anywhere in it, and now the
    declared paths `brief` and `review` concatenate. It needs no `.claude/loop/`,
    so a fresh repository can check the skill before laying anything out.
    """
    failures: list[str] = []
    checks = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal checks
        checks += 1
        if not ok:
            failures.append(f"{name}{': ' + detail if detail else ''}")

    # --- round_key: an anchored grammar, not "a digit somewhere in the field"
    check("round_key plain", round_key("234") == "234")
    check("round_key with commentary", round_key("234 — measured, then accepted") == "234")
    check("round_key off-journal", round_key("off-journal 77") is None)
    check("round_key unknown", round_key("—") is None)
    check("round_key not re-measured", round_key("— (not re-measured)") is None)
    # The case the old `re.search(r"\d+")` got wrong in silence.
    check("round_key ignores a trailing second number",
          round_key("213 measured, 214 accepted") == "213")
    check("round_key refuses a leading word", round_key("see 234") is None)

    # --- frontmatter and sections
    doc = parse_doc("---\nstatus: open\npaths: [a/**, b/**]\nlist:\n- one\n- two\n"
                    "---\n\n# T — x\n\n## Owner decision\n\ntext here\n")
    check("parse_doc scalar", doc["front"].get("status") == "open")
    check("parse_doc inline list", doc["front"].get("paths") == ["a/**", "b/**"])
    check("parse_doc block list", doc["front"].get("list") == ["one", "two"])
    check("parse_doc section", doc["sections"].get("owner decision") == "text here")
    check("parse_doc has_front", doc["has_front"] is True)
    check("parse_doc no front", parse_doc("# T\n")["has_front"] is False)

    # --- permission prefix matching, the thing rule zero stands on
    check("covered prefix", covered("melos run analyze", ["Bash(melos run:*)"]))
    check("covered rejects a different command",
          not covered("rm -rf /", ["Bash(melos run:*)"]))
    check("covered exact", covered("uptime", ["Bash(uptime)"]))
    check("covered bare Bash", covered("anything at all", ["Bash"]))
    rep = Report()
    bare_interpreters(["Bash(python3:*)"], "fixture", rep)
    check("bare_interpreters rejects the name", len(rep.errors) == 1)
    rep = Report()
    bare_interpreters([f"Bash(python3 {SKILL_ROOT}/scripts/loop.py:*)"], "fixture", rep)
    check("bare_interpreters accepts the path", not rep.errors)

    # --- globs used for ageing
    check("glob_match nested", glob_match("a/b/c/d.dart", "a/**/*.dart"))
    check("glob_match single segment", not glob_match("a/b/c.dart", "a/*.dart"))
    check("glob_match exact", glob_match("a/b.dart", "a/b.dart"))

    # --- the documented status grammars
    check("lens status derived", bool(LENS_STATUS_RE.match("derived")))
    check("lens status swept", bool(LENS_STATUS_RE.match("swept here (round 12, a1b2c3d)")))
    check("lens status rejects prose", not LENS_STATUS_RE.match("probably clean"))
    check("bench none", bool(BENCH_RE.match("none")))
    check("bench reused", bool(BENCH_RE.match("P-12 — reused")))
    check("bench none with a reason", bool(BENCH_RE.match("none — the detector is a grep")))
    check("bench rejects prose", not BENCH_RE.match("the one from last time"))
    check("bench rejects a trailing sentence", not BENCH_RE.match("P-12 — reused, mostly"))

    # --- round_rigour: each rule canaried, because a check nobody has seen fail
    # is a check nobody knows is wired up. This is the same demand the skill
    # makes of a fix -- no failing witness, no fix.
    def rigour(verdict: str, bench_field: str, before: str, after: str) -> list[str]:
        r = Report()
        round_rigour(r, "f.md", verdict, BENCH_RE.match(bench_field),
                     {"before": before, "after": after})
        return r.errors

    check("rigour passes a proper FIXED round",
          not rigour("FIXED", "P-1 — reused", "41 MiB", "4.4 MiB"))
    check("rigour passes `none` with a reason",
          not rigour("FIXED", "none — a grep detector with an ablation", "12 sites", "0 sites"))
    check("rigour catches bare `none` on FIXED",
          len(rigour("FIXED", "none", "12 sites", "0 sites")) == 1)
    check("rigour does not ERROR on a numberless Before",
          not rigour("FIXED", "P-1 — reused", "it grew", "4.4 MiB"),
          "a number is the usual evidence, not the only admissible one")
    check("rigour ignores a CLEAN round",
          not rigour("CLEAN", "none", "no number", "no number"))
    check("rigour ignores DEFERRED",
          not rigour("DEFERRED", "none", "no number", "no number"))

    def rigour_warns(verdict: str, bench_field: str, before: str, after: str) -> list[str]:
        r = Report()
        round_rigour(r, "f.md", verdict, BENCH_RE.match(bench_field),
                     {"before": before, "after": after})
        return r.warnings

    check("rigour still FLAGS a numberless Before",
          any("Before" in w for w in rigour_warns("FIXED", "P-1 — reused", "it grew", "4.4 MiB")))
    check("rigour is quiet when both sections carry numbers",
          not rigour_warns("FIXED", "P-1 — reused", "41 MiB", "4.4 MiB"))
    check("backlog status", bool(BACKLOG_STATUS_RE.match("decided by owner (round 9)")))
    check("probe status", bool(PROBE_STATUS_RE.match("stale (a1b2c3d)")))
    check("lesson status", bool(LESSON_STATUS_RE.match("active")))

    # --- config parsing, on a fixture rather than on this repository's file
    tmp = Path(tempfile.mkdtemp(prefix="loop-selftest-"))
    try:
        cfgdir = tmp / "cfg"
        cfgdir.mkdir()
        (cfgdir / "config.md").write_text(
            "unattended: yes\npacks: dart, async-io\n"
            "commit language: English\nreply language: Russian\n"
            "```gate\nmelos run analyze\nmelos run test\n```\n"
            "probes: 3\ncanaries: 2\nround cap: 40\n")
        cfg = parse_config(cfgdir)
        check("config unattended", cfg["unattended"] is True)
        check("config gate", cfg["gate"] == ["melos run analyze", "melos run test"])
        check("config budget", cfg["budget"] == {"probes": 3, "canaries": 2, "round cap": 40})
        check("config reply language", cfg["reply_lang"] == "Russian")

        # --- traits: declared, merged, and never interpreted
        (cfgdir / "config.md").write_text(
            "unattended: no\ntraits: dart, dart2js\nlocal traits: grpc-wire-compat\n"
            "```gate\ntrue\n```\n"
            "probes: 1\ncanaries: 1\nround cap: 5\n")
        tcfg = parse_config(cfgdir)
        check("config traits", tcfg["traits"] == ["dart", "dart2js"])
        check("config local traits", tcfg["local_traits"] == ["grpc-wire-compat"])
        check("config knows no `mandate:`", "mandate" not in tcfg,
              "a key parsed, printed, and read by nothing that decides")
        check("effective traits merge both lines",
              effective_traits(tcfg) == {"dart", "dart2js", "grpc-wire-compat"})
        check("a project can extend the vocabulary",
              "grpc-wire-compat" in effective_traits(tcfg)
              and "grpc-wire-compat" not in registry_traits())

        # --- init, the path a live repository can never exercise
        newroot = tmp / "repo"
        newroot.mkdir()
        newloop = newroot / ".claude" / "loop"
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = cmd_init(newroot, newloop)
        check("init returns 0", rc == 0, f"returned {rc}")
        check("init writes LOOP.md", (newloop / "LOOP.md").exists())
        check("init writes config.md", (newloop / "config.md").exists())
        for kind, index_name in DIRS.items():
            check(f"init writes {kind}/{index_name}", (newloop / kind / index_name).exists())
        # What `init` writes must satisfy what `lint` demands, or `setup` mode
        # hands a new repository a config that is red on its first check. The
        # template carried `packs: core` for one commit after the traits
        # redesign, which lint had just been taught to refuse.
        fresh = parse_config(newloop)
        check("the init template declares no `packs:`", not fresh["packs"],
              "setup would write a config lint rejects on sight")
        check("the init template has the traits keys",
              "traits:" in (newloop / "config.md").read_text()
              and "local traits:" in (newloop / "config.md").read_text())

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = cmd_init(newroot, newloop)
        check("init refuses to overwrite", rc == 1, f"returned {rc}")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = cmd_status(newroot, newloop)
        check("status on a fresh layout", rc == 0 and "Next round: 1" in buf.getvalue())

        # --- next, past the two early returns that a finished loop cannot get
        # past. In a repository at its round cap `next` stops before it prints
        # anything about lenses, so the table -- including the per-lens counts
        # that moved here from `yield` -- has no live exercise at all. A fixture
        # under the cap is the only place that branch runs.
        (newloop / "config.md").write_text(
            "unattended: no\npacks: core\n```gate\ntrue\n```\n"
            "probes: 3\ncanaries: 2\nround cap: 40\n")
        (newloop / "lenses" / "X-1-fixture.md").write_text(
            "---\nrefines: U-01\npaths: lib/**\napplies: always\n"
            "breaks: a crash\napplied: 1\nstatus: derived\n---\n\n"
            "# X-1 — fixture\n\n## Shape\n\ns\n\n## Detector\n\nd\n\n"
            "## Ask\n\na\n\n## Evidence\n\ne\n")
        (newloop / "rounds" / "1-fixture.md").write_text(
            "---\nround: 1\nverdict: FIXED\npackages: p\nlens: X-1\n"
            "bench: none\ncommit: yes\n---\n\n# Round 1 — fixture\n\n"
            "## Target\n\nt\n\n## Hypothesis\n\nh\n\n## Before\n\nb\n\n"
            "## Mechanism\n\nm\n\n## After\n\na\n\n## Canary\n\nc\n\n"
            "## Gate\n\ng\n\n## Not fixed\n\n—\n\n## Links\n\n—\n")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = cmd_next(newroot, newloop)
        out = buf.getvalue()
        check("next runs below the cap", rc == 0, f"returned {rc}")
        check("next prints the lens table", "LENSES" in out)
        check("next carries the per-lens counts", "1 round(s), 1 FIXED" in out,
              "the counts that moved here from `yield` did not print")
        check("next names brief rather than a reading list", "loop.py brief" in out)
        check("next still chooses nothing", "THE SCRIPT DOES NOT CHOOSE" in out)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # --- the declared paths brief and review concatenate
    for key, rel in (*BRIEF_PARTS, REVIEW_PART):
        p = SKILL_ROOT / rel
        check(f"declared path {rel} exists", p.exists())
        check(f"declared path {rel} is not empty", p.exists() and bool(p.read_text().strip()))
        why = SKILL_ROOT / (rel[:-3] + "-why.md")
        if key != "review":
            check(f"{rel} has its -why beside it", why.exists())
    core_only = assemble(BRIEF_PARTS[0][0], BRIEF_PARTS[0][1], {})
    check("assemble with no items returns the core",
          core_only.strip().startswith("# Measurement"))
    fake = {"measure": [{"path": SKILL_ROOT / "items" / "measure-dart.md"}]}
    merged = assemble(BRIEF_PARTS[0][0], BRIEF_PARTS[0][1], fake)
    check("assemble appends an items file", len(merged) > len(core_only))
    check("assemble strips the items file's frontmatter",
          "needs:" not in merged and "D1." in merged,
          "the `needs:` key leaked into the checklist a round reads")

    # --- trait filtering: an item arrives iff every trait it needs is declared
    tmp2 = Path(tempfile.mkdtemp(prefix="loop-traits-"))
    try:
        inc, skip = load_items(tmp2, {"traits": ["dart"], "local_traits": [],
                                      "packs": []})
        names = [r["path"].name for r in inc["tests"]]
        check("an item whose trait is declared arrives", "tests-dart.md" in names)
        check("an item whose trait is missing does NOT arrive",
              "tests-dart2js.md" not in names)
        check("a held-back item is reported, never dropped in silence",
              any(r["path"].name == "tests-dart2js.md" and r["missing"] == ["dart2js"]
                  for r in skip))
        inc2, _ = load_items(tmp2, {"traits": ["dart", "dart2js"], "local_traits": [],
                                    "packs": []})
        check("declaring the trait lets the item through",
              "tests-dart2js.md" in [r["path"].name for r in inc2["tests"]])
        check("a -why file is never concatenated",
              not any(r["path"].name.endswith("-why.md")
                      for k in inc2 for r in inc2[k]))
    finally:
        shutil.rmtree(tmp2, ignore_errors=True)

    # --- the catalog is not gated, and a shape carries only what it is for
    forms = catalog_forms(SKILL_ROOT / "nonexistent")
    check("catalog lists every shape", len(forms) >= 23, f"{len(forms)} shapes")
    check("every shape says when it applies",
          all(s["applies"] for s in forms),
          "a shape with no `applies:` cannot be weighed by lenses mode")
    for s in forms:
        front = parse_doc(s["path"].read_text())["front"]
        check(f"{s['id']} declares only schema keys",
              set(front) <= set(CATALOG_FRONT),
              f"extra: {sorted(set(front) - set(CATALOG_FRONT))}")

    for key, f in item_files(SKILL_ROOT / "nonexistent"):
        front = parse_doc(f.read_text())["front"]
        check(f"{f.name} declares needs", "needs" in front)
        text = f.read_text()
        check(f"{f.name} holds items and nothing else",
              not text.lstrip().startswith("#") and "](" not in text,
              "a heading or a link would land inside a checklist or a prompt")
    keys = {k for k, _ in item_files(SKILL_ROOT / "nonexistent")}
    check("items exist for every checklist key",
          keys == {"measure", "canary", "tests", "review"}, str(sorted(keys)))
    check("damage classes come from the trait registry",
          "frame jank" in damage_classes(SKILL_ROOT / "nonexistent",
                                         {"classes": []}),
          "the vocabulary lost its one home")
    # A `## Section` whose heading matches a frontmatter key: read through
    # `fields` it returns the section's prose instead of the declared value.
    collide = parse_doc("---\ndamage classes: crash, hang\n---\n\n"
                        "## Damage classes\n\nsome prose about them\n")
    check("a section heading does not shadow a frontmatter key in `front`",
          front_list(collide["front"], "damage classes") == ["crash", "hang"])
    check("`fields` DOES merge the two — which is why declared keys use `front`",
          "prose" in collide["fields"]["damage classes"])
    # The other half: a value may be inline or a block list, and `front` hands
    # back a string for one and a list for the other.
    inline = parse_doc("---\nneeds: dart, dart2js\n---\n")["front"]
    block = parse_doc("---\nneeds:\n- dart\n- dart2js\n---\n")["front"]
    check("front_list reads the inline form", front_list(inline, "needs") == ["dart", "dart2js"])
    check("front_list reads the block form", front_list(block, "needs") == ["dart", "dart2js"])
    check("front_list on a missing key is empty", front_list({}, "needs") == [])

    # --- lens -> verdicts, read from the declared field only
    fixture = {"rounds": {
        "1": {"fields": {"lens": "RPC-3", "verdict": "FIXED"}},
        "2": {"fields": {"lens": "RPC-3", "verdict": "CLEAN"}},
        "3": {"fields": {"lens": "RPC-3 because the migration is its own record",
                         "verdict": "FIXED"}}}}
    got = lens_verdicts(fixture)
    check("lens_verdicts counts declared rounds", got.get("RPC-3") == ["FIXED", "CLEAN"])
    check("lens_verdicts ignores a field with prose in it", len(got) == 1)

    # --- lint, against a fixture journal that is mutated one rule at a time.
    # Without this every `rep.error` in cmd_lint is a branch nobody has seen
    # taken: the live journal is green, so the error paths never run.
    tmp3 = Path(tempfile.mkdtemp(prefix="loop-lint-"))
    try:
        def errs(**override: str) -> list[str]:
            d = tmp3 / f"j{len(list(tmp3.iterdir()))}"
            build_fixture(d, **override)
            return lint_report(d.parent, d, skill=False).errors

        base = errs()
        check("the fixture journal lints clean", not base, "; ".join(base[:4]))

        def catches(name: str, needle: str, **override: str) -> None:
            found = errs(**override)
            check(f"lint catches {name}", any(needle in e for e in found),
                  f"got: {'; '.join(found[:3]) or 'nothing'}")

        catches("a verdict off the list", "is not one of",
                **{"rounds/1-one.md": FIXTURE["rounds/1-one.md"]
                   .replace("verdict: FIXED", "verdict: PROBABLY")})
        catches("FIXED without commit: yes", "`commit:` is not `yes`",
                **{"rounds/1-one.md": FIXTURE["rounds/1-one.md"]
                   .replace("commit: yes", "commit: no")})
        catches("FIXED with an empty canary", "`## Canary` is empty",
                **{"rounds/1-one.md": FIXTURE["rounds/1-one.md"]
                   .replace("## Canary\n\nfailed: boom", "## Canary\n\nn/a")})
        catches("FIXED with a bare `bench: none`", "and no reason",
                **{"rounds/1-one.md": FIXTURE["rounds/1-one.md"]
                   .replace("bench: P-1 — reused", "bench: none")})
        catches("a bench that is not in probes/", "not found in probes/",
                **{"rounds/1-one.md": FIXTURE["rounds/1-one.md"]
                   .replace("bench: P-1 — reused", "bench: P-9 — reused")})
        catches("a lens the set does not hold", "not found in lenses/",
                **{"rounds/1-one.md": FIXTURE["rounds/1-one.md"]
                   .replace("lens: X-1", "lens: X-9")})
        catches("`lens:` with prose after the ID", "must be exactly one ID",
                **{"rounds/1-one.md": FIXTURE["rounds/1-one.md"]
                   .replace("lens: X-1", "lens: X-1 because it fit")})
        catches("a lens missing the round from `applied:`", "does not list it",
                **{"lenses/X-1-fix.md": FIXTURE["lenses/X-1-fix.md"]
                   .replace("applied: 1", "applied:")})
        catches("a lens status off schema", "off the lens.md schema",
                **{"lenses/X-1-fix.md": FIXTURE["lenses/X-1-fix.md"]
                   .replace("status: derived", "status: probably fine")})
        catches("empty `paths:`", "`paths:` empty",
                **{"lenses/X-1-fix.md": FIXTURE["lenses/X-1-fix.md"]
                   .replace("paths: lib/**", "paths: —")})
        catches("a file with no line in its index", "with no line in",
                **{"probes/PROBES.md": "# Benches\n\n[../LOOP.md](../LOOP.md)\n"})
        catches("an index line with no file", "with no file",
                **{"probes/PROBES.md": FIXTURE["probes/PROBES.md"]
                   + "**[P-2](P-2-gone.md)** valid\n"})
        catches("a negative with no control", "hope, not a negative",
                **{"checked/C-1-clean.md": FIXTURE["checked/C-1-clean.md"]
                   .replace("mechanism removed, number differed", "—")})
        catches("a bench with no control", "not valid",
                **{"probes/P-1-bench.md": FIXTURE["probes/P-1-bench.md"]
                   .replace("## Control\n\nmechanism removed", "## Control\n\n—")})
        catches("a lesson with no price", "no number",
                **{"lessons/L-1-lesson.md": FIXTURE["lessons/L-1-lesson.md"]
                   .replace("cost: 2 rebuilds", "cost: some effort")})
        catches("a lesson class off the list", "`class:` is not one of",
                **{"lessons/L-1-lesson.md": FIXTURE["lessons/L-1-lesson.md"]
                   .replace("class: bench", "class: vibes")})
        catches("`commit:` that is not a sha", "must be exactly a sha",
                **{"backlog/B-1-lead.md": FIXTURE["backlog/B-1-lead.md"]
                   .replace("commit: abc1234", "commit: the one with the fix")})
        catches("`continuation: yes` on a closed lead", "only an OPEN lead",
                **{"backlog/B-1-lead.md": FIXTURE["backlog/B-1-lead.md"]
                   .replace("status: open", "status: closed (round 1)")
                   .replace("reason: cost", "reason: cost\ncontinuation: yes")})
        catches("an empty `reason:`", "`reason:` is empty",
                **{"backlog/B-1-lead.md": FIXTURE["backlog/B-1-lead.md"]
                   .replace("reason: cost", "reason:")})
        catches("a placeholder left in the gate", "placeholder",
                **{"config.md": FIXTURE["config.md"]
                   .replace("```gate\ntrue\n```", "```gate\n<command 1>\n```")})
        catches("a missing gate block", "no ```gate block",
                **{"config.md": FIXTURE["config.md"]
                   .replace("```gate\ntrue\n```", "")})
        catches("no traits declared", "no `traits:` line",
                **{"config.md": FIXTURE["config.md"].replace("traits: dart", "")})
        catches("a trait outside the registry", "not in the skill's registry",
                **{"config.md": FIXTURE["config.md"]
                   .replace("traits: dart", "traits: dart, wobbly")})
        catches("a local trait the registry already defines", "already defines",
                **{"config.md": FIXTURE["config.md"]
                   .replace("traits: dart", "traits: dart\nlocal traits: dart2js")})
        catches("a `packs:` line", "`packs:` is gone",
                **{"config.md": FIXTURE["config.md"] + "packs: core\n"})
        catches("a budget line missing", "under «Round budget»",
                **{"config.md": FIXTURE["config.md"].replace("canaries: 2", "")})
        catches("a round file off the naming schema", "name off schema",
                **{"rounds/one.md": FIXTURE["rounds/1-one.md"]})
        catches("a heading that disagrees with the file name", "!=",
                **{"rounds/1-one.md": FIXTURE["rounds/1-one.md"]
                   .replace("# Round 1 — fixture", "# Round 2 — fixture")})
        catches("a missing frontmatter block", "no frontmatter",
                **{"lessons/L-1-lesson.md": "# L-1 — fixture\n"})
        catches("an index with no link to LOOP.md", "no link to ../LOOP.md",
                **{"lessons/LESSONS.md": "# Lessons\n\n**[L-1](L-1-lesson.md)** active\n"})

        # --- the rest of the branches, one case each
        catches("a missing LOOP.md", "LOOP.md: missing", **{"LOOP.md": None})
        catches("a missing config.md", "config.md: missing", **{"config.md": None})
        catches("no `unattended:` line", "no `unattended: yes|no` line",
                **{"config.md": FIXTURE["config.md"].replace("unattended: no", "")})
        catches("a whole directory gone", "directory missing",
                **{"probes/PROBES.md": None, "probes/P-1-bench.md": None})
        catches("a missing index", "index missing",
                **{"lessons/LESSONS.md": None})
        catches("an index keeping a next free number", "next free number",
                **{"lessons/LESSONS.md": FIXTURE["lessons/LESSONS.md"]
                   + "\nNext free number: 2\n"})
        catches("an index line pointing at the wrong file", "points at",
                **{"lessons/L-1-lesson.md": None,
                   "lessons/L-1-renamed.md": FIXTURE["lessons/L-1-lesson.md"]})
        catches("a round heading off the form", "heading is not",
                **{"rounds/1-one.md": FIXTURE["rounds/1-one.md"]
                   .replace("# Round 1 — fixture", "# Fixture round")})
        catches("`round:` disagreeing with the file name", "does not match the number",
                **{"rounds/1-one.md": FIXTURE["rounds/1-one.md"]
                   .replace("round: 1\n", "round: 2\n")})
        catches("an entity heading without its ID", "heading must start with",
                **{"lessons/L-1-lesson.md": FIXTURE["lessons/L-1-lesson.md"]
                   .replace("# L-1 — fixture", "# a lesson")})
        catches("`commit:` that is neither yes nor no", "must be `yes` or `no`",
                **{"rounds/1-one.md": FIXTURE["rounds/1-one.md"]
                   .replace("commit: yes", "commit: abc1234")})
        catches("a malformed `bench:`", "`bench:` must be",
                **{"rounds/1-one.md": FIXTURE["rounds/1-one.md"]
                   .replace("bench: P-1 — reused", "bench: the one from last time")})
        catches("`budget:` off its form", "`budget:` off the form",
                **{"rounds/1-one.md": FIXTURE["rounds/1-one.md"]
                   .replace("commit: yes", "commit: yes\nbudget: lots")})
        catches("a budget exceeded on a FIXED round", "budget exceeded",
                **{"rounds/1-one.md": FIXTURE["rounds/1-one.md"]
                   .replace("commit: yes",
                            "commit: yes\nbudget: probes 9/3, canaries 1/2")})
        catches("`review:` off its form", "`review:` must start with",
                **{"rounds/1-one.md": FIXTURE["rounds/1-one.md"]
                   .replace("commit: yes", "commit: yes\nreview: a subagent did it")})
        catches("`applied:` holding a non-round", "holds a non-round",
                **{"lenses/X-1-fix.md": FIXTURE["lenses/X-1-fix.md"]
                   .replace("applied: 1", "applied: last tuesday")})
        catches("`applied:` naming a round with no file", "no file",
                **{"lenses/X-1-fix.md": FIXTURE["lenses/X-1-fix.md"]
                   .replace("applied: 1", "applied: 1, 7")})
        catches("an off-journal mark above the journal's start", "not history",
                **{"lenses/X-1-fix.md": FIXTURE["lenses/X-1-fix.md"]
                   .replace("applied: 1", "applied: 1, off-journal 9")})
        catches("confirmed with no evidence", "`## Evidence` is empty",
                **{"lenses/X-1-fix.md": FIXTURE["lenses/X-1-fix.md"]
                   .replace("status: derived", "status: confirmed (round 1)")
                   .replace("## Evidence\n\ne", "## Evidence\n\n—")})
        catches("a lead status off schema", "off schema",
                **{"backlog/B-1-lead.md": FIXTURE["backlog/B-1-lead.md"]
                   .replace("status: open", "status: maybe later")})
        catches("`continuation:` that is not yes/no", "is not yes/no",
                **{"backlog/B-1-lead.md": FIXTURE["backlog/B-1-lead.md"]
                   .replace("reason: cost", "reason: cost\ncontinuation: perhaps")})
        catches("a lead naming a round with no file", "no round file",
                **{"backlog/B-1-lead.md": FIXTURE["backlog/B-1-lead.md"]
                   .replace("round: 1", "round: 9")})
        catches("a lead with an unparseable round", "needs a round number",
                **{"backlog/B-1-lead.md": FIXTURE["backlog/B-1-lead.md"]
                   .replace("round: 1", "round: unknown")})
        catches("a bench status off schema", "off the probe.md schema",
                **{"probes/P-1-bench.md": FIXTURE["probes/P-1-bench.md"]
                   .replace("status: valid", "status: probably fine")})
        catches("a bench with no file named", "`file:` is empty",
                **{"probes/P-1-bench.md": FIXTURE["probes/P-1-bench.md"]
                   .replace("file: tool/p.dart", "file:")})
        catches("a lesson status off schema", "off the lesson.md schema",
                **{"lessons/L-1-lesson.md": FIXTURE["lessons/L-1-lesson.md"]
                   .replace("status: active", "status: still true")})
        catches("a lesson with no round", "was not paid for",
                **{"lessons/L-1-lesson.md": FIXTURE["lessons/L-1-lesson.md"]
                   .replace("round: 1", "round: —")})
        catches("a shape missing a schema key", "a shape says",
                **{"catalog/U-90-fixture.md":
                   "---\napplies: everywhere\n---\n\n# U-90 — fixture\n"})
        catches("a shape carrying a key outside the schema", "not in the schema",
                **{"catalog/U-91-fixture.md":
                   "---\napplies: everywhere\nbreaks: a crash\npack: core\n---\n\n"
                   "# U-91 — fixture\n"})
        catches("a shape whose heading disagrees with its file name",
                "heading must start with",
                **{"catalog/U-92-other.md":
                   "---\napplies: everywhere\nbreaks: a crash\n---\n\n"
                   "# U-93 — fixture\n"})
        catches("an items file holding a heading below its frontmatter",
                "holds a heading or a link",
                **{"items/measure-fix.md": "---\nneeds: dart\n---\n\n# Title\n\nF1. x\n"})
        catches("an items file holding a link", "holds a heading or a link",
                **{"items/measure-fix.md":
                   "---\nneeds: dart\n---\n\nF1. see [here](x.md)\n"})

        def warns(**override: str) -> list[str]:
            d = tmp3 / f"w{len(list(tmp3.iterdir()))}"
            build_fixture(d, **override)
            return lint_report(d.parent, d, skill=False).warnings

        check("lint warns on an items file with no `needs:`",
              any("will be merged into" in w
                  for w in warns(**{"items/measure-fix.md": "F1. no precondition\n"})),
              "an unconditional item is a warning, not an error")
        catches("an uncovered gate command under unattended", "permissions.allow",
                **{"config.md": FIXTURE["config.md"]
                   .replace("unattended: no", "unattended: yes")})
        catches("a journal path to the skill that does not resolve",
                "which does not exist",
                **{"LOOP.md": "# LOOP.md\n\nrules: `../skills/renamed-loop/`\n"})
        check("a placeholder path is not reported",
              not any("does not exist" in e for e in
                      errs(**{"LOOP.md": "# LOOP.md\n\n`.claude/skills/<name>/`\n"})),
              "`<name>` is a schema placeholder, not a broken path")
    finally:
        shutil.rmtree(tmp3, ignore_errors=True)

    # --- this file, parsed for names it reads but never binds
    rep = Report()
    script_names(rep)
    check("loop.py binds every name it reads", not rep.errors,
          "; ".join(rep.errors[:3]))

    # --- the skill's own link graph, without needing any project data
    rep = Report()
    skill_graph(rep)
    check("the skill's link graph is whole", not rep.errors,
          "; ".join(rep.errors[:3]))

    for f in failures:
        print(f"FAIL  {f}")
    print(f"selftest: {checks - len(failures)}/{checks} passed")
    return 1 if failures else 0


# ---------------------------------------------------------------- main

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["init", "status", "next", "brief", "lint",
                                        "stale", "catalog", "review", "yield",
                                        "selftest", "evals"])
    ap.add_argument("arg", nargs="?", help=argparse.SUPPRESS)
    ap.add_argument("--root", default=".", help="repository root (the current directory by default)")
    ap.add_argument("--loop", default=".claude/loop", help="path to the loop data relative to the root")
    a = ap.parse_args(argv)
    root = Path(a.root).resolve()
    loop = (root / a.loop).resolve()
    return {"init": cmd_init, "status": cmd_status, "next": cmd_next, "brief": cmd_brief,
            "lint": cmd_lint, "stale": cmd_stale, "catalog": cmd_catalog,
            "yield": cmd_yield, "review": cmd_review,
            "selftest": cmd_selftest, "evals": cmd_evals}[a.command](root, loop)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(0)
