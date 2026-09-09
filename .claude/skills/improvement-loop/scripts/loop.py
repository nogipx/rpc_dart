#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
#
# SPDX-License-Identifier: MIT
"""Improvement-loop bookkeeping: .claude/loop/ is checked by a script, not by memory.

    loop.py init     lay out .claude/loop/ (refuses if it already exists)
    loop.py status   next round number, last round, leads, owner decisions,
                     lenses, benches, lessons, stop condition
    loop.py next     the next round's target by the selection rules: owner
                     decision -> lens never applied -> rank -> stale sweep;
                     plus the reading list, matching benches and the budget
    loop.py lint     data integrity per specs/: fields, links in both
                     directions, indexes, round commits, gate permissions;
                     and the skill's OWN graph — every file reachable from
                     SKILL.md, no dangling link, no step named by number
    loop.py stale    what has aged against the code: sweeps, negatives, leads,
                     benches, lessons by their sha and paths; sweeps with a
                     script detector by the hash of the instance list;
                     directories no lens covers
    loop.py catalog  catalog shapes for the enabled packs (lenses mode)
    loop.py review   reviewer prompt: core plus the enabled packs' questions

Standard library only. Run from the repository root, or pass --root.
lint exit code: 0 clean, 1 errors found.
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import re
import subprocess
import sys
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

# The skill's own directories, each with an index named after it: SKILL.md links
# the indexes, an index lists its files, and the walk from SKILL.md must reach
# everything. `packs/` is two levels — `packs/<name>/PACK.md` indexes its own
# directory and is itself listed by `packs/PACKS.md`.
#
# Measured before this was written: 41 of 45 files had zero outbound links,
# `evals/` was reachable from nothing, and two of seven method cross-references
# pointed at a step of SKILL.md that had moved.
SKILL_DIRS = {
    "catalog": "CATALOG.md",
    "methods": "METHODS.md",
    "specs": "SPECS.md",
    "references": "REFERENCES.md",
    "evals": "EVALS.md",
    "packs": "PACKS.md",
}

# Machine fields live in frontmatter, prose in `## Section` blocks. Frontmatter
# keys and section headings are compared lower-cased.
ROUND_FRONT = ["round", "verdict", "packages", "lens", "bench", "commit"]
# Tolerated on rounds written before these were dropped, required on none.
# `review:` said "self" in 39 of 39 rounds -- a step satisfied nominally every
# time is worse than no step. `budget:` was self-reported from memory and
# validated by nothing.
ROUND_OPTIONAL = ["budget", "review"]
ROUND_SECTIONS = ["target", "hypothesis", "before", "mechanism", "after",
                  "canary", "gate", "not fixed", "links"]
LENS_FRONT = ["refines", "paths", "applies", "breaks", "applied", "status"]
LENS_SECTIONS = ["shape", "detector", "ask", "evidence"]
LENS_OPTIONAL: list[str] = []
BACKLOG_FRONT = ["status", "round", "commit", "paths", "probe", "reason"]
# Optional, opt-in: marks a lead as work a round STARTED and did not finish,
# which `select_target` takes before opening a new lens. See specs/backlog-item.md.
BACKLOG_OPTIONAL = ["continuation"]
BACKLOG_SECTIONS = ["owner decision"]
CHECKED_FRONT = ["round", "commit", "paths", "scope"]
CHECKED_SECTIONS = ["control"]
PROBE_FRONT = ["file", "round", "commit", "paths", "status"]
PROBE_SECTIONS = ["measures", "control"]
LESSON_FRONT = ["round", "class", "cost", "paths", "commit", "status"]
LESSON_SECTIONS: list[str] = []
PACK_FRONT = ["applies", "damage classes", "shapes", "contains"]
CATALOG_FRONT = ["pack", "applies", "breaks", "status"]
SKILL_ROOT = Path(__file__).resolve().parent.parent

ID_RE = re.compile(r"^([A-Z]+-\d+)-[^/]+\.md$")
ROUND_FILE_RE = re.compile(r"^(\d+)-[^/]+\.md$")
ROUND_H1_RE = re.compile(r"^# Round (\d+) — (.+)$")
ANY_ID_RE = re.compile(r"\b([A-Z]+-\d+)\b")
SHA_RE = re.compile(r"\b[0-9a-f]{7,40}\b")
# `off-journal` — a round that happened but whose record does not exist:
# setup.md allows starting the journal partway. Such a reference is not checked
# for a file, but it must sit BELOW the journal's first round, or the marker
# could bury a record that went missing recently.
LENS_STATUS_RE = re.compile(
    r"^(derived|confirmed \(round \d+(?:, off-journal)?\)|"
    r"swept here \(round \d+, (?:[0-9a-f]{7,40}(?:, sweep [0-9a-f]{8})?|off-journal)\)|"
    r"retracted \(round \d+(?:, off-journal)?\))")
SWEPT_RE = re.compile(r"swept here \(round (\d+), ([0-9a-f]{7,40})(?:, sweep ([0-9a-f]{8}))?\)")
SWEPT_OFF_RE = re.compile(r"swept here \(round (\d+), off-journal\)")
SCRIPT_RE = re.compile(r"^(\S+)(.*)$")
BACKLOG_STATUS_RE = re.compile(
    r"^(open|awaiting owner|closed \(round \d+\)|"
    r"decided by owner \(round \d+\))")
PROBE_STATUS_RE = re.compile(r"^(valid|stale \([0-9a-f]{7,40}\)|broken \(round \d+\))")
LESSON_STATUS_RE = re.compile(r"^(active|promoted to skill \([^)]+\)|obsolete \(round \d+\))")
LESSON_CLASSES = ("bench", "toolchain", "fixture", "metric", "process")
BUDGET_RE = re.compile(r"probes (\d+)/(\d+), canaries (\d+)/(\d+)")
BENCH_RE = re.compile(r"^(none|(P-\d+) — (reused|new))")
MD_LINK_RE = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
# A cross-reference to a numbered step of SKILL.md. The numbering moves whenever
# a step is added, and nothing notices: `methods/canary.md` said "before step 5"
# while the canary was step 6, and `methods/reporting.md` said "at step 7" while
# the report was step 8. Name the step instead.
STEP_NUM_RE = re.compile(r"\bstep \d", re.IGNORECASE)
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


def round_key(value: object) -> str | None:
    """The canonical form of a round number: `007`, `7` and `round 7` are one.

    Numbers are not zero-padded any more, so two spellings of the same round
    would otherwise be two different keys and every cross-reference check would
    pass while pointing at nothing.
    """
    s = str(value)
    # An OFF-JOURNAL round is a real number with no file behind it: rounds
    # before the journal existed. Demanding a file for every digit cost 21 of
    # 30 negatives their round number -- C-06 was measured in round 77, and the
    # frontmatter could only say "not re-measured" because 77 would not resolve.
    # The number is knowledge; the parser was destroying it to stay happy.
    if "off-journal" in s or "not re-measured" in s:
        return None
    m = re.search(r"\d+", s)
    return str(int(m.group(0))) if m else None


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


def round_numbers(loop: Path) -> list[int]:
    nums = []
    for p in entity_files(loop / "rounds", DIRS["rounds"]):
        m = ROUND_FILE_RE.match(p.name)
        if m:
            nums.append(int(m.group(1)))
    return sorted(nums)


def parse_config(loop: Path) -> dict:
    cfg = {"unattended": None, "gate": [], "budget": {}, "packs": ["core"],
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
    m = re.search(r"^packs:[ \t]*(.*)$", text, re.M | re.I)
    if m and m.group(1).strip():
        cfg["packs"] = split_list(m.group(1))
        if "core" not in cfg["packs"]:
            cfg["packs"].insert(0, "core")
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


def load_packs(loop: Path, cfg: dict) -> tuple[dict, list[str]]:
    """Enabled packs: the skill's first, then private ones in .claude/loop/packs/."""
    packs: dict[str, dict] = {}
    missing: list[str] = []
    for name in cfg["packs"]:
        found = None
        for base in (SKILL_ROOT / "packs", loop / "packs"):
            if (base / name / "PACK.md").exists():
                found = base / name
                break
        if not found:
            missing.append(name)
            continue
        fields = parse_doc((found / "PACK.md").read_text())["fields"]
        packs[name] = {"path": found, "fields": fields,
                       "files": {k: found / f"{k}.md" for k in ("measure", "canary", "tests", "review")
                                 if (found / f"{k}.md").exists()},
                       "detectors": sorted((found / "detectors").glob("*")) if (found / "detectors").is_dir() else []}
    return packs, missing


def damage_classes(packs: dict, cfg: dict) -> list[str]:
    out: list[str] = []
    for pk in packs.values():
        out += split_list(pk["fields"].get("damage classes", ""))
    out += cfg["classes"]
    return [c for c in out if c not in EMPTY]


def catalog_forms(loop: Path, packs: dict) -> list[tuple[str, str, Path]]:
    """(ID, pack, file) for the skill's catalog shapes and private packs' ones."""
    out = []
    dirs = [SKILL_ROOT / "catalog"] + [pk["path"] / "catalog" for pk in packs.values()
                                       if (pk["path"] / "catalog").is_dir()]
    for d in dirs:
        for f in sorted(d.glob("U-*.md")):
            fields = parse_doc(f.read_text())["fields"]
            out.append((f.name[:4] if f.name[4] == "-" else f.name.split("-")[0] + "-" + f.name.split("-")[1],
                        (fields.get("pack") or "core").strip(), f))
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


def resolve_script(loop: Path, packs: dict, rel: str) -> Path | None:
    """Detector script path: relative to the skill, .claude/loop/, a pack or the root."""
    cands = [SKILL_ROOT / rel, loop / rel, loop.parent.parent / rel]
    for pk in packs.values():
        cands.append(pk["path"] / rel)
    for c in cands:
        if c.exists():
            return c
    return None


# ---------------------------------------------------------------- lint

def skill_index_for(p: Path) -> Path | None:
    """The index that owns `p`, or None when nothing does (SKILL.md itself)."""
    rel = p.relative_to(SKILL_ROOT)
    parts = rel.parts
    if len(parts) == 1:
        return None                                  # SKILL.md is the root
    if parts[0] == "packs":
        if len(parts) == 2:                          # packs/PACKS.md
            return SKILL_ROOT / "SKILL.md"
        if rel.name == "PACK.md":                    # packs/<name>/PACK.md
            return SKILL_ROOT / "packs" / "PACKS.md"
        return SKILL_ROOT / "packs" / parts[1] / "PACK.md"
    index = SKILL_DIRS.get(parts[0])
    if index is None:
        return None
    if rel.name == index:
        return SKILL_ROOT / "SKILL.md"
    return SKILL_ROOT / parts[0] / index


def skill_graph(rep: "Report") -> None:
    """The skill's own files form ONE connected graph, and lint says so.

    Three properties, one per defect this was written after measuring: every
    link resolves, every file is reachable from SKILL.md (`evals/` was reachable
    from nothing), and no cross-reference names a step by number (two had
    drifted onto the wrong step).
    """
    files = sorted(SKILL_ROOT.rglob("*.md"))
    root_md = SKILL_ROOT / "SKILL.md"
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

    for p in files:
        if p == root_md:
            continue                                 # SKILL.md owns the numbering
        for n, line in enumerate(p.read_text().splitlines(), 1):
            if STEP_NUM_RE.search(line):
                rep.error(f"skill {p.relative_to(SKILL_ROOT)}:{n}: a step named by NUMBER — "
                          "the numbering in SKILL.md drifts and nothing notices; "
                          "name the step instead")


def cmd_yield(root: Path, loop: Path) -> int:
    """What each lens has actually produced. A FACT, decided by nobody.

    `curate` used to re-rank the set by feel. This counts: how many rounds took
    a lens, and how many of those ended FIXED. The first run of it made the
    single most useful observation in the project's history -- the lenses mined
    out of existing history found a defect on FIRST application three times out
    of three, while several derived ones had been applied twice for nothing.
    Rank on that, not on which shape feels clever.
    """
    if not loop.is_dir():
        print(f"no {loop} — data not laid out: setup mode (loop.py init)")
        return 1
    data = load(loop)
    took: dict[str, list[str]] = {}
    for ent in data["rounds"].values():
        f = ent["fields"]
        m = ANY_ID_RE.search(f.get("lens", ""))
        if m:
            took.setdefault(m.group(0), []).append(f.get("verdict", "").strip())

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


def cmd_lint(root: Path, loop: Path) -> int:
    rep = Report()
    if not loop.is_dir():
        print(f"no {loop} — setup mode: loop.py init")
        return 1
    for name in ("LOOP.md", "config.md"):
        if not (loop / name).exists():
            rep.error(f"{name}: missing")

    data = load(loop)
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
    packs, missing = load_packs(loop, cfg)
    for name in missing:
        rep.error(f"config.md: pack «{name}» found neither in {SKILL_ROOT / 'packs'} nor in {loop / 'packs'}")
    for name, pk in packs.items():
        for fld in PACK_FRONT:
            if fld not in pk["fields"]:
                rep.error(f"packs/{name}/PACK.md: no `{fld}:` key in the frontmatter")
    classes = damage_classes(packs, cfg)

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
        brk = f.get("breaks", "").lower()
        if brk and classes and not any(c.lower() in brk for c in classes):
            rep.warn(f"lenses/{ent['path'].name}: `breaks:` «{f['breaks'][:60]}» names no damage class "
                     f"of the enabled packs ({', '.join(classes)}) — add the class to config.md "
                     "(`damage classes:`) or rephrase")
        first_round = min(data["rounds"], key=int, default=None)

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
            rk = round_key(tok)
            if rk is None:
                rep.error(f"lenses/{ent['path'].name}: `applied:` holds a non-round: «{tok}»")
                continue
            applied.add(rk)
            check_round(rk, "off-journal" in tok, "`applied:`")
        lens_rounds[lid] = applied
        m = re.search(r"round (\d+)", st)
        if m:
            check_round(round_key(m.group(1)), "off-journal" in st, "the status")
        if st.startswith("confirmed") and f.get("evidence", "").strip() in EMPTY:
            rep.error(f"lenses/{ent['path'].name}: confirmed, but `## Evidence` is empty")

    have_git = git(root, "rev-parse", "--git-dir") is not None
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
            rep.error(f"rounds/{pname}: `bench:` must be `P-N — reused`, `P-N — new` or `none`")
        elif sm_ and sm_.group(2) and sm_.group(2) not in data["probes"]:
            rep.error(f"rounds/{pname}: bench {sm_.group(2)} not found in probes/")
        if f.get("review") and not REVIEW_RE.match(f["review"].strip()):
            rep.error(f"rounds/{pname}: `review:` must start with `subagent`, `self` or `claude -p`")
        if commit == "yes" and have_git:
            # The alternation covers records written before the loop switched
            # to English: those commit bodies say «Раунд NNN».
            # Case-INSENSITIVE and with no trailing space. Grepping for
            # "Round NNN " matched neither this repo's own commit convention
            # ("round 233 - ...") nor a body ending at the number, so eight
            # warnings stood for ~35 rounds, all false. A checker that is
            # stably wrong gets muted, and it was: every lint call in the
            # session that found this piped the warnings away.
            found = git(root, "log", "--all", "-i", "-E", "--format=%h",
                        f"--grep=(round|раунд) {rn}")
            if not (found or "").strip():
                rep.warn(f"rounds/{pname}: `commit: yes`, but no commit mentions "
                         f"round {rn} (not committed yet?)")
        lens_ref = f.get("lens", "")
        lm = ANY_ID_RE.search(lens_ref)
        if not lm:
            rep.error(f"rounds/{pname}: no ID in `lens:`")
        else:
            lid = lm.group(1)
            if lid.startswith("U-"):
                rep.warn(f"rounds/{pname}: lens {lid} is a catalog shape, not instantiated into the set")
            elif lid not in data["lenses"]:
                rep.error(f"rounds/{pname}: lens {lid} not found in lenses/")
            elif rn not in lens_rounds.get(lid, set()):
                rep.error(f"lenses/{data['lenses'][lid]['path'].name}: round {rn} used this lens, "
                          f"but its `applied:` does not list it")
        for tok in ANY_ID_RE.findall(f.get("links", "")):
            if tok.startswith(("B-", "C-")):
                kind = "backlog" if tok.startswith("B-") else "checked"
                if tok not in data[kind]:
                    rep.error(f"rounds/{pname}: `## Links` refers to {tok}, no file")

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
            if not SHA_RE.search(f.get("commit", "")):
                rep.error(f"{kind}/{pname}: `commit:` with no sha — ageing cannot be computed")
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
        if not SHA_RE.search(f.get("commit", "")):
            rep.error(f"probes/{pname}: `commit:` with no sha")
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
        if not SHA_RE.search(f.get("commit", "")):
            rep.error(f"lessons/{pname}: `commit:` with no sha")

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

    # --- the skill's own graph
    skill_graph(rep)
    return rep.dump()


# ---------------------------------------------------------------- selection

def changed_files(root: Path, sha: str, paths: list[str]) -> list[str] | None:
    if git(root, "cat-file", "-e", f"{sha}^{{commit}}") is None:
        return None
    specs = [f":(glob){p}" for p in paths]
    out = git(root, "diff", "--name-only", sha, "HEAD", "--", *specs)
    if out is None:
        return None
    return [l for l in out.splitlines() if l.strip()]


def lens_rank(loop: Path, data: dict) -> list[str]:
    """Line order in LENSES.md is the rank; lenses with no line go last."""
    order = list(index_links(loop / "lenses" / DIRS["lenses"]).keys())
    rest = [lid for lid in data["lenses"] if lid not in order]
    return [lid for lid in order if lid in data["lenses"]] + sorted(rest)


def backlog_rank(loop: Path, data: dict) -> list[str]:
    """Line order in BACKLOG.md is the rank; leads with no line go last."""
    order = list(index_links(loop / "backlog" / DIRS["backlog"]).keys())
    rest = [bid for bid in data["backlog"] if bid not in order]
    return [bid for bid in order if bid in data["backlog"]] + sorted(rest)


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

    NOT just `awaiting owner`. Writing the decision is what ENDS that status, so
    matching it alone meant a lead dropped out of the priority slot at the exact
    moment it became actionable, and fell to the bottom of the rank behind every
    lens. Measured at round 224: B-17 — a data loss with a decision, a bench and
    a reproduction — was the one thing `next` could never point at.

    A decision stays outstanding until the lead is `closed`. `decided by owner`
    therefore means "answered, not yet carried out"; a lead whose work shipped is
    `closed (round N)` like any other.

    Ranked by BACKLOG.md, per the rule that order lives in the index.

    The STATUS decides, not the section. `## Owner decision` is an archive: a
    lead whose decision was measured unbuildable keeps the old text with a
    "superseded" note above it, because the reasoning is still worth reading.
    Matching on "the section is non-empty" therefore reads a retired decision as
    a live one -- B-17 was named as the round's first target five rounds running
    while its decision was known impossible, and B-22 repeated it at round 232.

    So: `decided by owner` means answered and not yet carried out;
    `awaiting owner` means waiting, whatever the section still holds.
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
    """The ONLY thing the script still decides, and only because unattended runs
    need it: an agent asked "should we continue?" always says yes.

    Everything else that used to stop or steer a round -- ranking targets,
    "every lens is swept so the work is done" -- was judgement wearing a
    script's authority, and it cost five rounds of opening new threads while a
    started one sat unfinished. Facts belong here; choices do not.

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

    # One home for "which decisions are outstanding": `select_target` picks the
    # round's target from this same list, so status cannot disagree with next.
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
        print("Target: none — there is no lens set, do lenses mode first")
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

    print("LENSES — status, and the rounds that applied them:")
    for lid in sorted(data["lenses"]):
        f = data["lenses"][lid]["fields"]
        ap = split_list(f.get("applied", ""))
        print(f"  {lid:8} {f.get('status', ''):34} applied: {', '.join(ap) if ap else 'never'}")

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
    print(f"Budget: probes 0/{b.get('probes', '?')}, canaries 0/{b.get('canaries', '?')}")
    packs, missing = load_packs(loop, cfg)
    print("Packs: " + ", ".join(packs) + (f" (not found: {', '.join(missing)})" if missing else ""))
    print(f"Commit language: {cfg['commit_lang']}")
    print(f"Reply language: {cfg['reply_lang']}")
    # THE CHECKLISTS, not the files. Each of these opens with the operative list
    # and then spends most of its words on the stories that paid for each item.
    # The stories are why the rules stick and are worth reading once; re-reading
    # ~2400 words of them to reach ~600 words of checklist, every round, is the
    # largest recurring cost in the loop. Read the checklist; open the story
    # behind an item when that item is the one biting.
    reading = ["methods/measurement.md — the checklist at the top",
               "methods/canary.md — the checklist at the top",
               "methods/tests.md — the checklist at the top",
               "specs/round.md (the record's shape)"]
    for name, pk in packs.items():
        for k in ("measure", "canary", "tests"):
            if k in pk["files"]:
                reading.append(str(pk["files"][k].relative_to(SKILL_ROOT)) if SKILL_ROOT in pk["files"][k].parents
                               else str(pk["files"][k]))
    reading.append("`loop.py review` — the reviewer prompt with the packs' questions")
    # No per-lens reading here: the detector, the paths and the refined catalog
    # shape all live in the lens's own file, and naming one would be choosing.
    reading.append("the chosen lens's file, and the `refines:` shape it names")
    active = [l for l, e in data["lessons"].items() if e["fields"].get("status", "").startswith("active")]
    if active:
        print(f"Lessons in force ({len(active)}): lessons/LESSONS.md")
    print("Read: " + "; ".join(reading))
    return 0


def _overlap(a: str, b: str) -> bool:
    """Rough overlap of two globs: the first two path segments in common."""
    sa = [s for s in a.split("/") if s and s not in ("**", "*")][:2]
    sb = [s for s in b.split("/") if s and s not in ("**", "*")][:2]
    return bool(sa) and bool(sb) and sa[: len(sb)] == sb[: len(sa)]


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

    cfg = parse_config(loop)
    packs, _ = load_packs(loop, cfg)
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
        note = ""
        if m.group(3):
            if res is None:
                note = "detector script not found"
            elif res[1] != m.group(3):
                note = f"the instance list changed: sweep {m.group(3)} -> {res[1]}, {len(res[0])} instances"
                changed = (changed or []) + [f"[detector] {l}" for l in res[0][:3]]
            else:
                note = "the same instance list"
        rows.append(("sweep", lid, m.group(2), changed, note))
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
            sm = SHA_RE.search(f.get("commit", ""))
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


# ---------------------------------------------------------------- catalog / review / sweep

def cmd_catalog(root: Path, loop: Path) -> int:
    cfg = parse_config(loop)
    packs, missing = load_packs(loop, cfg)
    if missing:
        print(f"packs not found: {', '.join(missing)}")
    print("Packs: " + ", ".join(packs))
    print("Damage classes: " + ", ".join(damage_classes(packs, cfg)))
    forms = catalog_forms(loop, packs)
    enabled = [(uid, pk, f) for uid, pk, f in forms if pk in packs]
    skipped = [(uid, pk) for uid, pk, f in forms if pk not in packs]
    print(f"Shapes to instantiate ({len(enabled)}):")
    for uid, pk, f in enabled:
        h = h1(f.read_text())[2:]
        print(f"  {h}  [{pk}]  {f}")
    if skipped:
        print("Outside the enabled packs: " + ", ".join(f"{u} ({p})" for u, p in skipped))
    return 0


def fenced(text: str) -> str:
    m = re.search(r"```\n(.*?)```", text, re.S)
    return m.group(1) if m else ""


def cmd_review(root: Path, loop: Path) -> int:
    cfg = parse_config(loop)
    packs, _ = load_packs(loop, cfg)
    core = fenced((SKILL_ROOT / "references" / "review.md").read_text())
    extra = []
    for name, pk in packs.items():
        if "review" in pk["files"]:
            block = fenced(pk["files"]["review"].read_text()).strip()
            if block:
                extra.append(f"# {name}\n{block}")
    if extra:
        lines = core.rstrip("\n").splitlines()
        idx = next((i for i, l in enumerate(lines) if l.startswith("Bottom line")), len(lines))
        lines[idx:idx] = ["", *extra, ""]
        core = "\n".join(lines) + "\n"
    print(core, end="")
    return 0




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


# ---------------------------------------------------------------- main

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["init", "status", "next", "lint", "stale", "catalog", "review", "yield"])
    ap.add_argument("arg", nargs="?", help=argparse.SUPPRESS)
    ap.add_argument("--root", default=".", help="repository root (the current directory by default)")
    ap.add_argument("--loop", default=".claude/loop", help="path to the loop data relative to the root")
    a = ap.parse_args(argv)
    root = Path(a.root).resolve()
    loop = (root / a.loop).resolve()
    return {"init": cmd_init, "status": cmd_status, "next": cmd_next, "lint": cmd_lint,
            "stale": cmd_stale, "catalog": cmd_catalog, "yield": cmd_yield, "review": cmd_review}[a.command](root, loop)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(0)
