#!/usr/bin/env python3
# Enumerate partial record literals: a literal naming fewer fields than its
# record declares. briar-systems/mach#3108 says the unnamed fields hold the
# previous stack frame's contents rather than zero, which covers `T{}` and every
# partial form. See briar-systems/mach-tls#22.
#
#   python3 tools/partial_literal_sweep.py [project-root]
#
# Four things this gets right, each of which cost a wrong answer first:
#
#   * Enumerate from record definitions, not by matching literal text. A grep
#     pattern counts what it matches, not what exists.
#   * Parse those definitions by matching braces, never by assuming the closing
#     brace starts a line. A single-line `rec H { a: u64; b: u64; }` otherwise
#     runs on to the NEXT record's closing brace and steals its field list, so
#     two records get wrong field sets and the tool reports plausible nonsense.
#     That alone produced 54 findings in mach-http where the answer is 2.
#   * Resolve each literal's qualifier through its file's `use` statements. Many
#     record names collide across a project and its dependencies, so keying by
#     bare name silently matches the wrong definition. A module also re-exports
#     its submodules' types, so a miss falls back to the named module's own
#     subtree only, and reports ambiguity rather than guessing.
#   * Take the module root from each project's `[project] id` in mach.toml, not
#     from its directory name: mach-crypto is `crypto`, mach-tls is `tls`.
#   * Refuse to report a count when the input was incomplete. A dependency that
#     is absent from `dep/` resolves nothing, so its records are missing, so
#     every literal naming one is skipped and the total silently falls. That
#     produced a clean bill for hedge while ~43 sites went unexamined, because
#     the warning sat in a line a caller had truncated away. A missing
#     dependency, an unresolved qualifier, and an ambiguous one are now all
#     fatal: the headline itself is marked UNRELIABLE and the exit status is 1.
#
# `[N]Type{a, b}` is an array literal and is excluded; it is not a record
# literal. An unresolvable qualifier is reported and skipped, never guessed at.
# Partial record literal sweep, generalised across projects.
# Module roots and source dirs are read from each project's mach.toml rather
# than hardcoded, because the module root is the dependency's [project] id and
# not its directory name (mach-crypto -> crypto).
import re, glob, os, sys

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else '.')

def manifest(d):
    p = os.path.join(d, 'mach.toml')
    if not os.path.exists(p): return None, None
    t = open(p).read()
    pid = re.search(r'^\s*id\s*=\s*"([^"]+)"', t, re.M)
    src = re.search(r'^\s*src\s*=\s*"([^"]+)"', t, re.M)
    return (pid.group(1) if pid else None), (src.group(1) if src else 'src')

SELF_ID, SELF_SRC = manifest(ROOT)
if SELF_ID is None:
    print("no mach.toml at", ROOT); sys.exit(2)

# every dependency the project declares must actually be on disk and scanned;
# an absent one silently removes its records and every literal that names them
def declared_deps(root):
    names = set()
    for f in ('mach.lock', 'mach.toml'):
        p = os.path.join(root, f)
        if not os.path.exists(p): continue
        names |= set(re.findall(r'^\s*\[dep\.([\w.-]+)\]', open(p).read(), re.M))
        if names: break
    return names

DECLARED = declared_deps(ROOT)

roots = {}   # absolute source dir -> module root id
roots[os.path.join(ROOT, SELF_SRC)] = SELF_ID
dep_report = []
for d in sorted(glob.glob(os.path.join(ROOT, 'dep', '*'))):
    if not os.path.isdir(d): continue
    did, dsrc = manifest(d)
    if did is None:
        dep_report.append((os.path.basename(d), None)); continue
    roots[os.path.join(d, dsrc)] = did
    dep_report.append((os.path.basename(d), did))

present = {b for b, i in dep_report if i is not None}
missing_deps = sorted(DECLARED - present)
unreadable = sorted(b for b, i in dep_report if i is None)

def module_of(path):
    for base, rid in roots.items():
        if path.startswith(base + os.sep):
            rel = os.path.relpath(path, base)
            return rid + '.' + '.'.join(rel.split(os.sep))[:-5]
    return None

files = []
for base in roots:
    files += sorted(glob.glob(base + '/**/*.mach', recursive=True))

defs, texts = {}, {}
for f in files:
    mod = module_of(f)
    if not mod: continue
    texts[f] = (mod, open(f).read())
    body = texts[f][1]
    # brace-matched so a single-line `rec H { a: u64; b: u64; }` is not missed
    for m in re.finditer(r'^(?:pub )?rec (\w+)\s*\{', body, re.M):
        d, i = 0, m.end() - 1
        while i < len(body):
            if body[i] == '{': d += 1
            elif body[i] == '}':
                d -= 1
                if d == 0: break
            i += 1
        inner = body[m.end():i]
        fields, depth, cur = [], 0, ''
        for c in inner:
            if c in '{[(': depth += 1
            elif c in '}])': depth -= 1
            if c == ';' and depth == 0:
                fm = re.match(r'\s*(\w+)\s*:\s*(.+)$', cur, re.S)
                if fm: fields.append((fm.group(1), ' '.join(fm.group(2).split())))
                cur = ''
            else:
                cur += c
        defs[mod + '.' + m.group(1)] = fields

def aliases(text):
    o = {}
    for m in re.finditer(r'^use\s+(?:(\w+)\s*:\s*)?([\w.]+)\s*;', text, re.M):
        o[m.group(1) or m.group(2).split('.')[-1]] = m.group(2)
    return o

def top_named(inner):
    names, d, tok, i = [], 0, '', 0
    while i < len(inner):
        c = inner[i]
        if c in '{[(': d += 1
        elif c in '}])': d -= 1
        if d == 0 and c == ':' and not inner.startswith('::', i) and not (i and inner[i-1] == ':'):
            m = re.search(r'(\w+)\s*$', tok)
            if m: names.append(m.group(1))
            tok = ''
        elif d == 0 and c == ',': tok = ''
        else: tok += c
        i += 1
    return names

SELF_BASE = os.path.join(ROOT, SELF_SRC)
findings, unresolved, ambiguous = [], {}, {}
for f, (mod, text) in texts.items():
    if not f.startswith(SELF_BASE + os.sep): continue      # sweep this project only
    alias = aliases(text)
    # `[N]Type{...}` is an array literal, not a record literal
    for m in re.finditer(r'(?<![\w.\]])((?:[a-z_]\w*)\.)?([A-Z]\w*)\{', text):
        qual, name = m.group(1), m.group(2)
        if qual:
            base = alias.get(qual[:-1])
            key = base + '.' + name if base else None
        else:
            key = mod + '.' + name
        if key is not None and key not in defs:
            # a module re-exports its submodules' types, so look only inside the
            # named module's own subtree; never across unrelated namespaces
            stem = key[:-(len(name) + 1)]
            cand = [k for k in defs if k.startswith(stem + '.') and k.endswith('.' + name)]
            if len(cand) == 1:
                key = cand[0]
            elif len(cand) > 1:
                ambiguous[key] = sorted(cand)
                key = None
        if key is None or key not in defs:
            if qual: unresolved[qual + name] = unresolved.get(qual + name, 0) + 1
            continue
        start = m.end() - 1; d = 0; i = start
        while i < len(text):
            if text[i] == '{': d += 1
            elif text[i] == '}':
                d -= 1
                if d == 0: break
            i += 1
        inner = text[start+1:i]
        fields = defs[key]
        named = [n for n in top_named(inner) if n in dict(fields)]
        missing = [(n, t.strip()) for n, t in fields if n not in named]
        if not missing: continue
        ln = text.count('\n', 0, m.start()) + 1
        # classify: inside a `test "..."` block, or in library code
        lines = text.split('\n'); kind = 'src'
        for k in range(ln - 1, -1, -1):
            if lines[k].startswith('test "'): kind = 'test'; break
            if re.match(r'^(pub )?fun ', lines[k]): break
        findings.append((os.path.relpath(f, ROOT), ln, key, kind,
                         len(named), len(fields), missing))

print(f"project        : {SELF_ID}  ({os.path.basename(ROOT)})")
print(f"deps resolved  : {', '.join(f'{a}->{b}' for a,b in dep_report) or 'none'}")
print(f"files scanned  : {len(files)}  (this project: {sum(1 for f in texts if f.startswith(SELF_BASE + os.sep))})")
print(f"record defs    : {len(defs)}")
print(f"unresolved qual: {dict(sorted(unresolved.items())) if unresolved else 'none'}")
print(f"ambiguous qual : {ambiguous if ambiguous else 'none'}")
print(f"declared deps  : {len(DECLARED)}  missing: {', '.join(missing_deps) or 'none'}"
      + (f"  unreadable: {', '.join(unreadable)}" if unreadable else ""))
skipped = sum(unresolved.values()) + sum(len(v) for v in ambiguous.values())
reliable = not missing_deps and not unreadable and not unresolved and not ambiguous
src_n = sum(1 for x in findings if x[3] == 'src')
# the reliability verdict rides on the headline so truncating the output cannot
# separate the number from the reason it is wrong
mark = "" if reliable else f"   [UNRELIABLE: {skipped} literal sites skipped]"
print(f"PARTIAL LITERALS: {len(findings)}   (src {src_n} / test {len(findings)-src_n}){mark}")
if findings:
    from collections import Counter
    print()
    for k, n in Counter((x[2], x[3]) for x in findings).most_common():
        print(f"  {n:4d}  {k[1]:5s}  {k[0]}")
    print()
    for f, ln, key, kind, a, b, missing in sorted(findings, key=lambda x: (x[3] != 'src', x[0], x[1])):
        print(f"{kind:4s} {f}:{ln}  {key}  {a}/{b}  missing: {', '.join(n + ':' + t for n, t in missing)}")

print()
if reliable:
    print("VERDICT: complete. Every declared dependency was scanned and every "
          "qualifier resolved.")
else:
    why = []
    if missing_deps: why.append(f"{len(missing_deps)} declared dependencies absent from dep/")
    if unreadable:   why.append(f"{len(unreadable)} dependencies without a readable mach.toml")
    if unresolved:   why.append(f"{len(unresolved)} qualifiers unresolved")
    if ambiguous:    why.append(f"{len(ambiguous)} qualifiers ambiguous")
    print("VERDICT: UNRELIABLE. " + "; ".join(why) + ".")
    print(f"         {skipped} literal sites were skipped, so the count above is a "
          "floor and not an answer.")
    print("         Populate dep/ at the commits in mach.lock and run again.")
    sys.exit(1)
