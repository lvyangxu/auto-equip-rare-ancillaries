"""Very small structural sanity check for the mod's lua files.

It does not build a real syntax tree; it strips comments / strings and then
checks that every block opener (function / if / for / while / do / repeat)
has a matching closer (end / until).  That catches the mistakes this project
actually makes (a missing or extra `end`), which is enough as a smoke test
until the file is loaded by the game.

usage: python tools/_luacheck.py <file> [<file> ...]
"""
import re
import sys


def strip_noise(src):
    out = []
    i = 0
    n = len(src)
    while i < n:
        # long bracket string / comment: [[ ]] [==[ ]==]
        m = re.match(r'--\[(=*)\[', src[i:])
        if m:
            close = ']' + m.group(1) + ']'
            j = src.find(close, i + m.end())
            i = n if j < 0 else j + len(close)
            out.append(' ')
            continue
        m = re.match(r'\[(=*)\[', src[i:])
        if m:
            close = ']' + m.group(1) + ']'
            j = src.find(close, i + m.end())
            i = n if j < 0 else j + len(close)
            out.append(' ')
            continue
        if src.startswith('--', i):
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        ch = src[i]
        if ch in '"\'':
            j = i + 1
            while j < n:
                if src[j] == '\\':
                    j += 2
                    continue
                if src[j] == ch:
                    j += 1
                    break
                j += 1
            i = j
            out.append(' ')
            continue
        out.append(ch)
        i += 1
    return ''.join(out)


def check(path):
    src = open(path, encoding='utf-8', errors='replace').read()
    code = strip_noise(src)
    tokens = re.findall(r'[A-Za-z_][A-Za-z_0-9]*|==|~=|<=|>=|[^\s]', code)

    depth = 0
    pending_do = 0
    line = 1
    problems = []

    for tok in tokens:
        if tok == '\n':
            continue
        if tok == 'for' or tok == 'while':
            depth += 1
            pending_do += 1
        elif tok == 'if':
            depth += 1
        elif tok == 'function':
            depth += 1
        elif tok == 'repeat':
            depth += 1
        elif tok == 'do':
            if pending_do > 0:
                pending_do -= 1
            else:
                depth += 1
        elif tok == 'end':
            depth -= 1
            if depth < 0:
                problems.append('extra `end` (depth went negative)')
                depth = 0
        elif tok == 'until':
            depth -= 1
            if depth < 0:
                problems.append('extra `until`')
                depth = 0

    if depth != 0:
        problems.append('%d block(s) never closed' % depth)

    status = 'OK' if not problems else 'FAIL: ' + '; '.join(problems)
    print('%-60s %s' % (path, status))
    return not problems


all_ok = True
for p in sys.argv[1:]:
    all_ok = check(p) and all_ok

sys.exit(0 if all_ok else 1)
