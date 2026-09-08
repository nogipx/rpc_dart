#!/usr/bin/env python3
"""Учёт цикла улучшений: .claude/loop/ проверяется скриптом, а не памятью.

    loop.py init     развернуть .claude/loop/ (отказывается, если уже есть)
    loop.py status   следующий номер раунда, последний раунд, зацепки, решения
                     владельца, линзы, стенды, уроки, условие остановки
    loop.py next     цель следующего раунда по правилам выбора: решение
                     владельца -> линза без применений -> ранг -> устаревший
                     свип; плюс список чтения, подходящие стенды и бюджет
    loop.py lint     целостность данных по specs/: поля, ссылки в обе стороны,
                     оглавления, коммиты раундов, покрытие гейта разрешениями
    loop.py stale    что состарилось относительно кода: свипы, негативы, зацепки,
                     стенды, уроки по их sha и путям; свипы со скриптовым
                     детектором — по хешу списка экземпляров; директории, не
                     покрытые ни одной линзой
    loop.py catalog  формы каталога для подключённых пакетов (режим lenses)
    loop.py review   промпт рецензента: core плюс вопросы подключённых пакетов
    loop.py sweep ID прогнать скриптовый детектор линзы: экземпляры, счёт, хеш

Только стандартная библиотека. Запускать из корня репозитория или с --root.
Код выхода lint: 0 — чисто, 1 — есть ошибки.
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

ROUND_FIELDS = ["Линза", "Гипотеза", "Стенд", "До", "Механизм", "После",
                "Канарейка", "Бюджет", "Рецензия", "Гейт", "Коммит", "Не чинил",
                "Связи"]
LENS_FIELDS = ["Уточняет", "Форма", "Детектор", "Пути", "Спрашивать",
               "Ломается", "Применима", "Улика", "Применена", "Статус"]
BACKLOG_FIELDS = ["Статус", "Раунд", "Коммит", "Пути", "Проба", "Причина",
                  "Решение владельца"]
CHECKED_FIELDS = ["Раунд", "Коммит", "Пути", "Область", "Контроль"]
PROBE_FIELDS = ["Файл", "Измеряет", "Контроль", "Раунд", "Коммит", "Пути", "Статус"]
LESSON_FIELDS = ["Раунд", "Класс", "Цена", "Пути", "Коммит", "Статус"]
PACK_FIELDS = ["Применим", "Классы ущерба", "Формы", "Содержит"]
ALL_FIELDS = set(ROUND_FIELDS + LENS_FIELDS + BACKLOG_FIELDS + CHECKED_FIELDS
                 + PROBE_FIELDS + LESSON_FIELDS + PACK_FIELDS + ["Пакет"])
SKILL_ROOT = Path(__file__).resolve().parent.parent

ID_RE = re.compile(r"^([A-ZА-ЯЁ]+-\d{2,})-[^/]+\.md$")
ROUND_FILE_RE = re.compile(r"^(\d{3})-[^/]+\.md$")
ROUND_H1_RE = re.compile(r"^# Раунд (\d{3}) — (\w+) — ")
ANY_ID_RE = re.compile(r"\b([A-ZА-ЯЁ]+-\d{2,})\b")
SHA_RE = re.compile(r"\b[0-9a-f]{7,40}\b")
LENS_STATUS_RE = re.compile(
    r"^(выведена|подтверждена \(раунд \d{3}\)|"
    r"исчерпана здесь \(раунд \d{3}, [0-9a-f]{7,40}(, свип [0-9a-f]{8})?\)|отозвана \(раунд \d{3}\))")
SWEPT_RE = re.compile(r"исчерпана здесь \(раунд (\d{3}), ([0-9a-f]{7,40})(?:, свип ([0-9a-f]{8}))?\)")
SCRIPT_RE = re.compile(r"^script:\s*(\S+)(.*)$")
BACKLOG_STATUS_RE = re.compile(
    r"^(открыта|ждёт владельца|закрыта \(раунд \d{3}\)|"
    r"решена владельцем \(раунд \d{3}\))")
PROBE_STATUS_RE = re.compile(r"^(валиден|устарел \([0-9a-f]{7,40}\)|сломан \(раунд \d{3}\))")
LESSON_STATUS_RE = re.compile(r"^(действует|поднята в скилл \([^)]+\)|устарела \(раунд \d{3}\))")
LESSON_CLASSES = ("стенд", "тулчейн", "фикстура", "метрика", "процесс")
BUDGET_RE = re.compile(r"пробы (\d+)/(\d+), канарейки (\d+)/(\d+)")
STAND_RE = re.compile(r"^(без стенда|(P-\d{2,}) — (переиспользован|новый))")
REVIEW_RE = re.compile(r"^(субагент|сам|claude -p)\b")
EMPTY = {"", "—", "-", "n/a", "нет"}


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
            print(f"ОШИБКА  {m}")
        for m in self.warnings:
            print(f"предупр {m}")
        for m in self.infos:
            print(f"инфо    {m}")
        print(f"lint: {len(self.errors)} ошибок, {len(self.warnings)} предупреждений")
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


def parse_fields(text: str) -> dict[str, str]:
    """Поля вида `Имя: значение` с продолжением на отступленных строках."""
    fields: dict[str, str] = {}
    current: str | None = None
    for line in text.splitlines():
        m = re.match(r"^([A-Za-zА-Яа-яЁё][^:\n]{0,40}):[ \t]*(.*)$", line)
        if m and m.group(1).strip() in ALL_FIELDS:
            current = m.group(1).strip()
            fields[current] = m.group(2).strip()
            continue
        if current is not None:
            if line.startswith((" ", "\t")) and line.strip():
                fields[current] = (fields[current] + " " + line.strip()).strip()
                continue
            current = None
    return fields


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
    """ID -> имя файла по строкам `**[ID](file)**`."""
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
           "classes": [], "after_commit": []}
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
    for key in ("пробы", "канарейки", "потолок раундов"):
        km = re.search(rf"^{key}:\s*(\d+)\s*$", text, re.M | re.I)
        if km:
            cfg["budget"][key] = int(km.group(1))
    m = re.search(r"^пакеты:[ \t]*(.*)$", text, re.M | re.I)
    if m and m.group(1).strip():
        cfg["packs"] = split_list(m.group(1))
        if "core" not in cfg["packs"]:
            cfg["packs"].insert(0, "core")
    m = re.search(r"^классы ущерба:[ \t]*(.*)$", text, re.M | re.I)
    if m and m.group(1).strip():
        cfg["classes"] = split_list(m.group(1))
    m = re.search(r"```after-commit\n(.*?)```", text, re.S)
    if m:
        cfg["after_commit"] = [l.strip() for l in m.group(1).splitlines()
                               if l.strip() and not l.strip().startswith("#")]
    return cfg


def load_packs(loop: Path, cfg: dict) -> tuple[dict, list[str]]:
    """Подключённые пакеты: сначала в скилле, потом приватные в .claude/loop/packs/."""
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
        fields = parse_fields((found / "PACK.md").read_text())
        packs[name] = {"path": found, "fields": fields,
                       "files": {k: found / f"{k}.md" for k in ("measure", "canary", "tests", "review")
                                 if (found / f"{k}.md").exists()},
                       "detectors": sorted((found / "detectors").glob("*")) if (found / "detectors").is_dir() else []}
    return packs, missing


def damage_classes(packs: dict, cfg: dict) -> list[str]:
    out: list[str] = []
    for pk in packs.values():
        out += split_list(pk["fields"].get("Классы ущерба", ""))
    out += cfg["classes"]
    return [c for c in out if c not in EMPTY]


def catalog_forms(loop: Path, packs: dict) -> list[tuple[str, str, Path]]:
    """(ID, пакет, файл) для форм каталога скилла и приватных пакетов."""
    out = []
    dirs = [SKILL_ROOT / "catalog"] + [pk["path"] / "catalog" for pk in packs.values()
                                       if (pk["path"] / "catalog").is_dir()]
    for d in dirs:
        for f in sorted(d.glob("U-*.md")):
            fields = parse_fields(f.read_text())
            out.append((f.name[:4] if f.name[4] == "-" else f.name.split("-")[0] + "-" + f.name.split("-")[1],
                        fields.get("Пакет", "core").strip(), f))
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
    """`**` — любые вложенные директории; `*` — внутри одного сегмента."""
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
                key = m.group(1) if m else p.name
            else:
                m = ID_RE.match(p.name)
                key = m.group(1) if m else p.name
            data[kind][key] = {"path": p, "text": text, "h1": h1(text),
                               "fields": parse_fields(text)}
    return data


def resolve_script(loop: Path, packs: dict, rel: str) -> Path | None:
    """Путь скрипта детектора: относительно скилла, .claude/loop/, пакета или корня."""
    cands = [SKILL_ROOT / rel, loop / rel, loop.parent.parent / rel]
    for pk in packs.values():
        cands.append(pk["path"] / rel)
    for c in cands:
        if c.exists():
            return c
    return None


# ---------------------------------------------------------------- lint

def cmd_lint(root: Path, loop: Path) -> int:
    rep = Report()
    if not loop.is_dir():
        print(f"нет {loop} — режим setup: loop.py init")
        return 1
    for name in ("LOOP.md", "config.md"):
        if not (loop / name).exists():
            rep.error(f"{name}: отсутствует")

    data = load(loop)
    cfg = parse_config(loop)
    if cfg["unattended"] is None:
        rep.error("config.md: нет строки `unattended: yes|no`")
    if not cfg["gate"]:
        rep.error("config.md: нет блока ```gate с командами гейта")
    for cmd in cfg["gate"]:
        if "<" in cmd or ">" in cmd:
            rep.error(f"config.md: в блоке gate заполнитель «{cmd}» — гейт не задан")
    for key in ("пробы", "канарейки", "потолок раундов"):
        if key not in cfg["budget"]:
            rep.error(f"config.md: в «Бюджет раунда» нет строки `{key}: N`")
    packs, missing = load_packs(loop, cfg)
    for name in missing:
        rep.error(f"config.md: пакет «{name}» не найден ни в {SKILL_ROOT / 'packs'}, ни в {loop / 'packs'}")
    for name, pk in packs.items():
        for fld in PACK_FIELDS:
            if fld not in pk["fields"]:
                rep.error(f"packs/{name}/PACK.md: нет поля `{fld}:`")
    classes = damage_classes(packs, cfg)

    # --- имена, заголовки, оглавления
    for kind, index_name in DIRS.items():
        dirpath = loop / kind
        if not dirpath.is_dir():
            rep.error(f"{kind}/: директории нет")
            continue
        index_path = dirpath / index_name
        if not index_path.exists():
            rep.error(f"{kind}/{index_name}: оглавления нет")
            links = {}
        else:
            links = index_links(index_path)
            itext = index_path.read_text()
            if "LOOP.md" not in itext:
                rep.error(f"{kind}/{index_name}: нет ссылки на ../LOOP.md")
            if re.search(r"^Следующий свободный номер", itext, re.M):
                rep.error(f"{kind}/{index_name}: хранит «следующий свободный номер» — "
                          "второй дом факта, номер вычисляет status")
            for line in itext.splitlines():
                if line.lstrip().startswith("|"):
                    rep.warn(f"{kind}/{index_name}: таблица — запрещено схемой index.md")
                    break
        for lid, fname in links.items():
            if not (dirpath / fname).exists():
                rep.error(f"{kind}/{index_name}: строка [{lid}]({fname}) без файла")
        for key, ent in data[kind].items():
            p = ent["path"]
            fre = ROUND_FILE_RE if kind == "rounds" else ID_RE
            if not fre.match(p.name):
                rep.error(f"{kind}/{p.name}: имя не по схеме "
                          f"({'NNN-slug.md' if kind == 'rounds' else 'ID-NN-slug.md'})")
                continue
            if key not in links:
                rep.error(f"{kind}/{p.name}: файл без строки в {index_name}")
            elif links[key] != p.name:
                rep.error(f"{kind}/{index_name}: [{key}] указывает на {links[key]}, файл {p.name}")
            if kind == "rounds":
                m = ROUND_H1_RE.match(ent["h1"])
                if not m:
                    rep.error(f"rounds/{p.name}: заголовок не `# Раунд NNN — ВЕРДИКТ — пакет — тема`")
                else:
                    if m.group(1) != key:
                        rep.error(f"rounds/{p.name}: номер в заголовке {m.group(1)} != {key}")
                    if m.group(2) not in VERDICTS:
                        rep.error(f"rounds/{p.name}: вердикт «{m.group(2)}» не из {VERDICTS}")
            else:
                if not ent["h1"].startswith(f"# {key} — "):
                    rep.error(f"{kind}/{p.name}: заголовок должен начинаться с `# {key} — `")
            for line in ent["text"].splitlines():
                if line.lstrip().startswith("|"):
                    rep.warn(f"{kind}/{p.name}: таблица — запрещено схемой")
                    break

    # --- поля и ссылки
    lens_rounds: dict[str, set[str]] = {}
    for lid, ent in data["lenses"].items():
        f = ent["fields"]
        for name in LENS_FIELDS:
            if name not in f:
                rep.error(f"lenses/{ent['path'].name}: нет поля `{name}:`")
        st = f.get("Статус", "")
        if st and not LENS_STATUS_RE.match(st):
            rep.error(f"lenses/{ent['path'].name}: статус «{st}» не по схеме lens.md")
        if f.get("Пути", "").strip() in EMPTY:
            rep.error(f"lenses/{ent['path'].name}: `Пути:` пусто — свип нельзя состарить")
        lom = f.get("Ломается", "").lower()
        if lom and classes and not any(c.lower() in lom for c in classes):
            rep.warn(f"lenses/{ent['path'].name}: `Ломается:` «{f['Ломается'][:60]}» не называет ни один класс "
                     f"ущерба подключённых пакетов ({', '.join(classes)}) — добавить класс в config.md "
                     "(`классы ущерба:`) или переформулировать")
        det = f.get("Детектор", "").strip()
        sm_ = SCRIPT_RE.match(det)
        if sm_ and resolve_script(loop, packs, sm_.group(1)) is None:
            rep.error(f"lenses/{ent['path'].name}: скрипт детектора {sm_.group(1)} не найден")
        applied = set()
        for tok in split_list(f.get("Применена", "")):
            m = re.search(r"\d{3}", tok)
            if not m:
                rep.error(f"lenses/{ent['path'].name}: в `Применена:` не номер раунда: «{tok}»")
                continue
            applied.add(m.group(0))
            if m.group(0) not in data["rounds"]:
                rep.error(f"lenses/{ent['path'].name}: `Применена:` ссылается на раунд {m.group(0)}, файла нет")
        lens_rounds[lid] = applied
        m = re.search(r"раунд (\d{3})", st)
        if m and m.group(1) not in data["rounds"]:
            rep.error(f"lenses/{ent['path'].name}: статус ссылается на раунд {m.group(1)}, файла нет")
        if st.startswith("подтверждена") and f.get("Улика", "").strip() in EMPTY:
            rep.error(f"lenses/{ent['path'].name}: подтверждена, а `Улика:` пуста")

    have_git = git(root, "rev-parse", "--git-dir") is not None
    for rn, ent in data["rounds"].items():
        f = ent["fields"]
        pname = ent["path"].name
        for name in ROUND_FIELDS:
            if name not in f:
                rep.error(f"rounds/{pname}: нет поля `{name}:`")
        m = ROUND_H1_RE.match(ent["h1"])
        verdict = m.group(2) if m else ""
        commit = f.get("Коммит", "").strip().lower()
        if commit and commit not in ("да", "нет"):
            rep.error(f"rounds/{pname}: `Коммит:` должен быть `да` или `нет`, не «{f.get('Коммит')}»")
        if verdict == "FIXED" and commit != "да":
            rep.error(f"rounds/{pname}: FIXED, а `Коммит:` не `да`")
        if verdict == "FIXED":
            for name in ("После", "Канарейка", "Гейт"):
                if f.get(name, "").strip().lower() in EMPTY:
                    rep.error(f"rounds/{pname}: FIXED, а `{name}:` пусто или n/a")
        bm = BUDGET_RE.search(f.get("Бюджет", ""))
        if f.get("Бюджет") and not bm:
            rep.error(f"rounds/{pname}: `Бюджет:` не по форме `пробы n/N, канарейки n/N`")
        elif bm:
            pu, pb, cu, cb = (int(x) for x in bm.groups())
            cfg_b = cfg["budget"]
            if "пробы" in cfg_b and pb != cfg_b["пробы"]:
                rep.warn(f"rounds/{pname}: бюджет проб {pb} != {cfg_b['пробы']} из config.md")
            if "канарейки" in cfg_b and cb != cfg_b["канарейки"]:
                rep.warn(f"rounds/{pname}: бюджет канареек {cb} != {cfg_b['канарейки']} из config.md")
            if (pu > pb or cu > cb) and verdict not in ("INCONCLUSIVE", "DEFERRED"):
                rep.error(f"rounds/{pname}: бюджет превышен ({f['Бюджет']}), а вердикт {verdict}, не INCONCLUSIVE")
        sm_ = STAND_RE.match(f.get("Стенд", "").strip())
        if f.get("Стенд") and not sm_:
            rep.error(f"rounds/{pname}: `Стенд:` должен быть `P-NN — переиспользован`, `P-NN — новый` или `без стенда`")
        elif sm_ and sm_.group(2) and sm_.group(2) not in data["probes"]:
            rep.error(f"rounds/{pname}: стенд {sm_.group(2)} не найден в probes/")
        if f.get("Рецензия") and not REVIEW_RE.match(f["Рецензия"].strip()):
            rep.error(f"rounds/{pname}: `Рецензия:` должна начинаться с `субагент`, `сам` или `claude -p`")
        if commit == "да" and have_git:
            found = git(root, "log", "--all", "--format=%h", f"--grep=Раунд {rn} ")
            if not (found or "").strip():
                rep.warn(f"rounds/{pname}: `Коммит: да`, но `git log --grep \"Раунд {rn} \"` пуст "
                         "(ещё не закоммичен?)")
        lens_ref = f.get("Линза", "")
        lm = ANY_ID_RE.search(lens_ref)
        if not lm:
            rep.error(f"rounds/{pname}: в `Линза:` нет ID")
        else:
            lid = lm.group(1)
            if lid.startswith("U-"):
                rep.warn(f"rounds/{pname}: линза {lid} — каталожная форма без инстанцирования в набор")
            elif lid not in data["lenses"]:
                rep.error(f"rounds/{pname}: линза {lid} не найдена в lenses/")
            elif rn not in lens_rounds.get(lid, set()):
                rep.error(f"lenses/{data['lenses'][lid]['path'].name}: раунд {rn} пользовался линзой, "
                          f"а в её `Применена:` его нет")
        for tok in ANY_ID_RE.findall(f.get("Связи", "")):
            if tok.startswith(("B-", "C-")):
                kind = "backlog" if tok.startswith("B-") else "checked"
                if tok not in data[kind]:
                    rep.error(f"rounds/{pname}: `Связи:` ссылается на {tok}, файла нет")

    for kind, fields, status_re in (("backlog", BACKLOG_FIELDS, BACKLOG_STATUS_RE),
                                    ("checked", CHECKED_FIELDS, None)):
        for iid, ent in data[kind].items():
            f = ent["fields"]
            pname = ent["path"].name
            for name in fields:
                if name not in f:
                    rep.error(f"{kind}/{pname}: нет поля `{name}:`")
            if status_re and f.get("Статус") and not status_re.match(f["Статус"]):
                rep.error(f"{kind}/{pname}: статус «{f['Статус']}» не по схеме")
            rnd = f.get("Раунд", "")
            m = re.search(r"\d{3}", rnd)
            if m and m.group(0) not in data["rounds"]:
                rep.error(f"{kind}/{pname}: `Раунд: {m.group(0)}`, файла раунда нет")
            if not m and "не перепроверено" not in rnd:
                rep.error(f"{kind}/{pname}: `Раунд:` без номера и без пометки «(не перепроверено)»")
            if not SHA_RE.search(f.get("Коммит", "")):
                rep.error(f"{kind}/{pname}: `Коммит:` без sha — старение не посчитать")
            if f.get("Пути", "").strip() in EMPTY:
                rep.error(f"{kind}/{pname}: `Пути:` пусто — старение не посчитать")
            if kind == "checked" and f.get("Контроль", "").strip() in EMPTY:
                rep.error(f"checked/{pname}: негатив без контроля — это надежда, а не негатив")
            if kind == "backlog" and f.get("Причина", "").strip() in EMPTY:
                rep.error(f"backlog/{pname}: `Причина:` пуста")

    for pid, ent in data["probes"].items():
        f = ent["fields"]
        pname = ent["path"].name
        for name in PROBE_FIELDS:
            if name not in f:
                rep.error(f"probes/{pname}: нет поля `{name}:`")
        st = f.get("Статус", "")
        if st and not PROBE_STATUS_RE.match(st):
            rep.error(f"probes/{pname}: статус «{st}» не по схеме probe.md")
        m = re.search(r"\d{3}", f.get("Раунд", ""))
        if m and m.group(0) not in data["rounds"]:
            rep.error(f"probes/{pname}: `Раунд: {m.group(0)}`, файла раунда нет")
        if not SHA_RE.search(f.get("Коммит", "")):
            rep.error(f"probes/{pname}: `Коммит:` без sha")
        if f.get("Пути", "").strip() in EMPTY:
            rep.error(f"probes/{pname}: `Пути:` пусто")
        if f.get("Контроль", "").strip() in EMPTY:
            rep.error(f"probes/{pname}: стенд без контроля не валиден")
        fpath = f.get("Файл", "").strip()
        if fpath in EMPTY:
            rep.error(f"probes/{pname}: `Файл:` пуст")
        elif st.startswith("валиден") and not (root / fpath).exists():
            rep.warn(f"probes/{pname}: файл пробы {fpath} не найден на диске (проба вне git?)")

    for lid_, ent in data["lessons"].items():
        f = ent["fields"]
        pname = ent["path"].name
        for name in LESSON_FIELDS:
            if name not in f:
                rep.error(f"lessons/{pname}: нет поля `{name}:`")
        st = f.get("Статус", "")
        if st and not LESSON_STATUS_RE.match(st):
            rep.error(f"lessons/{pname}: статус «{st}» не по схеме lesson.md")
        if f.get("Класс") and f["Класс"].strip() not in LESSON_CLASSES:
            rep.error(f"lessons/{pname}: `Класс:` не из {LESSON_CLASSES}")
        m = re.search(r"\d{3}", f.get("Раунд", ""))
        if not m:
            rep.error(f"lessons/{pname}: `Раунд:` без номера — урок без раунда не оплачен")
        elif m.group(0) not in data["rounds"]:
            rep.error(f"lessons/{pname}: `Раунд: {m.group(0)}`, файла раунда нет")
        if f.get("Цена", "").strip() in EMPTY or not re.search(r"\d", f.get("Цена", "")):
            rep.error(f"lessons/{pname}: `Цена:` без числа — без цены это не урок")
        if not SHA_RE.search(f.get("Коммит", "")):
            rep.error(f"lessons/{pname}: `Коммит:` без sha")

    # --- нумерация раундов
    nums = round_numbers(loop)
    for a, b in zip(nums, nums[1:]):
        if b != a + 1:
            rep.warn(f"rounds/: пропуск в нумерации между {a:03d} и {b:03d}")

    # --- разрешения
    rules = allow_rules(root)
    if cfg["unattended"]:
        for cmd in cfg["after_commit"]:
            if not covered(cmd, rules):
                rep.error(f"unattended: команда after-commit «{cmd}» не покрыта permissions.allow")
        for cmd in cfg["gate"]:
            if not covered(cmd, rules):
                rep.error(f"unattended: команда гейта «{cmd}» не покрыта permissions.allow "
                          "в .claude/settings.json — она спросит разрешение и убьёт раунд")
        if not covered(f"python3 {Path(__file__).resolve()} status", rules):
            rep.warn("unattended: нет правила, покрывающего `python3 .../scripts/loop.py` — "
                     "status/lint/stale/next спросят разрешение")
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
    """Порядок строк в LENSES.md — ранг; линзы без строки — в конец."""
    order = list(index_links(loop / "lenses" / DIRS["lenses"]).keys())
    rest = [lid for lid in data["lenses"] if lid not in order]
    return [lid for lid in order if lid in data["lenses"]] + sorted(rest)


def swept_stale(root: Path, ent: dict) -> list[str] | None:
    """Для линзы `исчерпана здесь`: изменённые файлы по её путям с sha свипа."""
    m = re.match(r"исчерпана здесь \(раунд \d{3}, ([0-9a-f]{7,40})\)", ent["fields"].get("Статус", ""))
    if not m:
        return None
    paths = split_list(ent["fields"].get("Пути", ""))
    return changed_files(root, m.group(1), paths) if paths else []


def pending_decisions(data: dict) -> list[str]:
    out = []
    for bid, ent in data["backlog"].items():
        f = ent["fields"]
        if f.get("Статус", "").startswith("ждёт владельца") and f.get("Решение владельца", "").strip() not in EMPTY:
            out.append(bid)
    return out


def select_target(root: Path, loop: Path, data: dict) -> tuple[str, str, str]:
    """(вид, ID, причина) по правилам шага 1."""
    dec = pending_decisions(data)
    if dec:
        return ("решение владельца", dec[0], "решение владельца, не принятое в работу, идёт раньше любой линзы")
    rank = lens_rank(loop, data)
    for lid in rank:
        f = data["lenses"][lid]["fields"]
        if f.get("Статус", "").startswith("выведена") and not split_list(f.get("Применена", "")):
            return ("линза", lid, "выведена и ни разу не применена — гипотеза, за которую ещё не платили")
    for lid in rank:
        st = data["lenses"][lid]["fields"].get("Статус", "")
        if st.startswith(("выведена", "подтверждена")):
            return ("линза", lid, "первая по рангу среди не исчерпанных")
    for lid in rank:
        ent = data["lenses"][lid]
        ch = swept_stale(root, ent)
        if ch:
            return ("линза", lid, f"исчерпана, но по её путям изменилось {len(ch)} файл(ов) — перемер")
    for bid, ent in data["backlog"].items():
        if ent["fields"].get("Статус", "").startswith("открыта"):
            return ("зацепка", bid, "открытая зацепка при исчерпанном наборе — перемер (U-21)")
    return ("нет", "", "")


def stop_condition(root: Path, loop: Path, data: dict, cfg: dict) -> tuple[bool, str]:
    n = len(data["rounds"])
    cap = cfg["budget"].get("потолок раундов")
    if cap is not None and n >= cap:
        return True, f"достигнут потолок раундов ({n} из {cap})"
    if not data["lenses"]:
        return False, "набора линз нет — режим lenses"
    kind, tid, why = select_target(root, loop, data)
    if kind != "нет":
        return False, f"есть цель: {kind} {tid}"
    waiting = [b for b, e in data["backlog"].items()
               if e["fields"].get("Статус", "").startswith("ждёт владельца")]
    if waiting:
        return True, f"все линзы исчерпаны и свежи, работа ждёт владельца: {', '.join(waiting)}"
    return True, "все линзы исчерпаны или отозваны, по их путям изменений нет, открытых зацепок нет"


# ---------------------------------------------------------------- status

def cmd_status(root: Path, loop: Path) -> int:
    if not loop.is_dir():
        print(f"нет {loop} — данные не развёрнуты: режим setup (loop.py init)")
        return 1
    data = load(loop)
    nums = round_numbers(loop)
    nxt = (nums[-1] + 1) if nums else 1
    print(f"Следующий раунд: {nxt:03d}")
    if nums:
        last = data["rounds"][f"{nums[-1]:03d}"]
        print(f"Последний раунд: {last['h1'][2:]}")
        print(f"  Не чинил: {last['fields'].get('Не чинил', '—')}")
    else:
        print("Последний раунд: нет — цикл ещё не начинался")

    if not data["lenses"]:
        print("Линзы: набора нет — режим lenses")
    else:
        by = {"выведена": [], "подтверждена": [], "исчерпана здесь": [], "отозвана": [],
              "не по схеме": []}
        never = []
        for lid, ent in data["lenses"].items():
            st = ent["fields"].get("Статус", "")
            key = next((k for k in by if st.startswith(k)), "не по схеме")
            by[key].append(lid)
            if not split_list(ent["fields"].get("Применена", "")):
                never.append(lid)
        print("Линзы: " + ", ".join(f"{k} {len(v)}" for k, v in by.items() if v))
        if never:
            print(f"  ни разу не применены: {', '.join(never)}")

    decisions, waiting, open_ = [], [], []
    for bid, ent in data["backlog"].items():
        f = ent["fields"]
        st = f.get("Статус", "")
        title = ent["h1"][2:]
        if st.startswith("ждёт владельца"):
            if f.get("Решение владельца", "").strip() not in EMPTY:
                decisions.append(f"{title}: {f['Решение владельца']}")
            else:
                waiting.append(title)
        elif st.startswith("открыта"):
            open_.append(f"{title} — {f.get('Причина', '')}")
    print(f"Решения владельца, не принятые в работу: {len(decisions)}"
          + (" — ПЕРВАЯ ЦЕЛЬ РАУНДА" if decisions else ""))
    for d in decisions:
        print(f"  {d}")
    print(f"Ждёт владельца: {len(waiting)}")
    for w in waiting:
        print(f"  {w}")
    print(f"Открытые зацепки: {len(open_)}")
    for o in open_:
        print(f"  {o}")
    print(f"Негативы: {len(data['checked'])}")
    valid = [pid for pid, e in data["probes"].items() if e["fields"].get("Статус", "").startswith("валиден")]
    print(f"Стенды: {len(data['probes'])}, валидных {len(valid)}"
          + (f" ({', '.join(valid)})" if valid else ""))
    active = [l for l, e in data["lessons"].items() if e["fields"].get("Статус", "").startswith("действует")]
    print(f"Уроки: {len(data['lessons'])}, действуют {len(active)} — читать lessons/LESSONS.md")
    cfg = parse_config(loop)
    stop, why = stop_condition(root, loop, data, cfg)
    print(f"Остановка: {'ДА' if stop else 'нет'} — {why}")
    return 0


# ---------------------------------------------------------------- next

def cmd_next(root: Path, loop: Path) -> int:
    if not loop.is_dir():
        print(f"нет {loop} — данные не развёрнуты: режим setup (loop.py init)")
        return 1
    data = load(loop)
    cfg = parse_config(loop)
    nums = round_numbers(loop)
    print(f"Раунд: {(nums[-1] + 1) if nums else 1:03d}")
    if not data["lenses"]:
        print("Цель: нет — набора линз нет, сначала режим lenses")
        return 2
    stop, why = stop_condition(root, loop, data, cfg)
    if stop:
        print(f"Остановка: ДА — {why}. Раунд не начинать; если запущено из /loop — снять задание.")
        return 2
    kind, tid, why = select_target(root, loop, data)
    if kind == "нет":
        print(f"Цель: нет — {why}")
        return 2
    print(f"Цель: {kind} {tid} — {why}")
    b = cfg["budget"]
    print(f"Бюджет: пробы 0/{b.get('пробы', '?')}, канарейки 0/{b.get('канарейки', '?')}")
    packs, missing = load_packs(loop, cfg)
    print("Пакеты: " + ", ".join(packs) + (f" (не найдены: {', '.join(missing)})" if missing else ""))
    reading = ["methods/measurement.md (чек-лист)", "methods/canary.md (чек-лист)",
               "methods/tests.md (чек-лист)", "specs/round.md"]
    for name, pk in packs.items():
        for k in ("measure", "canary", "tests"):
            if k in pk["files"]:
                reading.append(str(pk["files"][k].relative_to(SKILL_ROOT)) if SKILL_ROOT in pk["files"][k].parents
                               else str(pk["files"][k]))
    reading.append("`loop.py review` — промпт рецензента с вопросами пакетов")
    if kind == "линза":
        ent = data["lenses"][tid]
        f = ent["fields"]
        print(f"Линза: {ent['path'].relative_to(root)}")
        print(f"  Статус: {f.get('Статус', '')}")
        print(f"  Пути: {f.get('Пути', '')}")
        print(f"  Детектор: {f.get('Детектор', '')[:200]}")
        if SCRIPT_RE.match(f.get("Детектор", "").strip()):
            print(f"  Свип — скриптом: python3 scripts/loop.py sweep {tid}")
        lens_paths = split_list(f.get("Пути", ""))
        matches = []
        for pid, pe in data["probes"].items():
            if not pe["fields"].get("Статус", "").startswith("валиден"):
                continue
            ppaths = split_list(pe["fields"].get("Пути", ""))
            if any(_overlap(a, b_) for a in lens_paths for b_ in ppaths):
                matches.append(f"{pid} ({pe['fields'].get('Файл', '')}) — {pe['h1'][2:]}")
        if matches:
            print("Валидные стенды по тем же путям — начинать с них, не строить новый:")
            for m_ in matches:
                print(f"  {m_}")
        else:
            print("Валидных стендов по этим путям нет — новый стенд регистрировать как P-NN после валидации контролем")
        if f.get("Уточняет", "").strip() not in EMPTY:
            reading.append(f"catalog/{f['Уточняет'].strip()}-*.md")
    elif kind == "решение владельца":
        ent = data["backlog"][tid]
        print(f"Зацепка: {ent['path'].relative_to(root)}")
        print(f"  Решение владельца: {ent['fields'].get('Решение владельца', '')}")
        print("  Линза для записи раунда — та, что породила зацепку (см. её ссылки)")
    else:
        ent = data["backlog"][tid]
        print(f"Зацепка: {ent['path'].relative_to(root)}")
        print(f"  Причина: {ent['fields'].get('Причина', '')}")
        reading.append("catalog/U-21-remeasure-own-deferrals.md")
    active = [l for l, e in data["lessons"].items() if e["fields"].get("Статус", "").startswith("действует")]
    if active:
        print(f"Уроки, которые действуют ({len(active)}): lessons/LESSONS.md")
    print("Читать: " + "; ".join(reading))
    return 0


def _overlap(a: str, b: str) -> bool:
    """Грубое пересечение двух глобов: общие первые два сегмента пути."""
    sa = [s for s in a.split("/") if s and s not in ("**", "*")][:2]
    sb = [s for s in b.split("/") if s and s not in ("**", "*")][:2]
    return bool(sa) and bool(sb) and sa[: len(sb)] == sb[: len(sa)]


# ---------------------------------------------------------------- stale

def cmd_stale(root: Path, loop: Path) -> int:
    if not loop.is_dir():
        print(f"нет {loop} — данные не развёрнуты")
        return 1
    if git(root, "rev-parse", "--git-dir") is None:
        print("нет git — старение не посчитать")
        return 1
    data = load(loop)
    rows: list[tuple[str, str, str, list[str] | None, str]] = []

    cfg = parse_config(loop)
    packs, _ = load_packs(loop, cfg)
    for lid, ent in data["lenses"].items():
        st = ent["fields"].get("Статус", "")
        m = SWEPT_RE.match(st)
        if not m:
            continue
        paths = split_list(ent["fields"].get("Пути", ""))
        changed = changed_files(root, m.group(2), paths) if paths else []
        note = ""
        if m.group(3):
            res = run_detector(root, loop, packs, ent["fields"].get("Детектор", ""))
            if res is None:
                note = "скрипт детектора не найден"
            elif res[1] != m.group(3):
                note = f"список экземпляров изменился: свип {m.group(3)} -> {res[1]}, экземпляров {len(res[0])}"
                changed = (changed or []) + [f"[детектор] {l}" for l in res[0][:3]]
            else:
                note = "список экземпляров тот же"
        rows.append(("свип", lid, m.group(2), changed, note))
    for kind, label in (("backlog", "зацепка"), ("checked", "негатив"),
                        ("probes", "стенд"), ("lessons", "урок")):
        for iid, ent in data[kind].items():
            f = ent["fields"]
            if kind == "backlog" and not f.get("Статус", "").startswith(("открыта", "ждёт")):
                continue
            if kind == "probes" and not f.get("Статус", "").startswith("валиден"):
                continue
            if kind == "lessons" and (not f.get("Статус", "").startswith("действует")
                                      or f.get("Пути", "").strip() in EMPTY):
                continue
            sm = SHA_RE.search(f.get("Коммит", ""))
            paths = split_list(f.get("Пути", ""))
            if not sm:
                rows.append((label, iid, "—", None, ""))
                continue
            rows.append((label, iid, sm.group(0), changed_files(root, sm.group(0), paths) if paths else [], ""))

    stale_n = 0
    for label, iid, sha, changed, note in rows:
        suffix = f" — {note}" if note else ""
        if changed is None:
            print(f"{label:8} {iid:10} sha {sha}: не найден или не задан — старение не посчитать")
        elif changed:
            stale_n += 1
            head = ", ".join(changed[:5]) + (" …" if len(changed) > 5 else "")
            print(f"{label:8} {iid:10} УСТАРЕЛ: {len(changed)} с {sha[:8]}: {head}{suffix}")
        else:
            print(f"{label:8} {iid:10} свеж: по путям изменений с {sha[:8]} нет{suffix}")
    print(f"stale: {stale_n} из {len(rows)} записей устарели")

    # директории, не покрытые ни одной линзой
    tracked = (git(root, "ls-files") or "").splitlines()
    globs = [p for ent in data["lenses"].values()
             for p in split_list(ent["fields"].get("Пути", ""))]
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
            print("Директории без единой линзы (повод перепройти вывод набора):")
            for d in uncovered:
                print(f"  {d}/  ({dirs[d][0]} файл(ов))")
    return 0


# ---------------------------------------------------------------- catalog / review / sweep

def cmd_catalog(root: Path, loop: Path) -> int:
    cfg = parse_config(loop)
    packs, missing = load_packs(loop, cfg)
    if missing:
        print(f"не найдены пакеты: {', '.join(missing)}")
    print("Пакеты: " + ", ".join(packs))
    print("Классы ущерба: " + ", ".join(damage_classes(packs, cfg)))
    forms = catalog_forms(loop, packs)
    enabled = [(uid, pk, f) for uid, pk, f in forms if pk in packs]
    skipped = [(uid, pk) for uid, pk, f in forms if pk not in packs]
    print(f"Формы для инстанцирования ({len(enabled)}):")
    for uid, pk, f in enabled:
        h = h1(f.read_text())[2:]
        print(f"  {h}  [{pk}]  {f}")
    if skipped:
        print("Вне подключённых пакетов: " + ", ".join(f"{u} ({p})" for u, p in skipped))
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
        idx = next((i for i, l in enumerate(lines) if l.startswith("Итог")), len(lines))
        lines[idx:idx] = ["", *extra, ""]
        core = "\n".join(lines) + "\n"
    print(core, end="")
    return 0


def run_detector(root: Path, loop: Path, packs: dict, det: str) -> tuple[list[str], str] | None:
    m = SCRIPT_RE.match(det.strip())
    if not m:
        return None
    script = resolve_script(loop, packs, m.group(1))
    if script is None:
        return None
    args = m.group(2).split()
    cmd = ["python3", str(script), *args] if script.suffix == ".py" else [str(script), *args]
    out = subprocess.run(cmd, cwd=root, capture_output=True, text=True, check=False)
    lines = sorted(l for l in out.stdout.splitlines() if l.strip())
    import hashlib
    digest = hashlib.sha1("\n".join(lines).encode()).hexdigest()[:8]
    return lines, digest


def cmd_sweep(root: Path, loop: Path, lens_id: str | None) -> int:
    if not lens_id:
        print("укажи ID линзы: loop.py sweep RPC-01")
        return 1
    data = load(loop)
    cfg = parse_config(loop)
    packs, _ = load_packs(loop, cfg)
    ent = data["lenses"].get(lens_id)
    if not ent:
        print(f"линза {lens_id} не найдена")
        return 1
    det = ent["fields"].get("Детектор", "")
    res = run_detector(root, loop, packs, det)
    if res is None:
        print(f"{lens_id}: детектор не скрипт (`script: путь`) или скрипт не найден — свип вручную по описанию:")
        print("  " + det)
        return 1
    lines, digest = res
    for l in lines:
        print(l)
    print(f"экземпляров: {len(lines)}, свип {digest} — в статус линзы: "
          f"`исчерпана здесь (раунд NNN, <sha>, свип {digest})`")
    return 0


# ---------------------------------------------------------------- init

CONFIG_TEMPLATE = """# Настройки цикла

Схема — `specs/config.md` в скилле. Три места ниже читает `loop.py`, их формат
точный: строка `unattended:`, блок ```gate, три строки «Бюджета раунда».

## Режим

unattended: no

## Пакеты

Подключённые пакеты знаний из `packs/` скилла или `.claude/loop/packs/`;
`core` подключён всегда. Свои классы ущерба — через запятую, необязательно.

пакеты: core
классы ущерба:

## Тулчейн

<чем запускать сборку и тесты; обёртки для закреплённой версии SDK; известные
ловушки запуска и их безопасные формы>

## Гейт

Точная последовательность до коммита, по одной команде на строку:

```gate
<команда 1>
<команда 2>
```

## Пробы

<куда класть и почему туда: разрешение импортов, исключение из анализа, игнор в git>

## После коммита

Команды unattended-запуска после успешного коммита раунда (push, уведомление);
пусто — ничего. Покрываются permissions.allow так же, как гейт.

```after-commit
```

## Бюджет раунда

пробы: 3
канарейки: 2
потолок раундов: 30

## Цели, которые никто не гоняет

<другой компилятор, нативный слой, устройства, генераторы — команда и что находит>

## Планка серьёзности

<какие классы ущерба достойны раунда сейчас>

## Вне области

<что не является целью цикла>

## Постоянные требования владельца

<то, что действует в каждом раунде>

## Известные флейки

<поимённо; пусто — так и написать>
"""

LOOP_TEMPLATE = """# LOOP.md — карта данных цикла улучшений

Данные измеряемого цикла поиска и починки дефектов; правила — в скилле
`improvement-loop` (SKILL.md, specs/, methods/). Здесь только навигация.

## Четыре сущности

- **Линза** — генератор гипотез: что искать и как. `lenses/`, оглавление `lenses/LENSES.md`.
- **Раунд** — что было измерено, починено и с каким вердиктом. `rounds/`, оглавление `rounds/ROUNDS.md`.
- **Зацепка** — недоделанное: отсрочка, ожидание владельца, стенд без числа. `backlog/`, оглавление `backlog/BACKLOG.md`.
- **Негатив** — измерено, чисто, делать нечего. `checked/`, оглавление `checked/CHECKED.md`.
- **Стенд** — проба, чей контроль доказал, что она видит дефект; переиспользуется. `probes/`, оглавление `probes/PROBES.md`.
- **Урок** — правило работы с этим кодом, за которое раунд заплатил. `lessons/`, оглавление `lessons/LESSONS.md`.

## Кто на кого ссылается

```mermaid
flowchart LR
    R[раунд] -->|Линза:| L[линза]
    L -->|Применена:| R
    R -->|Стенд:| P[стенд]
    B[зацепка] -->|Раунд:| R
    C[негатив] -->|Раунд:| R
    P -->|Раунд:| R
    S[урок] -->|Раунд:| R
    R -->|Связи:| B
    R -->|Связи:| C
```

## Куда идти с вопросом

- Прогнать раунд — скилл, режим по умолчанию; сначала `loop.py status`.
- Какой номер следующего раунда — `loop.py status` (максимум в `rounds/` плюс один).
- Это уже проверяли? — `checked/CHECKED.md` и статусы линз `исчерпана здесь`.
- Откуда взялось утверждение — по ID: `grep -rn "<ID>" .claude/loop/`.
- Что ждёт владельца — `loop.py status`; ответить: вписать текст в поле
  `Решение владельца:` файла зацепки, статус не менять.
- Что устарело относительно кода — `loop.py stale`.
- Какую цель взять следующему раунду — `loop.py next`.
- Есть ли готовый стенд для этой поверхности — `probes/PROBES.md` или `loop.py next`.
- Чему научились на этом коде — `lessons/LESSONS.md`.

## Чему верить с оглядкой

<заполнить при развёртывании: невосстановленная история, записи «не
перепроверено», непрогнанные детекторы, набор линз не проверен раундом>
"""

INDEX_TITLES = {
    "lenses": "Набор линз проекта — что искать и как; порядок строк это ранг",
    "rounds": "Журнал раундов — от нового к старому",
    "backlog": "Зацепки — недоделанное; порядок строк это ранг",
    "checked": "Негативы — измерено чисто, делать нечего",
    "probes": "Стенды — пробы, чей контроль доказал, что они видят дефект",
    "lessons": "Уроки — оплаченные раундом правила работы с этим кодом",
}


def cmd_init(root: Path, loop: Path) -> int:
    if loop.exists():
        print(f"{loop} уже есть — развёртывание поверх данных не делается")
        return 1
    loop.mkdir(parents=True)
    (loop / "LOOP.md").write_text(LOOP_TEMPLATE)
    (loop / "config.md").write_text(CONFIG_TEMPLATE)
    for kind, index_name in DIRS.items():
        (loop / kind).mkdir()
        (loop / kind / index_name).write_text(
            f"# {INDEX_TITLES[kind]}\n\nПравила и связи — [../LOOP.md](../LOOP.md).\n\n")
    print(f"развёрнуто: {loop}")
    print("дальше: заполнить config.md по specs/config.md, разрешения в "
          ".claude/settings.json, режим lenses, затем loop.py lint")
    return 0


# ---------------------------------------------------------------- main

def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["init", "status", "next", "lint", "stale", "catalog", "review", "sweep"])
    ap.add_argument("arg", nargs="?", help="ID линзы для sweep")
    ap.add_argument("--root", default=".", help="корень репозитория (по умолчанию текущая директория)")
    ap.add_argument("--loop", default=".claude/loop", help="путь к данным цикла относительно корня")
    a = ap.parse_args(argv)
    root = Path(a.root).resolve()
    loop = (root / a.loop).resolve()
    if a.command == "sweep":
        return cmd_sweep(root, loop, a.arg)
    return {"init": cmd_init, "status": cmd_status, "next": cmd_next, "lint": cmd_lint,
            "stale": cmd_stale, "catalog": cmd_catalog, "review": cmd_review}[a.command](root, loop)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(0)
