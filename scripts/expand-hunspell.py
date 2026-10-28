#!/usr/bin/env python3
"""Expands a Hunspell dictionary (.dic + .aff) into a plain list of every word form.

LaserFocus ships the result for Indonesian, because older macOS versions have no Indonesian
word list of their own. Supports what the Indonesian dictionary uses: FLAG long, PFX/SFX with
strip, add and condition, continuation classes, cross products, CIRCUMFIX and NEEDAFFIX.

    scripts/expand-hunspell.py id_ID.dic id_ID.aff > Resources/Indonesian/words-id.txt
"""
import re
import sys
from collections import defaultdict


def split_flags(text, long_flags):
    if long_flags:
        return {text[i:i + 2] for i in range(0, len(text) - len(text) % 2, 2)}
    return set(text)


def parse_aff(path):
    encoding, long_flags = "utf-8", False
    raw = open(path, "rb").read()
    match = re.search(rb"^SET\s+(\S+)", raw, re.M)
    if match:
        encoding = match.group(1).decode().lower().replace("iso8859", "iso-8859")
    rules = defaultdict(list)       # flag -> [(kind, strip, add, contflags, condition regex)]
    cross = {}
    circumfix = needaffix = None
    for line in raw.decode(encoding).splitlines():
        line = line.split("#", 1)[0].rstrip()
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "FLAG" and parts[1] == "long":
            long_flags = True
        elif parts[0] == "CIRCUMFIX":
            circumfix = parts[1]
        elif parts[0] == "NEEDAFFIX":
            needaffix = parts[1]
        elif parts[0] in ("PFX", "SFX") and len(parts) == 4 and parts[3].isdigit():
            cross[parts[1]] = parts[2] == "Y"
        elif parts[0] in ("PFX", "SFX") and len(parts) >= 5:
            kind, flag, strip, add, condition = parts[:5]
            strip = "" if strip == "0" else strip
            add, _, cont = add.partition("/")
            add = "" if add == "0" else add
            # Hunspell reads "[^l^r]" as "none of l, r": drop the inner carets.
            condition = re.sub(r"\[\^([^\]]*)\]", lambda m: "[^" + m.group(1).replace("^", "") + "]", condition)
            pattern = re.compile(("^" + condition) if kind == "PFX" else (condition + "$"))
            rules[flag].append((kind, strip, add, split_flags(cont, long_flags), pattern))
    return encoding, long_flags, rules, cross, circumfix, needaffix


def expand(dic_path, aff_path):
    encoding, long_flags, rules, cross, circumfix, needaffix = parse_aff(aff_path)
    words = set()
    lines = open(dic_path, encoding=encoding).read().splitlines()
    for line in lines[1:]:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        stem, _, flag_text = line.partition("/")
        flag_text = flag_text.split()[0] if flag_text else ""
        root_flags = split_flags(flag_text, long_flags)
        # Each state: word, flags it can take now, prefixes and suffixes so far, and whether
        # a circumfix half or a "needs another affix" mark is still waiting for its partner.
        start = (stem, frozenset(root_flags), 0, 0, False, False, needaffix in root_flags)
        seen = {start}
        queue = [start]
        while queue:
            word, flags, prefixes, suffixes, circ_p, circ_s, needs = queue.pop()
            if not needs and circ_p == circ_s:
                words.add(word)
            for flag in flags:
                for kind, strip, add, cont, pattern in rules.get(flag, ()):
                    if kind == "PFX":
                        if prefixes >= 1 or (suffixes and not cross.get(flag, False)) or not pattern.search(word):
                            continue
                        if strip and not word.startswith(strip):
                            continue
                        new = add + word[len(strip):]
                        # A prefix can still be followed by the root's cross-product suffixes.
                        later = {f for f in root_flags if cross.get(f) and rules[f] and rules[f][0][0] == "SFX"} if not suffixes else set()
                        state = (new, frozenset(cont | later), prefixes + 1, suffixes,
                                 circ_p or circumfix in cont, circ_s, needaffix in cont)
                    else:
                        if suffixes >= 2 or not pattern.search(word):
                            continue
                        if strip and not word.endswith(strip):
                            continue
                        new = word[:len(word) - len(strip)] + add
                        later = {f for f in root_flags if cross.get(f) and rules[f] and rules[f][0][0] == "PFX"} if not prefixes and cross.get(flag, False) else set()
                        state = (new, frozenset(cont | later), prefixes, suffixes + 1,
                                 circ_p, circ_s or circumfix in cont, needaffix in cont)
                    if state not in seen:
                        seen.add(state)
                        queue.append(state)
    return words


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    # Lowercase and sorted by code point, so the app can binary-search it.
    for word in sorted({w.lower() for w in expand(sys.argv[1], sys.argv[2]) if len(w) > 1}):
        print(word)
