#!/usr/bin/env python3
"""sweep_classes.py — the engine behind tools/sweep-classes.sh.

One rule per defect class in this project's history. Every rule resolves the
CLASS of what it looks at (a comment from code, a definition from a call, a
sourced file from an executed one), because a detector that cries is worse
than no detector.

Each rule is listed in RULES below with the symptom it prevents.
"""
import re
import sys
from pathlib import Path

RULES = [
    ("R01", "consumer of os/_common.sh or os/_paths.sh that cannot point at the shared library",
     "a sourced file resolved its siblings by $0, so the library was looked up in the wrong directory"),
    ("R02", "shell variable spliced into python source code",
     "a project path with a quote or a newline broke the parse, and the empty result was reported as something else"),
    ("R03", "shift N without an arity guard",
     "shift 2 with fewer than two arguments does not advance the list, so the parse loop spun forever"),
    ("R04", "python whose exit status is lost inside a pipeline",
     "a parse failure read as an empty list with rc 0 (the pool then said 'max ordinal 0' and reused [01])"),
    ("R05", "dangling pipe ('; true |')",
     "the status was swallowed by a `true` and the pipe transformed nothing"),
    ("R06", "function defined and never called",
     "dead code drifts away from the code around it"),
    ("R07", "unquoted heredoc whose body is python",
     "shellcheck parses the body as shell and reports a bogus error (the lint gate went red on 5 pushes)"),
    ("R08", "version incoherent between the three public sources",
     "the skill_version, the README badge and the README.es badge drifted apart"),
    ("R09", "README.md and README.es.md out of mirror",
     "the Spanish mirror was not in the scope of a fix and kept the old badge, the old snapshot and the old wording"),
    ("R10", "count in the prose that does not match the tree",
     "a fixed number in the docs went stale the moment the tree changed"),
    ("R11", "curl invoked with the AUTH flag quoted",
     "curl took '-u opencode:<password>' as one token with a space inside and answered 401"),
    ("R12", "raw python whose output the shell reads",
     "on Windows every value read from python carried a stray CR and corrupted the comparison"),
]


def _read(path):
    """UTF-8 explicitly: the default encoding is the locale's, and on the
    Windows runner that is not UTF-8 (the files carry accents)."""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def shipped_files(root):
    """The closed list in package.sh IS the source of truth for what ships."""
    pkg = root / "SKILL/scripts/package.sh"
    text = _read(pkg)
    block = text.split("PACKAGE_FILES='", 1)[1].split("'", 1)[0]
    return [ln.strip() for ln in block.splitlines() if ln.strip()]


def strip_comment(line):
    """Remove a trailing shell comment, respecting quotes."""
    out, quote = [], None
    i = 0
    while i < len(line):
        ch = line[i]
        if quote:
            out.append(ch)
            if ch == quote and (i == 0 or line[i - 1] != "\\"):
                quote = None
        elif ch in "'\"":
            quote = ch
            out.append(ch)
        elif ch == "#" and (not out or out[-1] in " \t"):
            break
        else:
            out.append(ch)
        i += 1
    return "".join(out)


def code_lines(text):
    """[(lineno, code)] without comments and without blank lines."""
    res = []
    for n, ln in enumerate(text.splitlines(), 1):
        c = strip_comment(ln).strip()
        if c:
            res.append((n, c))
    return res


def _block_end(lines, i, q):
    """The line that closes the python block opened at lines[i].

    Three shapes exist in this codebase:
      ' 2>/dev/null)          the quote opens the line
      " "$PROJ_DIR") || ...   the quote opens the line (argv after it)
      print("?")' 2>/dev/null) the quote closes mid-line (inline-start form)
    """
    for j in range(i + 1, len(lines)):
        s = lines[j].strip()
        if s.startswith("'") or s.startswith('"'):
            return j
        if re.search(r"['\"]\s*(2>/dev/null|\|\||\|)", s):
            return j
    return len(lines)


def py_blocks(text):
    """[(start_line, end_line, body, first_line, command)] for every `py -c` block."""
    lines = text.splitlines()
    blocks = []
    for i, ln in enumerate(lines):
        m = re.search(r"\b(py|python3)\s+-c\s+(['\"])", ln)
        if not m:
            continue
        cmd = m.group(1)
        q = m.group(2)
        rest = ln[m.end():]
        if q in rest:  # the whole block is on one line
            blocks.append((i + 1, i + 1, rest[:rest.index(q)], ln, cmd))
            continue
        j = _block_end(lines, i, q)
        blocks.append((i + 1, j + 1, "\n".join(lines[i + 1:j + 1]), ln, cmd))
    return blocks


def rule_r01(root, shipped, repo_files):
    """A consumer of the shared library must be able to point at it.

    An EXECUTED file may use its own $0. A SOURCED file cannot ($0 is the
    caller's path), so it must export SELF_DIR. A consumer that meets neither
    is the shape that broke the CI: the library was looked up in /usr/bin.
    """
    hits = []
    consumers = []
    for rel, text in repo_files.items():
        if not re.search(r"^\s*\.\s+.*(?:_common|_paths)\.sh", text, re.M):
            continue
        consumers.append(rel)
    # which shell files are SOURCED by another file?
    sourced = set()
    for rel, text in repo_files.items():
        for other, otext in repo_files.items():
            if other == rel or not other.endswith(".sh"):
                continue
            base = Path(rel).name
            if re.search(r"^\s*(?:\.|source)\s+[^\n]*" + re.escape(base), otext, re.M):
                sourced.add(rel)
    for rel in consumers:
        text = repo_files[rel]
        lines = text.splitlines()
        for m in re.finditer(r"^\s*\.\s+([^\n]*?(?:_common|_paths)\.sh[^\n]*)$", text, re.M):
            lineno = text[:m.start()].count("\n") + 1
            src = m.group(1)
            before = "\n".join(lines[:lineno - 1])
            # SELF_DIR must be set to a NON-EMPTY value: SELF_DIR="" points at
            # nothing, which is the same as not setting it at all.
            uses_self_dir = re.search(r'\bSELF_DIR="?[^"\s]', before) is not None
            own_path = "dirname" in src and "$0" in src
            executed = rel.endswith(".sh") and rel not in sourced
            if uses_self_dir:
                continue
            if own_path and executed:
                continue
            hits.append((f"{rel}:{lineno}",
                         f"sources {src.strip()} without exporting SELF_DIR"))
    return hits


def rule_r02(root, shipped, repo_files):
    hits = []
    for rel in shipped:
        text = repo_files.get(f"SKILL/{rel}") or ""
        for start, end, body, first, _cmd in py_blocks(text):
            for n, bl in enumerate(body.splitlines(), start + 1):
                if re.search(r"'\"\s*\$\{?[A-Za-z_]", bl):
                    hits.append((f"SKILL/{rel}:{n}", bl.strip()[:70]))
    return hits


def rule_r03(root, shipped, repo_files):
    hits = []
    for rel in shipped:
        text = repo_files.get(f"SKILL/{rel}") or ""
        lines = text.splitlines()
        for n, ln in enumerate(lines, 1):
            if not re.search(r"\bshift\s+[2-9]\b", ln):
                continue
            if ln.strip().startswith("#"):
                continue
            ctx = "\n".join(lines[max(0, n - 5):n])
            if "assert_value" in ln or re.search(r"\[\s*\$\#\s*-ge\s*[2-9]\s*\]", ctx):
                continue
            hits.append((f"SKILL/{rel}:{n}", ln.strip()[:70]))
    return hits


def rule_r04(root, shipped, repo_files):
    """The python's status is lost when the pipeline continues past it."""
    hits = []
    for rel in shipped:
        key = f"SKILL/{rel}"
        text = repo_files.get(key) or ""
        lines = text.splitlines()
        for start, end, body, first, _cmd in py_blocks(text):
            if end >= len(lines):
                continue
            rest = lines[end - 1]
            # only the text AFTER the block matters: a pipe BEFORE the python
            # is the normal way to feed it, and the python then owns the
            # status of the pipeline.
            tail = rest[rest.rfind("'"):] if end == start else rest
            # a SINGLE pipe after the block means the pipeline continues past
            # the python: the pipeline's status is the LAST command's, so the
            # python's status is lost. A `||` after it does NOT recover it
            # (it guards the pipeline, not the python).
            if re.search(r"(?<!\|)\|(?!\|)", tail):
                hits.append((f"{key}:{end}", rest.strip()[:70]))
    return hits


def rule_r05(root, shipped, repo_files):
    """`; true |` swallows a status AND leaves the pipe hanging off nothing."""
    hits = []
    for rel in shipped:
        key = f"SKILL/{rel}"
        for n, ln in code_lines(repo_files.get(key) or ""):
            if re.search(r";\s*(true|:)\s*\|", ln):
                hits.append((f"{key}:{n}", ln[:70]))
    return hits


def rule_r06(root, shipped, repo_files):
    """A function that is defined and never called: dead code."""
    hits = []
    defs, calls = {}, {}
    for rel in shipped:
        key = f"SKILL/{rel}"
        text = repo_files.get(key) or ""
        for n, ln in code_lines(text):
            m = re.match(r"^([a-z_][a-z0-9_]*)\(\)\s*\{", ln)
            own = m.group(1) if m else None
            if own:
                defs.setdefault(own, []).append(f"{key}:{n}")
            for name in re.findall(r"(?<![\w-])([a-z_][a-z0-9_]*)(?![\w(])", ln):
                if name == own:
                    continue  # the definition itself is not a call
                calls[name] = calls.get(name, 0) + 1
    for name, places in sorted(defs.items()):
        if calls.get(name, 0) == 0:
            for p in places:
                hits.append((p, name))
    return hits


def rule_r07(root, shipped, repo_files):
    hits = []
    heredoc = re.compile(r"<<-?\s*([A-Za-z_][A-Za-z0-9_]*)")
    for rel in shipped:
        key = f"SKILL/{rel}"
        text = repo_files.get(key) or ""
        lines = text.splitlines()
        i = 0
        while i < len(lines):
            m = heredoc.search(lines[i])
            if not m:
                i += 1
                continue
            delim = m.group(1)
            start = m.start(1)
            quoted = bool(start and lines[i][start - 1] in "'\"")
            body, j = [], i + 1
            while j < len(lines) and lines[j].strip() != delim:
                body.append(lines[j])
                j += 1
            if not quoted and any(re.search(r"^\s*(import |from \w+ import )", b) for b in body):
                hits.append((f"{key}:{i + 1}", f"unquoted heredoc '{delim}' with a python body"))
            i = j + 1
    return hits


def rule_r08(root, shipped, repo_files):
    hits = []
    front = repo_files.get("SKILL/SKILL.md", "")
    m = re.search(r'skill_version:\s*"([0-9.]+)"', front)
    en = re.search(r"release-([0-9.]+)", repo_files.get("README.md", ""))
    es = re.search(r"versi.n-([0-9.]+)", repo_files.get("README.es.md", ""))
    vals = {"SKILL.md": m.group(1) if m else None,
            "README.md": en.group(1) if en else None,
            "README.es.md": es.group(1) if es else None}
    if len(set(vals.values())) != 1:
        hits.append(("version", ", ".join(f"{k}={v}" for k, v in vals.items())))
    return hits


def rule_r09(root, shipped, repo_files):
    def profile(t):
        return (len(re.findall(r"^## ", t, re.M)), len(re.findall(r"^### ", t, re.M)),
                t.count("```"), len(re.findall(r"\]\([^)]+\)", t)),
                len([l for l in t.splitlines() if l.startswith("|")]))
    en = profile(repo_files.get("README.md", ""))
    es = profile(repo_files.get("README.es.md", ""))
    names = ("h2", "h3", "fences", "links", "rows")
    hits = []
    for name, a, b in zip(names, en, es):
        if a != b:
            hits.append((name, f"README.md={a} README.es.md={b}"))
    return hits


def rule_r10(root, shipped, repo_files):
    """A count in the CURRENT documentation that does not match the tree.

    The CHANGELOG is a dated record: its historical sections state what was
    true then, so they are not checked. The current docs (READMEs, SKILL.md,
    references/) must match the tree.
    """
    hits = []
    orch = repo_files.get("SKILL/scripts/orchestrate.sh", "")
    n_sub = len(re.findall(r"^  ([a-z][a-z0-9-]*)\)\s+sub_", orch, re.M))
    n_refs = len([f for f in shipped if f.startswith("references/") and f.endswith(".md")])
    n_words = len(repo_files.get("SKILL/SKILL.md", "").split())
    for name, text in repo_files.items():
        if not (name.startswith("README") or name.startswith("SKILL/references/")):
            continue
        for n, ln in enumerate(text.splitlines(), 1):
            for num, kind in re.findall(r"(\d+)\s+(subcomandos|subcommands|referencias|references|palabras|words)\b", ln):
                if kind in ("subcomandos", "subcommands") and int(num) != n_sub:
                    hits.append((f"{name}:{n}", f"claims {num} subcommands, the dispatch has {n_sub}"))
                if kind in ("referencias", "references") and int(num) != n_refs:
                    hits.append((f"{name}:{n}", f"claims {num} references, the tree has {n_refs}"))
                if kind in ("palabras", "words") and int(num) != n_words:
                    hits.append((f"{name}:{n}", f"claims {num} words, SKILL.md has {n_words}"))
    return hits


def rule_r11(root, shipped, repo_files):
    hits = []
    for rel in shipped:
        key = f"SKILL/{rel}"
        for n, ln in code_lines(repo_files.get(key) or ""):
            if "curl" in ln and re.search(r'"\$?\{?AUTH\}?"', ln):
                hits.append((f"{key}:{n}", ln[:70]))
    return hits


def rule_r12(root, shipped, repo_files):
    """A RAW python (not the `py` helper) whose output the shell reads.

    On Windows a text-mode print() ends the line with CRLF and the shell
    reads the CR as part of the value. `py` is the ONE way to read python's
    output safely; a raw `python3` that the shell captures is the class.
    A python that writes BINARY (sys.stdout.buffer.write) is fine.
    """
    hits = []
    for rel in shipped:
        key = f"SKILL/{rel}"
        text = repo_files.get(key) or ""
        for start, end, body, first, cmd in py_blocks(text):
            if cmd != "python3":
                continue  # `py` IS the safe wrapper
            if "stdout.buffer.write" in body:
                continue
            captured = re.search(r"=\$\(", first) is not None
            redirected = re.search(r"python3[^\n]*>\s*\"?\$", first) is not None
            if captured or redirected:
                hits.append((f"{key}:{start}", first.strip()[:70]))
    return hits


DETECTORS = [
    ("R01", rule_r01), ("R02", rule_r02), ("R03", rule_r03), ("R04", rule_r04),
    ("R05", rule_r05), ("R06", rule_r06), ("R07", rule_r07), ("R08", rule_r08),
    ("R09", rule_r09), ("R10", rule_r10), ("R11", rule_r11), ("R12", rule_r12),
]


def collect_repo_files(root):
    out = {}
    for p in sorted(root.rglob("*")):
        if not p.is_file() or ".git" in p.parts:
            continue
        rel = p.relative_to(root).as_posix()
        if not (rel.endswith(".sh") or rel.endswith(".md") or rel.endswith(".yml")
                or rel.endswith(".awk") or rel.endswith(".yaml")):
            continue
        if rel.startswith(("runs/", "RSI_LOG", ".agents/", "SKILL/scripts/evals/")):
            continue
        try:
            out[rel] = _read(p)
        except OSError:
            pass
    return out


def main(argv):
    if "--list" in argv:
        for rid, what, why in RULES:
            print(f"{rid}  {what}\n      prevents: {why}")
        return 0
    root = Path(argv[argv.index("--root") + 1]).resolve() if "--root" in argv else Path.cwd()
    shipped = shipped_files(root)
    repo_files = collect_repo_files(root)
    # the maintainer-internal fixtures are consumers too: they must honour the
    # same contract, otherwise the net that guards the classes is itself broken
    for p in sorted((root / "SKILL/scripts/evals").rglob("*")):
        if p.is_file() and p.suffix in (".sh",):
            repo_files[p.relative_to(root).as_posix()] = p.read_text()
    total = 0
    for rid, fn in DETECTORS:
        hits = fn(root, shipped, repo_files)
        if hits:
            total += len(hits)
            print(f"[OPEN] {rid}: {len(hits)} hit(s)")
            for where, why in hits:
                print(f"         {where}  {why}")
    if total == 0:
        print("sweep-classes: every class is closed (0 hits)")
        return 0
    print(f"sweep-classes: {total} hit(s): at least one class is OPEN")
    return 1


# --------------------------------------------------------------------------
# SELFTEST: a guard that has never been seen to fail is a hypothesis.
# Each rule is proved by introducing its defect into a COPY of the tree and
# checking that the rule fires (and that the clean tree does not fire it).
# --------------------------------------------------------------------------

def _write(path, text):
    """Write with LF line endings on every platform.

    Without this, a mutation on Windows would rewrite the file with CRLF and
    the detectors would read a file that no longer matches the tree.
    """
    with open(path, "w", newline="\n", encoding="utf-8") as fh:
        fh.write(text)


def _sub(path, old, new, count=1):
    p = Path(path)
    s = _read(p)
    if old not in s:
        raise AssertionError(f"mutation target not found in {path}: {old[:40]!r}")
    _write(p, s.replace(old, new, count))


def _resub(path, pattern, repl, count=1):
    """Regex mutation: it must not depend on the CURRENT version or count."""
    p = Path(path)
    s = _read(p)
    new, n = re.subn(pattern, repl, s, count=count)
    if n == 0:
        raise AssertionError(f"mutation pattern not found in {path}: {pattern!r}")
    _write(p, new)


def _append(path, text):
    with open(path, "a", newline="\n", encoding="utf-8") as fh:
        fh.write(text)


MUTATIONS = {
    "R01": lambda c: _sub(c / "SKILL/scripts/preflight.sh",
                          'SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)',
                          'SELF_DIR=""'),
    "R02": lambda c: _sub(c / "SKILL/scripts/orchestrate.sh",
                          'proj = os.environ["PROJ_DIR"]',
                          "proj = \"'\"$PROJ_DIR\"'\""),
    "R03": lambda c: _append(c / "SKILL/scripts/orchestrate.sh", "\nshift 2\n"),
    "R04": lambda c: _sub(c / "SKILL/scripts/os/_common.sh",
                          '" "$PROJ_DIR") || return 3', '" "$PROJ_DIR" | cat) || return 3'),
    "R05": lambda c: _append(c / "SKILL/scripts/orchestrate.sh",
                             "\nX=$(echo hi 2>/dev/null; true | tr 'a' 'b')\n"),
    "R06": lambda c: _append(c / "SKILL/scripts/os/_common.sh",
                             "\nzz_never_called_helper() { :; }\n"),
    "R07": lambda c: _append(c / "SKILL/scripts/os/_common.sh",
                             "\ncat <<EOF\nimport json\nprint(1,\nEOF\n"),
    "R08": lambda c: _resub(c / "README.md", r"release-[0-9.]+", "release-9.9.9"),
    "R09": lambda c: _append(c / "README.es.md", "\n## Seccion solo en espanol\n"),
    "R10": lambda c: _resub(c / "README.md", r"[0-9]+ subcommands", "99 subcommands"),
    "R11": lambda c: _append(c / "SKILL/scripts/preflight.sh",
                             '\ncurl -s "$AUTH" http://example.invalid\n'),
    "R12": lambda c: _append(c / "SKILL/scripts/os/_common.sh",
                             "\n_x=$(python3 -c 'print(1)')\n"),
}


def _copy_tree(root, dest):
    import shutil
    dest.mkdir(parents=True, exist_ok=True)
    shutil.copytree(root / "SKILL", dest / "SKILL", dirs_exist_ok=True)
    for f in ("README.md", "README.es.md", "CHANGELOG.md"):
        if (root / f).exists():
            shutil.copy(root / f, dest / f)
    if (root / ".github").exists():
        shutil.copytree(root / ".github", dest / ".github", dirs_exist_ok=True)


def _load(root):
    shipped = shipped_files(root)
    repo_files = collect_repo_files(root)
    evals = root / "SKILL/scripts/evals"
    if evals.is_dir():
        for p in sorted(evals.rglob("*")):
            if p.is_file() and p.suffix == ".sh":
                repo_files[p.relative_to(root).as_posix()] = _read(p)
    return shipped, repo_files


def selftest(root):
    import tempfile
    failures = []
    for rid, fn in DETECTORS:
        # 1. the clean tree must NOT fire
        shipped, repo_files = _load(root)
        clean_hits = fn(root, shipped, repo_files)
        if clean_hits:
            failures.append(f"{rid}: fires on the CLEAN tree: {clean_hits[:2]}")
            continue
        # 2. the tree with the defect introduced MUST fire
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp) / "tree"
            _copy_tree(root, copy)
            MUTATIONS[rid](copy)
            s2, r2 = _load(copy)
            dirty_hits = fn(copy, s2, r2)
            if not dirty_hits:
                failures.append(f"{rid}: did NOT fire with its defect introduced")
            else:
                print(f"[PROVED] {rid}: fires with the defect introduced "
                      f"({dirty_hits[0][0]})")
    if failures:
        print()
        for f in failures:
            print(f"[FAIL]   {f}")
        print(f"selftest: {len(failures)} rule(s) are not trustworthy")
        return 1
    print("selftest: every rule is trustworthy (proved with its own defect)")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        r = Path(sys.argv[sys.argv.index("--root") + 1]).resolve() if "--root" in sys.argv else Path.cwd()
        sys.exit(selftest(r))
    sys.exit(main(sys.argv[1:]))
