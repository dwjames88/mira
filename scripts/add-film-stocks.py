#!/usr/bin/env python3
"""One-off: add the stock / stockName / stockBase / isoLabel / variation fields to Films/films.json.

Run once from the repository root with `python3 -I scripts/add-film-stocks.py`. It edits the file in place
as text (inserting lines after each entry's "iso"), so the rest of the file's formatting is untouched.
Scheme: Design/FILM-SCIENCE.md, "How to add a film". Re-running is refused when the fields exist.
"""
import json, re, sys

PATH = "Films/films.json"
text = open(PATH, encoding="utf8").read()
films = json.loads(text)
if any("stock" in f for f in films):
    sys.exit("films.json already has stock fields")
byid = {f["id"]: f for f in films}
root = lambda f: f.get("parent") or f["id"]

# stock id -> (stockName, base film id, member root ids)
GROUPS = {
    "kodak-portra": ("Portra", "kodak-portra-400", [
        "kodak-portra-160", "kodak-portra-160-nc", "kodak-portra-160-vc",
        "kodak-portra-400", "kodak-portra-400-nc", "kodak-portra-400-uc", "kodak-portra-400-vc",
        "kodak-portra-800"]),
    "fuji-superia": ("Superia", "fuji-superia-400", [
        "fuji-superia-100", "fuji-superia-200", "fuji-superia-400", "fuji-superia-800", "fuji-superia-1600",
        "fuji-superia-hg-1600", "fuji-superia-reala-100", "fuji-superia-x-tra-800"]),
    "fuji-provia": ("Provia", "fuji-provia-100f", ["fuji-provia-100f", "fuji-provia-400f", "fuji-provia-400x"]),
    "fuji-velvia": ("Velvia", "fuji-velvia-50", ["fuji-velvia-50", "fuji-velvia-100"]),
    "fuji-pro": ("Pro", "fuji-pro-400h", ["fuji-pro-160c", "fuji-pro-400h", "fuji-pro-800z"]),
    "kodak-elite-chrome": ("Elite Chrome", "kodak-elite-chrome-200", [
        "kodak-elite-chrome-200", "kodak-elite-chrome-400", "kodak-elite-extracolor-100"]),
    "kodak-elite-color": ("Elite Color", "kodak-elite-color-400", ["kodak-elite-color-200", "kodak-elite-color-400"]),
    "kodak-kodachrome": ("Kodachrome", "kodak-kodachrome-64", [
        "kodak-kodachrome-25", "kodak-kodachrome-64", "kodak-kodachrome-200"]),
    "ilford-delta": ("Delta", "ilford-delta-400", ["ilford-delta-100", "ilford-delta-400", "ilford-delta-3200"]),
    "kodak-t-max": ("T-Max", "kodak-t-max-400", ["kodak-t-max-100", "kodak-t-max-400", "kodak-t-max-3200"]),
    "agfa-apx": ("APX", "agfa-apx-100", ["agfa-apx-25", "agfa-apx-100"]),
    "fuji-neopan": ("Neopan", "fuji-neopan-acros-100", ["fuji-neopan-acros-100", "fuji-neopan-1600"]),
    "rollei-retro": ("Retro", "rollei-retro-80s", ["rollei-retro-80s", "rollei-retro-100-tonal"]),
    "mira-vision3": ("Vision3", "vision3-500t", ["vision3-500t", "vision3-250d"]),
    "fuji-fp-100c": ("FP-100C", "fuji-fp-100c", ["fuji-fp-100c", "fuji-fp-100c-negative"]),
    "fuji-fp-3000b": ("FP-3000B", "fuji-fp-3000b", ["fuji-fp-3000b", "fuji-fp-3000b-negative"]),
    "polaroid-665": ("665", "polaroid-665", ["polaroid-665", "polaroid-665-negative"]),
}
# Singletons whose stock id / card title differ from the film's id / displayName.
SINGLE = {
    "kodak-tri-x-400": ("kodak-tri-x", "Tri-X"),
    "ilford-hp5-plus-400": ("ilford-hp5-plus", "HP5 Plus"),
}
# Root film id -> variation label of that root inside its stock (all other roots are the plain film).
ROOT_VARIATION = {
    "kodak-portra-160-nc": "NC", "kodak-portra-400-nc": "NC",
    "kodak-portra-160-vc": "VC", "kodak-portra-400-vc": "VC", "kodak-portra-400-uc": "UC",
    "fuji-superia-hg-1600": "HG", "fuji-superia-reala-100": "Reala", "fuji-superia-x-tra-800": "X-Tra",
    "fuji-provia-400f": "F", "fuji-provia-400x": "X",
    "fuji-fp-100c-negative": "Negative", "fuji-fp-3000b-negative": "Negative", "polaroid-665-negative": "Negative",
}
# Root film id -> ISO chip label, where the bare number would not do.
ROOT_ISO_LABEL = {
    "fuji-provia-100f": "100F",
    "fuji-pro-160c": "160C", "fuji-pro-400h": "400H", "fuji-pro-800z": "800Z",
    "rollei-retro-80s": "80s", "rollei-retro-100-tonal": "100 Tonal",
    "vision3-500t": "500T", "vision3-250d": "250D",
}

stock_of, name_of = {}, {}
for sid, (name, base, roots) in GROUPS.items():
    for r in roots:
        assert r in byid and not byid[r].get("parent"), r
        stock_of[r] = sid
    name_of[sid] = name
for f in films:
    r = root(f)
    if r not in stock_of:
        sid, name = SINGLE.get(r, (r, byid[r]["displayName"]))
        stock_of[r] = sid
        name_of[sid] = name
bases = {sid: base for sid, (_, base, _) in GROUPS.items()}
for r, (sid, _) in SINGLE.items():
    bases[sid] = r
for f in films:
    sid = stock_of[root(f)]
    bases.setdefault(sid, root(f))

fields = {}
for f in films:
    r = root(f)
    parts = [ROOT_VARIATION.get(r), f.get("variant")]
    variation = " ".join(p for p in parts if p) or None
    e = {"stock": stock_of[r]}
    if bases[e["stock"]] == f["id"]:
        e["stockBase"] = True
        e["stockName"] = name_of[e["stock"]]
    if r in ROOT_ISO_LABEL:
        e["isoLabel"] = ROOT_ISO_LABEL[r]
    if variation:
        e["variation"] = variation
    fields[f["id"]] = e

# Sanity: one family per stock, one base per stock, one entry per (iso, variation).
seen = {}
for f in films:
    e = fields[f["id"]]
    s = e["stock"]
    seen.setdefault(s, []).append(f)
for s, members in seen.items():
    assert len({m["family"] for m in members}) == 1, s
    assert sum(1 for m in members if fields[m["id"]].get("stockBase")) == 1, s
    keys = [(str(m["iso"]), fields[m["id"]].get("variation")) for m in members]
    assert len(keys) == len(set(keys)), (s, keys)

out, cur = [], None
for line in text.split("\n"):
    m = re.match(r'^    "id": "([^"]+)"', line)
    if m:
        cur = m.group(1)
    out.append(line)
    if cur and re.match(r'^    "iso":', line):
        for k, v in fields[cur].items():
            out.append(f'    "{k}": {json.dumps(v, ensure_ascii=False)},')
        cur = None
open(PATH, "w", encoding="utf8").write("\n".join(out))
json.load(open(PATH, encoding="utf8"))
print(len(films), "films,", len(seen), "stocks")
