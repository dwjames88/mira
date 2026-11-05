#!/usr/bin/env python3 -I
"""Writes the per-stock `grain` blocks of Films/films.json (Mira's grain model, Design/GRAIN.md section 6.7).

Re-runnable: it removes any existing one-line `"grain"` entry and appends the table below as the last key of each
listed film, and gives every variant (an entry with a `parent`) its stock's block. Nothing else in the file is
touched (the file is edited as text, so key order, the inline `reciprocity` objects and keys other tools add stay as
they are). Stocks not listed use the family and ISO defaults of `FilmCharacter.defaults`.

    python3 -I scripts/apply-grain-params.py [path/to/films.json]

Block keys: rms (datasheet RMS granularity x 1000 at D = 1.0, 48 um aperture), size (cloud std in frame um),
clumping (weight of the coarse octave), layerCorrelation (share of the grain common to the colour layers),
shape (optional density shape: negative, slide, bw, instant). The numbers are Mira's own tuning, set by eye
against the model; the RMS values for Tri-X, T-Max, Velvia and Provia follow the public datasheets.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# id -> (rms, size um, clumping, layerCorrelation)
STOCKS = {
    "kodak-portra-160":   (4.0, 3.7, 0.12, 0.88),
    "kodak-portra-400":   (4.4, 4.0, 0.15, 0.88),
    "kodak-portra-800":   (5.2, 4.8, 0.20, 0.86),
    "kodak-ektar-100":    (3.0, 3.2, 0.08, 0.90),
    "fuji-velvia-50":     (6.0, 2.4, 0.05, 0.90),
    "fuji-provia-100f":   (7.0, 2.7, 0.06, 0.90),
    "kodak-tri-x-400":    (17.0, 3.0, 0.38, 1.0),
    "ilford-hp5-plus-400": (15.0, 3.2, 0.32, 1.0),
    "kodak-t-max-100":    (8.0, 2.0, 0.04, 1.0),
    "kodak-t-max-400":    (10.0, 2.3, 0.06, 1.0),
    "ilford-delta-100":   (9.0, 2.0, 0.04, 1.0),
    "ilford-delta-400":   (12.0, 2.4, 0.06, 1.0),
    "vision3-500t":       (5.4, 4.2, 0.14, 0.88),
    "vision3-250d":       (3.8, 3.5, 0.10, 0.90),
}
# Instant film: soft, large mottle, weakly chromatic (every instant stock; the instant family default shape).
INSTANT = (10.0, 7.5, 0.10, 0.40)


def fmt(v):
    return ("%g" % v)


def block_json(t):
    rms, size, clump, rho = t
    return '"grain": {"rms": %s, "size": %s, "clumping": %s, "layerCorrelation": %s}' % (
        fmt(rms), fmt(size), fmt(clump), fmt(rho))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "Films", "films.json")
    text = open(path, encoding="utf-8").read()
    films = json.loads(text)
    by_id = {f["id"]: f for f in films}

    def stock_of(f):
        while f.get("parent") in by_id:
            f = by_id[f["parent"]]
        return f

    wanted = {}
    for f in films:
        s = stock_of(f)
        if s["id"] in STOCKS:
            wanted[f["id"]] = STOCKS[s["id"]]
        elif s.get("family") == "instant":
            wanted[f["id"]] = INSTANT

    lines = text.split("\n")
    out = []
    i = 0
    n_set = 0
    while i < len(lines):
        if lines[i] == "  {":
            j = i
            while lines[j] not in ("  }", "  },"):
                j += 1
            body = lines[i + 1:j]
            m = re.search(r'^    "id": "([^"]+)"', "\n".join(body), re.M)
            fid = m.group(1) if m else None
            body = [ln for ln in body if not re.match(r'^    "grain": \{.*\},?$', ln)]
            if body:
                body[-1] = body[-1].rstrip().rstrip(",")
            if fid in wanted:
                body[-1] = body[-1] + ","
                body.append("    " + block_json(wanted[fid]))
                n_set += 1
            out.append(lines[i])
            out.extend(body)
            out.append(lines[j])
            i = j + 1
        else:
            out.append(lines[i])
            i += 1
    new_text = "\n".join(out)

    # Check: valid JSON, same data except for the grain blocks.
    new = json.loads(new_text)
    assert len(new) == len(films)
    for a, b in zip(films, new):
        a = {k: v for k, v in a.items() if k != "grain"}
        b2 = {k: v for k, v in b.items() if k != "grain"}
        assert a == b2, a["id"]
        assert ("grain" in b) == (b["id"] in wanted), b["id"]
    if new_text != text:
        open(path, "w", encoding="utf-8").write(new_text)
    print("grain blocks on %d of %d films (%s)" % (n_set, len(films), path))


if __name__ == "__main__":
    main()
