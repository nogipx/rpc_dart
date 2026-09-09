#!/usr/bin/env python3
"""Detector for U-01: comments justifying deliberateness.

Prints one instance per line: path:line: text. Run from the repository root; the
argument is the directories to walk (the current one by default). The detector
protocol: the instance list on stdout, exit code 0. This is an example; for a
particular project the detector is instantiated in a lens with its own words and
paths.
"""
import os
import re
import sys

WORDS = re.compile(
    r"(намеренно|нарочно|специально|иначе|вместо того|а не |intentionally|deliberately|"
    r"on purpose|instead of|rather than|otherwise|would break|to avoid)", re.I)
COMMENT = re.compile(r"(//|#|/\*|\*|<!--)\s*(.*)")
SKIP_DIRS = {".git", "node_modules", "build", ".dart_tool", ".claude", "dist", "target"}
EXTS = (".dart", ".py", ".ts", ".js", ".kt", ".swift", ".go", ".rs", ".java", ".rb", ".c", ".cc", ".cpp", ".h")

def main(roots):
    for root in roots:
        for d, dirs, files in os.walk(root):
            dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
            for fn in files:
                if not fn.endswith(EXTS):
                    continue
                path = os.path.join(d, fn)
                try:
                    with open(path, encoding="utf-8", errors="replace") as fh:
                        for n, line in enumerate(fh, 1):
                            m = COMMENT.search(line)
                            if m and WORDS.search(m.group(2)):
                                print(f"{path}:{n}: {m.group(2).strip()[:120]}")
                except OSError:
                    continue
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or ["."]))
