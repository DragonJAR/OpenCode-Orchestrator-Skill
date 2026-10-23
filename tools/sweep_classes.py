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
    ("R13", "bash-only construct in a script that declares POSIX sh",
     "the CI only linted in bash mode, so a bashism reached a dash runner and broke there only"),
    ("R14", "the JSON offset formula outside the shared library",
     "the same extraction was written four times and the copies had already drifted"),
    ("R15", "a JSON parse that refuses control characters inside strings",
     "the serve emits a literal newline inside a JSON string and the parse failed"),
    ("R16", "the CI using a file that is not published",
     "a fixture under runs/ is gitignored, so the checkout the CI sees never had it"),
    ("R17", "the same function body in two shipped files",
     "a copy that answers a different question answers it wrong somewhere"),
    ("R18", "a random directory as a fallback for a shared path",
     "the cache split in two: preflight wrote the password into one directory and the run read from another"),
    ("R19", "a query parameter that can be empty",
     "an empty parameter is a different query: the whole catalog instead of the project's"),
    ("R20", "docs invoking bash over a #!/bin/sh script",
     "the documented command contradicts the declared POSIX compatibility"),
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


# A rule that cannot run (missing tool) returns SKIP. It is reported as
# SKIPPED, never as clean: a rule that silently watches nothing is worse
# than no rule.
SKIP = "SKIP"


def rule_r13(root, shipped, repo_files):
    """bash-only construct in a script that declares POSIX sh.

    The CI linted in bash mode, so a bashism passed every push and only
    broke on a dash runner (Linux, WSL, Alpine). The skill's own
    compatibility line promises POSIX sh + awk.

    Only the SC3xxx family counts: those are the POSIX-compatibility
    findings. The rest of the warning level is not about POSIX (the
    `CDPATH= cd` idiom trips SC1007 in every shell, and it is correct).
    """
    import shutil
    import subprocess
    sc = shutil.which("shellcheck")
    if not sc:
        return SKIP
    hits = []
    for rel in shipped:
        if not rel.endswith(".sh"):
            continue
        p = root / "SKILL" / rel
        r = subprocess.run([sc, "--shell=sh", "--severity=warning", str(p)],
                           capture_output=True, text=True)
        for ln in r.stdout.splitlines():
            m = re.search(r"\b(SC3\d{3})\b", ln)
            if m:
                hits.append((f"SKILL/{rel}", ln.strip()[:70]))
    return hits


def rule_r14(root, shipped, repo_files):
    """the JSON extraction formula outside the shared library.

    The formula lived in four files and the copies had already drifted.
    The two shapes that give it away are awk's `match(<var>, *"<key>"*)`
    and `substr(<var>, RSTART+..., RLENGTH-...)`; the title pattern in
    worker_list uses neither (its match carries a regex literal, not a
    quoted key), and python's `re.match` is not awk's `match`.
    """
    hits = []
    for rel in shipped:
        if not rel.endswith((".sh", ".awk")) or rel == "scripts/_json.awk":
            continue
        key = f"SKILL/{rel}"
        for n, ln in code_lines(repo_files.get(key) or ""):
            quoted_key = False
            for m in re.finditer(r"(?<![.\w])match\(([^,]+),\s*([^)]*)\)", ln):
                if '"' in m.group(2):
                    quoted_key = True
            rstart = re.search(r"substr\(\s*(?:RSTART|[^,]+,\s*RSTART)", ln)
            if quoted_key or rstart:
                hits.append((f"{key}:{n}", ln[:70]))
    return hits


def rule_r15(root, shipped, repo_files):
    """a JSON parse that refuses control characters inside strings.

    The serve sporadically emits a literal newline inside a JSON string
    (a title with an embedded line break): without strict=False the parse
    failed and the caller read an empty result.
    """
    hits = []
    for rel in shipped:
        if not rel.endswith(".sh"):
            continue
        key = f"SKILL/{rel}"
        lines = (repo_files.get(key) or "").splitlines()
        for i, ln in enumerate(lines):
            for m in re.finditer(r"json\.loads?\(", ln):
                window = " ".join(lines[i:i + 2])
                if "strict" not in window:
                    hits.append((f"{key}:{i + 1}", ln.strip()[:70]))
    return hits


def rule_r16(root, shipped, repo_files):
    """the CI (or the package) using a file that is not published.

    A fixture under runs/ is gitignored: the checkout the CI sees never had
    it, and the step failed on every runner.
    """
    import subprocess
    ci = root / ".github/workflows/ci.yml"
    if not ci.exists():
        return SKIP
    text = _read(ci)
    # comments are not uses: a note about a gitignored directory is fine
    code = "\n".join(re.sub(r"(?<=\s)#.*$", "", ln) if not ln.strip().startswith("#") else ""
                     for ln in text.splitlines())
    ignored = ("runs/", ".agents/", "SKILL/scripts/evals/", "RSI_LOG", "reports/")
    hits = []
    for n, ln in enumerate(code.splitlines(), 1):
        for pref in ignored:
            if pref in ln:
                hits.append((f"ci.yml:{n}", ln.strip()[:70]))
                break
    # a repo-relative path the CI uses must be tracked
    try:
        tracked = set(subprocess.run(["git", "ls-files"], cwd=root,
                                      capture_output=True, text=True).stdout.split())
    except OSError:
        return SKIP
    for m in re.finditer(r"(?:SKILL|tools|\.github)/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+", code):
        rel = m.group(0)
        if rel not in tracked:
            hits.append((f"ci.yml", f"{rel} is not tracked by git"))
    return hits


def rule_r17(root, shipped, repo_files):
    """the same function body in two shipped files (DRY).

    The per-OS adapters are excluded on purpose: each one repeats the
    same one-line delegator to the shared skeleton BY DESIGN.
    """
    import hashlib
    groups = {}
    for rel in shipped:
        if not rel.endswith(".sh"):
            continue
        key = f"SKILL/{rel}"
        text = repo_files.get(key) or ""
        name, cur = None, None
        for n, ln in enumerate(text.splitlines(), 1):
            m = re.match(r"^([a-z_][a-z0-9_]*)\(\)\s*\{", ln)
            if m:
                name = m.group(1)
                if ln.rstrip().endswith("}"):
                    # a one-line function body
                    h = hashlib.sha1(ln.encode()).hexdigest()
                    groups.setdefault((name, h), []).append(f"{key}:{n}")
                    cur = None
                else:
                    cur = [ln]
                continue
            if cur is not None:
                cur.append(ln)
                if ln.strip() == "}":
                    h = hashlib.sha1("\n".join(cur).encode()).hexdigest()
                    groups.setdefault((name, h), []).append(f"{key}:{n}")
                    cur = None
    hits = []
    for (name, _h), places in sorted(groups.items()):
        files = sorted({p.split(":")[0] for p in places})
        if len(files) > 1 and not all(f.startswith("SKILL/scripts/os/") for f in files):
            hits.append((", ".join(files), f"identical body of {name}()"))
    return hits


def rule_r18(root, shipped, repo_files):
    """a random directory as a fallback for a path two processes must share.

    The cache location is derived from the project hash so that preflight
    and orchestrate.sh agree on it; a random fallback splits the cache in
    two and the run goes unauthenticated with no error anywhere.
    """
    hits = []
    shared = re.compile(r"(CACHE|STATE|ROOT|SHARED)")
    for rel in shipped:
        if not rel.endswith(".sh"):
            continue
        key = f"SKILL/{rel}"
        for n, ln in code_lines(repo_files.get(key) or ""):
            m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=["\']?\$\(mktemp\s+-d', ln)
            if m and shared.search(m.group(1)):
                hits.append((f"{key}:{n}", ln[:70]))
    return hits


def rule_r19(root, shipped, repo_files):
    """a query parameter that can be empty.

    An empty parameter is a DIFFERENT query, not the same one: the server
    was asked for the whole catalog of the instance instead of the
    project's, and the client-side filter had to sift it.
    """
    hits = []
    for rel in shipped:
        if not rel.endswith(".sh"):
            continue
        key = f"SKILL/{rel}"
        text = repo_files.get(key) or ""
        lines = text.splitlines()
        for i, ln in enumerate(lines):
            m = re.search(r"\?[A-Za-z_]+=\$([A-Za-z_][A-Za-z0-9_]*)", ln)
            if not m:
                continue
            var = m.group(1)
            if not _var_guarded_non_empty(lines, i, var):
                hits.append((f"{key}:{i + 1}", ln.strip()[:70]))
    return hits


def _var_guarded_non_empty(lines, upto, var):
    """Is $var rejected when empty, before line `upto`?"""
    i = 0
    while i < upto:
        ln = lines[i]
        if re.search(r'\[ -n "\$' + re.escape(var) + r'" \]', ln):
            return True
        m = re.match(r'\s*case\s+"\$' + re.escape(var) + r'"\s+in\b', ln)
        if m:
            j = i + 1
            while j < len(lines) and not re.match(r"\s*esac\b", lines[j]):
                pat = lines[j].strip().split(")")[0].strip()
                # a pattern that does NOT match the empty string rejects it
                if pat and pat not in ("*", '""') and not pat.startswith("*|"):
                    return True
                j += 1
            i = j
        i += 1
    return False


def rule_r20(root, shipped, repo_files):
    """docs invoking bash over a script whose shebang is #!/bin/sh."""
    hits = []
    for name, text in repo_files.items():
        if not (name.startswith("README") or name.startswith("SKILL/references/")
                or name == "CHANGELOG.md"):
            continue
        for n, ln in enumerate(text.splitlines(), 1):
            for m in re.finditer(r"\bbash\s+(\S+\.sh)\b", ln):
                target = m.group(1)
                for cand in (root / target, root / "SKILL/scripts" / Path(target).name,
                             root / "SKILL" / target):
                    if cand.exists():
                        first = _read(cand).splitlines()
                        if first and first[0].startswith("#!/bin/sh"):
                            hits.append((f"{name}:{n}", f"{target} is #!/bin/sh"))
                        break
    return hits


DETECTORS = [
    ("R01", rule_r01), ("R02", rule_r02), ("R03", rule_r03), ("R04", rule_r04),
    ("R05", rule_r05), ("R06", rule_r06), ("R07", rule_r07), ("R08", rule_r08),
    ("R09", rule_r09), ("R10", rule_r10), ("R11", rule_r11), ("R12", rule_r12),
    ("R13", rule_r13), ("R14", rule_r14), ("R15", rule_r15), ("R16", rule_r16),
    ("R17", rule_r17), ("R18", rule_r18), ("R19", rule_r19), ("R20", rule_r20),
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
        if hits is SKIP:
            # A rule that could not run is NOT a rule that found nothing.
            print(f"[SKIP] {rid}: the tool it needs is not available here")
            continue
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
    "R13": lambda c: _append(c / "SKILL/scripts/os/_common.sh",
                             '\nif [[ -n "$_JSON_LIB" ]]; then :; fi\n'),
    "R14": lambda c: _append(c / "SKILL/scripts/os/_common.sh",
                             "\n_v=$(printf '%s' \"$x\" | awk '{ if (match($0, *\"key\"*)) { print substr($0, RSTART+1, RLENGTH-1) } }')\n"),
    "R15": lambda c: _append(c / "SKILL/scripts/os/_common.sh",
                             "\n_x=$(python3 -c 'import json,sys; json.loads(sys.stdin.read())')\n"),
    "R16": lambda c: _append(c / ".github/workflows/ci.yml",
                             "\n      - name: uses an unpublished file\n"
                             "        run: sh runs/20261001-replica/ledger.yaml\n"),
    "R17": lambda c: (_append(c / "SKILL/scripts/os/_common.sh",
                              "\nzz_same_body() { :; }\n"),
                      _append(c / "SKILL/scripts/preflight.sh",
                              "\nzz_same_body() { :; }\n")),
    "R18": lambda c: _append(c / "SKILL/scripts/os/_common.sh",
                             '\nCACHE_DIR="$(mktemp -d)"\n'),
    "R19": lambda c: _sub(c / "SKILL/scripts/os/_common.sh",
                          '[ -n "$_dir_enc" ] || return 3\n', ""),
    "R20": lambda c: _append(c / "README.md",
                             "\nsh SKILL/scripts/validate_dag.sh  # or: bash SKILL/scripts/validate_dag.sh\n"),
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
    unproven = []
    for rid, fn in DETECTORS:
        # 1. the clean tree must NOT fire
        shipped, repo_files = _load(root)
        clean_hits = fn(root, shipped, repo_files)
        if clean_hits is SKIP:
            # A rule that could not run was not proved: it is neither a
            # success nor a failure, and it must not be counted as one.
            unproven.append(rid)
            print(f"[SKIP] {rid}: no tool available, the rule could not be proved")
            continue
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
            if dirty_hits is SKIP:
                unproven.append(rid)
                print(f"[SKIP] {rid}: no tool available on the copy, not proved")
                continue
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
    if unproven:
        print()
        print(f"selftest: {len(failures) + len(unproven)} rule(s) could NOT be proved "
              f"(tool missing): {', '.join(unproven)}")
        return 1
    print("selftest: every rule is trustworthy (proved with its own defect)")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        r = Path(sys.argv[sys.argv.index("--root") + 1]).resolve() if "--root" in sys.argv else Path.cwd()
        sys.exit(selftest(r))
    sys.exit(main(sys.argv[1:]))
