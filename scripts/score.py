#!/usr/bin/env python3
"""Score what Unread read from a page against what it should have read.

  scripts/score.py page <expected.txt> <Engine>=<extract output>...   one page: scores, then each miss and junk sentence
  scripts/score.py table <dir> <page>... [--baseline <file>] [--record]
                                         each page's <dir>/<page>.<Engine>.txt against fixtures/corpus/<page>.expected.txt;
                                         a missing output counts as nothing read

Sentences are compared after collapsing whitespace and dropping invisible characters
(zero-width spaces and joiners, soft hyphens), aligned in order (longest common
subsequence), so a sentence read twice, out of place or split in two counts against the score.
  precision  aligned sentences / sentences read      (junk read lowers it)
  recall     aligned sentences / expected sentences  (content missed lowers it)
  bounds     sentences read that came with bounds / sentences read

An extract output is what `Unread --extract --from-start` prints: one `  N. (x,y wxh)  text`
or `  N. no bounds  text` line per sentence.
"""
import os
import re
import sys

SENTENCE = re.compile(r"^  \d+\. (\([^)]*\)|no bounds)  (.*)$")
CORPUS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fixtures", "corpus")
ENGINES = ("WebKit", "Chromium")


INVISIBLE = dict.fromkeys(map(ord, "\u200b\u200c\u200d\u2060\ufeff\u00ad"))  # zero-width spaces/joiners, soft hyphen


def norm(text):
    return " ".join(text.translate(INVISIBLE).split())


def expected_sentences(path):
    lines = open(path, encoding="utf-8").read().splitlines()
    while lines and lines[0].startswith("# "):  # headers: # start:, # flags:
        lines.pop(0)
    return [norm(l) for l in lines if l.strip()]


def extracted(path):
    """[(text, has_bounds)] from an --extract output."""
    out = []
    for line in open(path, encoding="utf-8", errors="replace"):
        m = SENTENCE.match(line.rstrip("\n"))
        if m:
            out.append((norm(m.group(2)), m.group(1) != "no bounds"))
    return out


def align(want, got):
    """Pairs (i, j) of an LCS of two lists, in order."""
    n, m = len(want), len(got)
    lcs = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n - 1, -1, -1):
        row, below = lcs[i], lcs[i + 1]
        for j in range(m - 1, -1, -1):
            row[j] = below[j + 1] + 1 if want[i] == got[j] else max(below[j], row[j + 1])
    pairs, i, j = [], 0, 0
    while i < n and j < m:
        if want[i] == got[j]:
            pairs.append((i, j)); i += 1; j += 1
        elif lcs[i + 1][j] >= lcs[i][j + 1]:
            i += 1
        else:
            j += 1
    return pairs


def score(want, got):
    texts = [t for t, _ in got]
    pairs = align(want, texts)
    return {
        "expected": len(want),
        "read": len(got),
        "matched": len(pairs),
        "bounded": sum(1 for _, b in got if b),
        "pairs": pairs,
    }


def pct(a, b):
    return a / b if b else (1.0 if a == 0 else 0.0)


def rates(s):
    return pct(s["matched"], s["read"]), pct(s["matched"], s["expected"]), pct(s["bounded"], s["read"])


def fmt(x):
    return f"{x * 100:5.1f}%"


def differences(want, got, pairs):
    """Missed (-) and junk (+) sentences in reading order, with the expected/read line numbers."""
    out, i, j = [], 0, 0
    for pi, pj in pairs + [(len(want), len(got))]:
        out += [f"     - {k + 1:>4}  {want[k]}" for k in range(i, pi)]
        out += [f"     + {k:>4}. {got[k][0]}" for k in range(j, pj)]
        i, j = pi + 1, pj + 1
    return out


def page(args):
    want = expected_sentences(args[0])
    for spec in args[1:]:
        engine, path = spec.split("=", 1)
        got = extracted(path)
        s = score(want, got)
        p, r, b = rates(s)
        print(f"   score: precision {fmt(p)}  recall {fmt(r)}  bounds {fmt(b)}  "
              f"({s['matched']} of {s['expected']} expected, {s['read']} read)  [{engine}]")
        diff = differences(want, got, s["pairs"])
        if diff:
            print("   - expected but not read (expected line), + read but not expected (sentence number):")
            print("\n".join(diff))


def load_baseline(path):
    base = {}
    if path and os.path.exists(path):
        for line in open(path):
            if line.startswith("#") or not line.strip():
                continue
            name, engine, p, r, b = line.split("\t")[:5]
            base[(name, engine)] = (float(p), float(r), float(b))
    return base


def table(args):
    out_dir = args[0]
    baseline = args[args.index("--baseline") + 1] if "--baseline" in args else None
    base = load_baseline(baseline)
    names = sorted(a for a in args[1:] if not a.startswith("--") and a != baseline)
    rows, totals = [], {e: {"expected": 0, "read": 0, "matched": 0, "bounded": 0} for e in ENGINES}
    header = f"{'page':<26} {'engine':<9} {'expected':>8} {'read':>5} {'match':>6} {'precision':>9} {'recall':>7} {'bounds':>7}"
    print(header + ("   Δprec  Δrecall Δbounds" if base else ""))
    for name in names:
        want = expected_sentences(os.path.join(CORPUS, f"{name}.expected.txt"))
        for engine in ENGINES:
            path = os.path.join(out_dir, f"{name}.{engine}.txt")
            s = score(want, extracted(path) if os.path.exists(path) else [])
            for k in totals[engine]:
                totals[engine][k] += s[k]
            p, r, b = rates(s)
            rows.append((name, engine, p, r, b))
            line = (f"{name:<26} {engine:<9} {s['expected']:>8} {s['read']:>5} {s['matched']:>6} "
                    f"{fmt(p):>9} {fmt(r):>7} {fmt(b):>7}")
            if (name, engine) in base:
                d = [x - y for x, y in zip((p, r, b), base[(name, engine)])]
                line += "".join(f" {round(x * 100, 1) + 0:+7.1f}" for x in d)
                if min(d) < -0.0005:
                    line += "  ← worse"
            print(line)
    for engine, t in totals.items():
        if t["expected"]:
            p, r, b = rates(t)
            print(f"{'corpus (all sentences)':<26} {engine:<9} {t['expected']:>8} {t['read']:>5} {t['matched']:>6} "
                  f"{fmt(p):>9} {fmt(r):>7} {fmt(b):>7}")
    if "--record" in args and baseline:
        with open(baseline, "w") as f:
            f.write("# page\tengine\tprecision\trecall\tbounds  (scripts/score-corpus.sh --record)\n")
            for name, engine, p, r, b in rows:
                f.write(f"{name}\t{engine}\t{p:.4f}\t{r:.4f}\t{b:.4f}\n")
        print(f"baseline recorded: {baseline}")


if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in ("page", "table"):
        sys.exit(__doc__)
    (page if sys.argv[1] == "page" else table)(sys.argv[2:])
