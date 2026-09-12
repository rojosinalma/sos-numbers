#!/usr/bin/env python3
"""Generate an offline country-boundary asset from Natural Earth admin-0 data.

Deliverable: assets/geo/country_borders.json  (compact, integer-quantised rings)
  `countries` - Natural Earth admin-0 countries, one entry per ISO alpha-2
  `subunits`  - overlay from admin-0 map units: inhabited overseas territories
                that admin-0 folds into the parent (BQ, YT, GF, ...). Tested
                FIRST by the lookup, `countries` is the fallback.

Usage:
    python3 tools/gen_country_borders.py            # download (cached) + build
    python3 tools/gen_country_borders.py --verify    # spec tables + shape asserts
    python3 tools/gen_country_borders.py --build --verify

stdlib only. See tools/SPEC_borders.md for the documented output format.
"""

import argparse
import json
import math
import os
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CACHE = os.path.join(HERE, "ne_admin0.cache.geojson")
MU_CACHE = os.path.join(HERE, "mapunits.cache.geojson")
OUT = os.path.join(ROOT, "assets", "geo", "country_borders.json")
NUMBERS = os.path.join(ROOT, "assets", "data", "emergency_numbers.json")

# 10m is used instead of 50m on purpose: at 50m the coastline generalisation
# puts Manhattan, Hong Kong Island and the European bank of the Bosphorus in
# the water, so New York / Hong Kong / Istanbul cannot resolve at all. 50m and
# 110m are kept as fallbacks only.
SOURCE_URLS = [
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/"
    "geojson/ne_10m_admin_0_countries.geojson",
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/main/"
    "geojson/ne_10m_admin_0_countries.geojson",
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/"
    "geojson/ne_50m_admin_0_countries.geojson",
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/"
    "geojson/ne_110m_admin_0_countries.geojson",
]
SOURCE_NAME = "Natural Earth 5.x admin-0 countries, 10m (public domain)"

# Natural Earth admin-0 folds several *inhabited* overseas territories into the
# parent state's feature, so a phone in Kralendijk (Bonaire) resolved to NL and
# was shown 112 when BQ's real emergency number is 911. Mayotte, Cocos and
# Tokelau resolved to nothing at all. ne_10m_admin_0_map_units splits exactly
# those apart while keeping identical parent outlines, so it is used as a
# second pass and emitted as the `subunits` overlay.
MAPUNITS_URLS = [
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/"
    "geojson/ne_10m_admin_0_map_units.geojson",
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/main/"
    "geojson/ne_10m_admin_0_map_units.geojson",
]
MAPUNITS_NAME = "Natural Earth 5.x admin-0 map units, 10m (public domain)"

SCHEMA = 2
SCALE = 1000          # coordinate multiplier before rounding to int (~110 m)
SIMPLIFY_EPS = 0.002  # degrees (~220 m) Douglas-Peucker, applied before quantising
SMALL_RING_DEG = 0.05  # rings smaller than this (bbox extent) are never simplified
TINY_RING_DEG = 0.004  # rings smaller than this are quantised outward, not to nearest
MIN_RING_POINTS = 3   # distinct points; rings are stored unclosed (== 4 closed)

# Natural Earth leaves ISO_A2 as "-99" for sovereignty-disputed or
# non-ISO entries. NAME -> alpha-2 patch, applied only after ISO_A2,
# ISO_A2_EH and WB_A2 have all failed.
NAME_PATCH = {
    "Somaliland": "SO",        # no ISO code; de jure part of Somalia (ADM0_ISO=SOM)
    "N. Cyprus": "CY",         # no ISO code; de jure part of Cyprus (ADM0_ISO=CYP)
    "Siachen Glacier": "IN",   # disputed, India-administered
    "Kosovo": "XK",            # user-assigned code, in common use
    "Indian Ocean Ter.": "AU", # Christmas + Cocos, one NE feature
    "Ashmore and Cartier Is.": "AU",
    "France": "FR",
    "Norway": "NO",
    "Taiwan": "TW",
    "Dhekelia Sovereign Base Area": "CY",
    "Akrotiri Sovereign Base Area": "CY",
    "Dhekelia": "CY",                # UK base on Cyprus, no own ISO code
    "Akrotiri": "CY",                # UK base on Cyprus, no own ISO code
    "Cyprus U.N. Buffer Zone": "CY",
    "USNB Guantanamo Bay": "CU",     # US lease inside Cuba (SOV_A3=CU1)
    "Baikonur": "KZ",
    "Bir Tawil": "SD",
    "Coral Sea Is.": "AU",
    "Clipperton I.": "FR",
    "Scarborough Reef": "PH",
    "Serranilla Bank": "CO",
    "Bajo Nuevo Bank": "CO",
    "Spratly Is.": "VN",
    "Brazilian I.": "BR",
    "Southern Patagonian Ice Field": "CL",
}

TESTS = [
    ("Berlin", 52.5200, 13.4050, "DE"),
    ("Paris", 48.8566, 2.3522, "FR"),
    ("Madrid", 40.4168, -3.7038, "ES"),
    ("London", 51.5074, -0.1278, "GB"),
    ("Dublin", 53.3498, -6.2603, "IE"),
    ("New York", 40.7128, -74.0060, "US"),
    ("Los Angeles", 34.0522, -118.2437, "US"),
    ("Mexico City", 19.4326, -99.1332, "MX"),
    ("Buenos Aires", -34.6037, -58.3816, "AR"),
    ("Santiago", -33.4489, -70.6693, "CL"),
    ("Sao Paulo", -23.5505, -46.6333, "BR"),
    ("Bogota", 4.7110, -74.0721, "CO"),
    ("Cairo", 30.0444, 31.2357, "EG"),
    ("Nairobi", -1.2921, 36.8219, "KE"),
    ("Lagos", 6.5244, 3.3792, "NG"),
    ("Cape Town", -33.9249, 18.4241, "ZA"),
    ("Tokyo", 35.6762, 139.6503, "JP"),
    ("Seoul", 37.5665, 126.9780, "KR"),
    ("Beijing", 39.9042, 116.4074, "CN"),
    ("Hong Kong", 22.3193, 114.1694, "HK|CN"),
    ("Singapore", 1.3521, 103.8198, "SG"),
    ("Bangkok", 13.7563, 100.5018, "TH"),
    ("Mumbai", 19.0760, 72.8777, "IN"),
    ("Dubai", 25.2048, 55.2708, "AE"),
    ("Istanbul", 41.0082, 28.9784, "TR"),
    ("Moscow", 55.7558, 37.6173, "RU"),
    ("Sydney", -33.8688, 151.2093, "AU"),
    ("Auckland", -36.8485, 174.7633, "NZ"),
    ("Reykjavik", 64.1466, -21.9426, "IS"),
    ("Valletta", 35.8989, 14.5146, "MT"),
    ("Zurich", 47.3769, 8.5417, "CH"),
    ("mid-Atlantic", 0.0000, -30.0000, None),
]

# The overseas territories the `subunits` overlay exists for. Every one of these
# is in assets/data/emergency_numbers.json with its OWN numbers, and every one
# of them resolved to the wrong answer (or to nothing) before the overlay.
#
# An optional 5th element marks a KNOWN SOURCE GAP: the coordinate is real but
# Natural Earth 10m has no land under it (generalised coastline, or the islet
# is missing outright), so the raw source polygon does not contain it either.
# Such a row reports GAP instead of FAIL when the result is null - a wrong
# non-null answer still fails - and is paired with an on-land companion for the
# same territory that must PASS. Geometry is never fabricated to force a pass.
SUBUNIT_TESTS = [
    ("Kralendijk", 12.1510, -68.2770, "BQ"),      # was NL -> 112. The actual bug.
    ("Oranjestad SE", 17.4850, -62.9760, "BQ"),   # Sint Eustatius, also BQ
    ("Mamoudzou", -12.7800, 45.2280, "YT",        # was null, still null:
     "NE 10m coast is 850 m west of this point"),
    ("Dzaoudzi", -12.7870, 45.2750, "YT"),        # Petite-Terre (airport), was FR
    ("Nukunonu", -9.1690, -171.8190, "TK",        # was null, still null:
     "atoll absent from NE 10m; nearest ring (Fakaofo) 70 km away"),
    ("Fakaofo", -9.3500, -171.1934, "TK"),        # east rim, was NZ
    ("West Island", -12.1570, 96.8260, "CC"),     # was null
    ("Flying Fish Cove", -10.4220, 105.6790, "CX",   # was null, still null:
     "2.1 km north of NE 10m's northern tip of Christmas I."),
    ("Christmas I. apt", -10.4506, 105.6906, "CX"),  # airport, was AU
    ("Cayenne", 4.9220, -52.3130, "GF"),          # was FR
    ("Fort-de-France", 14.6160, -61.0580, "MQ"),  # was null
    ("Pointe-a-Pitre", 16.2410, -61.5330, "GP"),  # was FR
    ("Saint-Denis", -20.8820, 55.4500, "RE"),     # was FR
]

# The overlay must not steal any of these from their existing answer.
PARENT_TESTS = [
    ("Amsterdam", 52.3740, 4.8900, "NL"),
    ("Paris", 48.8570, 2.3520, "FR"),
    ("Sydney", -33.8690, 151.2090, "AU"),
    ("Wellington", -41.2890, 174.7770, "NZ"),
    ("Willemstad", 12.1170, -68.9330, "CW"),
    ("Oranjestad", 12.5240, -70.0270, "AW"),
]


def log(msg):
    print(msg, file=sys.stderr)


# --------------------------------------------------------------------------
# source
# --------------------------------------------------------------------------

def fetch_geojson(cache, urls):
    """Return a parsed FeatureCollection, downloading it once into `cache`."""
    if not os.path.exists(cache) or os.path.getsize(cache) < 100000:
        last = None
        for url in urls:
            try:
                log("downloading %s" % url)
                req = urllib.request.Request(
                    url, headers={"User-Agent": "sos-numbers-border-gen/1"})
                with urllib.request.urlopen(req, timeout=120) as r:
                    data = r.read()
                if len(data) < 100000:
                    raise ValueError("suspiciously small response")
                with open(cache, "wb") as fh:
                    fh.write(data)
                break
            except Exception as exc:      # noqa: BLE001 - report and try next
                last = exc
                log("  failed: %s" % exc)
        else:
            raise SystemExit("could not download any source variant: %s" % last)
    with open(cache, "r", encoding="utf-8") as fh:
        return json.load(fh)


def fetch_source():
    """The admin-0 countries source (the `countries` array)."""
    return fetch_geojson(CACHE, SOURCE_URLS)


def fetch_mapunits():
    """The admin-0 map-units source (the `subunits` overlay)."""
    return fetch_geojson(MU_CACHE, MAPUNITS_URLS)


def numbers_codes():
    """ISO codes that have their own emergency numbers, or None if unreadable.

    The overlay's only purpose is to hand the lookup a code with better
    emergency numbers than its parent's. A code with no entry in the dataset
    would make the phone show nothing where it previously showed the parent's
    working number, so those are excluded rather than added.
    """
    try:
        with open(NUMBERS, "r", encoding="utf-8") as fh:
            return set(json.load(fh)["countries"])
    except Exception as exc:              # noqa: BLE001 - overlay-filter only
        log("emergency_numbers.json unreadable (%s); overlay unfiltered" % exc)
        return None


def iso_code(props):
    """Resolve a real alpha-2 code for a feature, or None."""
    for key in ("ISO_A2", "ISO_A2_EH", "WB_A2"):
        val = props.get(key)
        if isinstance(val, str):
            val = val.strip().upper()
            if len(val) == 2 and val.isalpha():
                return val, key
    name = (props.get("NAME") or props.get("ADMIN") or "").strip()
    if name in NAME_PATCH:
        return NAME_PATCH[name], "NAME_PATCH"
    return None, None


def rings_of(geom):
    """Flatten a (Multi)Polygon into a list of coordinate rings."""
    if not geom:
        return []
    gtype = geom.get("type")
    coords = geom.get("coordinates") or []
    if gtype == "Polygon":
        return list(coords)
    if gtype == "MultiPolygon":
        out = []
        for poly in coords:
            out.extend(poly)
        return out
    return []


def quantise(ring, expand=False):
    """Scale to ints, drop consecutive duplicates, drop the closing point.

    With expand=True every point is rounded *away* from the ring centroid
    (ceil above it, floor below it) instead of to nearest. Rings smaller than
    the 0.001 deg grid - Vatican City, atolls, the Vatican-shaped hole in
    Italy - would otherwise collapse to a degenerate sliver that no longer
    contains its own interior. Outward rounding grows them by at most one
    grid cell (~110 m) and guarantees the original ring stays inside.
    """
    if expand and ring:
        cx = sum(p[0] for p in ring) / float(len(ring))
        cy = sum(p[1] for p in ring) / float(len(ring))
    out = []
    prev = None
    for pt in ring:
        if expand:
            fx = pt[0] * SCALE
            fy = pt[1] * SCALE
            x = int(math.ceil(fx)) if pt[0] >= cx else int(math.floor(fx))
            y = int(math.ceil(fy)) if pt[1] >= cy else int(math.floor(fy))
        else:
            x = int(round(pt[0] * SCALE))
            y = int(round(pt[1] * SCALE))
        if prev is not None and prev == (x, y):
            continue
        prev = (x, y)
        out.append(x)
        out.append(y)
    # rings are implicitly closed: strip a trailing point equal to the first
    while len(out) >= 4 and out[0] == out[-2] and out[1] == out[-1]:
        del out[-2:]
    return out


def simplify(pts, eps):
    """Ramer-Douglas-Peucker on a ring, endpoints preserved. eps in degrees."""
    n = len(pts)
    if eps <= 0 or n < 4:
        return pts
    keep = [False] * n
    keep[0] = keep[n - 1] = True
    eps2 = eps * eps
    stack = [(0, n - 1)]
    while stack:
        a, b = stack.pop()
        if b <= a + 1:
            continue
        ax, ay = pts[a][0], pts[a][1]
        bx, by = pts[b][0], pts[b][1]
        dx, dy = bx - ax, by - ay
        seg = dx * dx + dy * dy
        best, bi = -1.0, -1
        for i in range(a + 1, b):
            px, py = pts[i][0], pts[i][1]
            if seg == 0.0:
                t = 0.0
            else:
                t = ((px - ax) * dx + (py - ay) * dy) / seg
                t = 0.0 if t < 0.0 else (1.0 if t > 1.0 else t)
            ex = ax + t * dx - px
            ey = ay + t * dy - py
            d2 = ex * ex + ey * ey
            if d2 > best:
                best, bi = d2, i
        if best > eps2:
            keep[bi] = True
            stack.append((a, bi))
            stack.append((bi, b))
    return [pts[i] for i in range(n) if keep[i]]


def prepare_ring(ring):
    """Simplify + quantise. Falls back to unsimplified if simplifying kills it."""
    xs = [p[0] for p in ring]
    ys = [p[1] for p in ring]
    extent = max(max(xs) - min(xs), max(ys) - min(ys))
    if extent < TINY_RING_DEG:
        # smaller than a couple of grid cells: keep every point, round outward
        return quantise(ring, expand=True)
    if extent < SMALL_RING_DEG:
        # smaller than the simplification tolerance: keep every point
        q = quantise(ring)
        return q if len(q) // 2 >= MIN_RING_POINTS else quantise(ring, expand=True)
    q = quantise(simplify(ring, SIMPLIFY_EPS))
    if len(q) // 2 >= MIN_RING_POINTS:
        return q
    q = quantise(ring)                      # never lose a ring to simplification
    return q if len(q) // 2 >= MIN_RING_POINTS else quantise(ring, expand=True)


def delta_encode(ring):
    """[x0,y0, dx1,dy1, dx2,dy2, ...] - smaller numbers, ~2x smaller JSON."""
    out = [ring[0], ring[1]]
    px, py = ring[0], ring[1]
    for i in range(2, len(ring), 2):
        out.append(ring[i] - px)
        out.append(ring[i + 1] - py)
        px, py = ring[i], ring[i + 1]
    return out


def delta_decode(ring):
    """Inverse of delta_encode: flat absolute [lon,lat,...] scaled ints."""
    out = [ring[0], ring[1]]
    x, y = ring[0], ring[1]
    for i in range(2, len(ring), 2):
        x += ring[i]
        y += ring[i + 1]
        out.append(x)
        out.append(y)
    return out


# --------------------------------------------------------------------------
# build
# --------------------------------------------------------------------------

def collect(feats, admin_name=True):
    """Resolve codes, simplify + quantise every ring, merge features by code.

    Shared by both passes so `subunits` goes through exactly the pipeline
    `countries` does. With admin_name=True the main feature of a code takes
    its ADMIN-level name (admin-0: "Netherlands"); the map-units pass sets
    it False because there ADMIN is the *parent* ("Netherlands" for BQ,
    "Indian Ocean Territories" for CC) and NAME_LONG is the right label.
    Returns (merged, stats) where merged is iso -> {"n", "rings", "spare"}.
    """
    merged = {}
    stats = {"dropped_feats": [], "dropped_rings": 0, "rescued": [],
             "fallbacks": {}}

    for feat in feats:
        props = feat.get("properties") or {}
        name = (props.get("NAME") or props.get("ADMIN") or "?").strip()
        iso, via = iso_code(props)
        if not iso:
            stats["dropped_feats"].append(
                "%s (no resolvable alpha-2; ISO_A2=%r)" % (name, props.get("ISO_A2")))
            continue
        if via != "ISO_A2":
            stats["fallbacks"].setdefault(via, []).append("%s -> %s" % (name, iso))

        raw = rings_of(feat.get("geometry"))
        kept, spare = [], []
        for ring in raw:
            q = prepare_ring(ring)
            if len(q) // 2 >= MIN_RING_POINTS:
                kept.append(q)
            else:
                stats["dropped_rings"] += 1
                if q:
                    spare.append((len(ring), q))

        if not admin_name:
            name = (props.get("NAME_LONG") or name).strip()
        entry = merged.setdefault(iso, {"n": name, "rings": [], "spare": []})
        # keep the ADMIN-level name for the main feature of a code
        if (admin_name and props.get("ADM0_A3") and props.get("ISO_A2") == iso
                and not entry["rings"]):
            entry["n"] = (props.get("ADMIN") or name).strip()
        entry["rings"].extend(kept)
        entry["spare"].extend(spare)

    # never drop the last ring of a country: rescue the best discarded one
    for iso, entry in merged.items():
        if not entry["rings"] and entry["spare"]:
            entry["spare"].sort(reverse=True)
            entry["rings"].append(entry["spare"][0][1])
            stats["dropped_rings"] -= 1
            stats["rescued"].append(iso)
    return merged, stats


def bbox_of(rings):
    """[min_x, min_y, max_x, max_y] over every point of every (absolute) ring."""
    xs_min = ys_min = 10 ** 9
    xs_max = ys_max = -10 ** 9
    for r in rings:
        for i in range(0, len(r), 2):
            x, y = r[i], r[i + 1]
            if x < xs_min:
                xs_min = x
            if x > xs_max:
                xs_max = x
            if y < ys_min:
                ys_min = y
            if y > ys_max:
                ys_max = y
    return [xs_min, ys_min, xs_max, ys_max]


def emit(merged, stats):
    """merged -> sorted list of {c, n, b, r} objects with delta-encoded rings."""
    out = []
    for iso in sorted(merged):
        entry = merged[iso]
        rings = entry["rings"]
        if not rings:
            stats["dropped_feats"].append("%s (%s): no usable rings" % (entry["n"], iso))
            continue
        out.append({
            "c": iso,
            "n": entry["n"],
            "b": bbox_of(rings),
            "r": [delta_encode(r) for r in rings],
        })
    return out


def report_pass(label, objs, stats):
    n_rings = sum(len(c["r"]) for c in objs)
    n_pts = sum(len(r) // 2 for c in objs for r in c["r"])
    log("%s: %d   rings: %d   points: %d" % (label, len(objs), n_rings, n_pts))
    for via, items in sorted(stats["fallbacks"].items()):
        log("  iso fallback via %s: %s" % (via, ", ".join(sorted(items))))
    log("  rings dropped (< %d distinct points after quantisation): %d"
        % (MIN_RING_POINTS, stats["dropped_rings"]))
    if stats["rescued"]:
        log("  rings rescued (only ring for that code): %s" % ", ".join(stats["rescued"]))
    if stats["dropped_feats"]:
        log("  features dropped: %d" % len(stats["dropped_feats"]))
        for d in stats["dropped_feats"]:
            log("    - %s" % d)
    else:
        log("  features dropped: none")


def select_subunits(feats, emitted, allowed):
    """Map-units features worth overlaying, computed dynamically.

    Keeps every feature whose code the admin-0 pass did NOT emit, provided
    the code has its own entry in emergency_numbers.json (`allowed`; None
    means the dataset was unreadable and no filter is applied). Everything
    excluded is logged with the reason. Returns (features, overlay_codes).
    """
    chosen, excluded, no_code, parents = [], {}, [], 0
    for feat in feats:
        props = feat.get("properties") or {}
        name = (props.get("NAME") or props.get("ADMIN") or "?").strip()
        iso, _ = iso_code(props)
        if not iso:
            no_code.append("%s (ISO_A2=%r)" % (name, props.get("ISO_A2")))
            continue
        if iso in emitted:
            parents += 1            # already covered by `countries`, skip
            continue
        if allowed is not None and iso not in allowed:
            why = "no entry in emergency_numbers.json, parent's numbers are the better answer"
            if iso[0] == "X" and iso != "XK":
                why += "; user-assigned code, not ISO 3166-1"
            excluded[iso] = "%s: %s" % (name, why)
            continue
        chosen.append(feat)

    codes = sorted({iso_code(f.get("properties") or {})[0] for f in chosen})
    log("map-units features: %d   already in countries: %d" % (len(feats), parents))
    log("overlay codes (%d): %s" % (len(codes), " ".join(codes)))
    for iso in sorted(excluded):
        log("  excluded %s - %s" % (iso, excluded[iso]))
    for item in no_code:
        log("  excluded %s - no resolvable alpha-2" % item)
    return chosen, codes


def build():
    src = fetch_source()
    feats = src.get("features") or []
    log("source features: %d" % len(feats))

    merged, stats = collect(feats)
    countries = emit(merged, stats)
    emitted = {c["c"] for c in countries}

    # second pass: the inhabited territories admin-0 folds into their parent
    mu_feats = fetch_mapunits().get("features") or []
    su_feats, overlay = select_subunits(mu_feats, emitted, numbers_codes())
    su_merged, su_stats = collect(su_feats, admin_name=False)
    subunits = emit(su_merged, su_stats)
    lost = sorted(set(overlay) - {s["c"] for s in subunits})
    if lost:
        raise SystemExit("overlay codes lost all their rings: %s" % " ".join(lost))

    doc = {
        "schema": SCHEMA,
        "source": SOURCE_NAME,
        "source_url": SOURCE_URLS[0],
        "scale": SCALE,
        "quantisation": ("degrees * %d, rounded to int (3 dp, ~110 m); "
                         "divide by scale to get degrees. Rings are also "
                         "Douglas-Peucker simplified with eps=%s deg (~220 m) "
                         "before quantising" % (SCALE, SIMPLIFY_EPS)),
        "encoding": "delta",
        "ring_format": ("flat scaled-int array [x0,y0,dx1,dy1,dx2,dy2,...]: "
                        "first pair absolute (lon,lat), every later pair a "
                        "delta from the previous point. Rings are implicitly "
                        "closed (last point != first). All rings of a country "
                        "are tested together with the even-odd rule, so "
                        "interior holes are plain rings"),
        "bbox_format": "[min_lon,min_lat,max_lon,max_lat] scaled ints",
        "countries": countries,
        "subunits_source": MAPUNITS_NAME,
        "subunits_source_url": MAPUNITS_URLS[0],
        "subunits_note": ("overseas territories that admin-0 folds into their "
                          "parent state but that have their own ISO code and "
                          "their own emergency numbers. Same object shape and "
                          "encoding as `countries`. Lookup order: test "
                          "`subunits` first, fall back to `countries`"),
        "subunits": subunits,
    }

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, separators=(",", ":"), ensure_ascii=False)

    size = os.path.getsize(OUT)
    log("")
    report_pass("countries", countries, stats)
    report_pass("subunits", subunits, su_stats)
    log("file: %s  (%d bytes, %.2f MB)" % (OUT, size, size / 1048576.0))
    return doc


# --------------------------------------------------------------------------
# verify  (reads the FINAL asset, exactly as Dart will)
# --------------------------------------------------------------------------

def point_in_country(lon, lat, country, scale):
    """Even-odd ray cast over every ring of the country. bbox pre-reject."""
    x = lon * scale
    y = lat * scale
    b = country["b"]
    if x < b[0] or x > b[2] or y < b[1] or y > b[3]:
        return False
    inside = False
    for enc in country["r"]:
        r = delta_decode(enc)
        n = len(r) // 2
        j = n - 1
        for i in range(n):
            xi, yi = r[2 * i], r[2 * i + 1]
            xj, yj = r[2 * j], r[2 * j + 1]
            if (yi > y) != (yj > y):
                if x < (xj - xi) * (y - yi) / float(yj - yi) + xi:
                    inside = not inside
            j = i
    return inside


def locate(lon, lat, doc):
    """All codes whose polygons contain the point, `subunits` first.

    This is the exact precedence the Dart side must use: an overlay hit
    wins outright, `countries` is only the fallback.
    """
    scale = doc["scale"]
    hits = [c["c"] for c in doc.get("subunits", [])
            if point_in_country(lon, lat, c, scale)]
    hits += [c["c"] for c in doc["countries"]
             if point_in_country(lon, lat, c, scale)]
    return hits


def run_table(title, tests, doc):
    """Print one verification table; return (failures, source_gaps)."""
    print(title)
    print("%-16s %10s %11s  %-10s %-10s %s"
          % ("place", "lat", "lon", "expected", "got", "result"))
    print("-" * 74)
    failures = gaps = 0
    for row in tests:
        name, lat, lon, expect = row[:4]
        gap_note = row[4] if len(row) > 4 else None
        hits = locate(lon, lat, doc)
        got = hits[0] if hits else None
        extra = "" if len(hits) < 2 else " (also %s)" % ",".join(hits[1:])
        if expect is None:
            ok = got is None
            exp_s = "null"
        elif "|" in expect:
            ok = got in expect.split("|")
            exp_s = expect.replace("|", " or ")
        else:
            ok = got == expect
            exp_s = expect
        if ok:
            result = "PASS"
        elif gap_note and got is None:
            gaps += 1
            result = "GAP  - " + gap_note
        else:
            failures += 1
            result = "FAIL"
        print("%-16s %10.4f %11.4f  %-10s %-10s %s%s"
              % (name, lat, lon, exp_s, got if got else "null", result, extra))
    print("-" * 74)
    print("%d/%d passed%s" % (len(tests) - failures - gaps, len(tests),
                              "" if not gaps else ", %d known source gap(s)" % gaps))
    print("")
    return failures, gaps


def check_shape(label, objs):
    """Structural asserts on an emitted array; returns number of problems."""
    problems = 0

    def bad(msg):
        nonlocal problems
        problems += 1
        print("  SHAPE FAIL %s: %s" % (label, msg))

    seen = set()
    for obj in objs:
        c = obj.get("c")
        if not (isinstance(c, str) and len(c) == 2 and c.isalpha() and c.isupper()):
            bad("bad code %r" % (c,))
        if c in seen:
            bad("duplicate code %s" % c)
        seen.add(c)
        if not isinstance(obj.get("n"), str) or not obj["n"]:
            bad("%s: bad name %r" % (c, obj.get("n")))
        b = obj.get("b")
        if not (isinstance(b, list) and len(b) == 4
                and all(type(v) is int for v in b)):
            bad("%s: bbox not 4 ints: %r" % (c, b))
            continue
        rings = obj.get("r")
        if not isinstance(rings, list) or not rings:
            bad("%s: no rings" % c)
            continue
        xs_min = ys_min = 10 ** 9
        xs_max = ys_max = -10 ** 9
        for enc in rings:
            if not all(type(v) is int for v in enc):
                bad("%s: non-int value in ring" % c)
            if len(enc) % 2 or len(enc) < 2 * MIN_RING_POINTS:
                bad("%s: ring length %d (must be even and >= %d)"
                    % (c, len(enc), 2 * MIN_RING_POINTS))
            r = delta_decode(enc)
            for i in range(0, len(r), 2):
                xs_min = min(xs_min, r[i])
                xs_max = max(xs_max, r[i])
                ys_min = min(ys_min, r[i + 1])
                ys_max = max(ys_max, r[i + 1])
        if b != [xs_min, ys_min, xs_max, ys_max]:
            bad("%s: bbox %r != decoded extent %r"
                % (c, b, [xs_min, ys_min, xs_max, ys_max]))
    print("shape %-9s %d entries, %s" % (label + ":", len(objs),
                                        "OK" if not problems else "%d PROBLEMS" % problems))
    return problems


def verify():
    if not os.path.exists(OUT):
        raise SystemExit("asset not built yet: %s" % OUT)
    with open(OUT, "r", encoding="utf-8") as fh:
        doc = json.load(fh)
    size = os.path.getsize(OUT)
    subunits = doc.get("subunits", [])

    print("asset: %s" % OUT)
    print("size : %d bytes (%.2f MB)" % (size, size / 1048576.0))
    print("schema: %s   countries: %d   subunits: %d (%s)"
          % (doc.get("schema"), len(doc["countries"]), len(subunits),
             " ".join(s["c"] for s in subunits) or "none"))
    print("")

    failures = 0
    if doc.get("schema") != SCHEMA:
        print("FAIL: schema is %r, generator expects %d" % (doc.get("schema"), SCHEMA))
        failures += 1
    overlap = {s["c"] for s in subunits} & {c["c"] for c in doc["countries"]}
    if overlap:
        print("FAIL: codes in both subunits and countries: %s" % " ".join(sorted(overlap)))
        failures += 1
    failures += check_shape("countries", doc["countries"])
    failures += check_shape("subunits", subunits)
    print("")

    gaps = 0
    for title, tests in (("overseas territories (subunits overlay)", SUBUNIT_TESTS),
                         ("parents unchanged by the overlay", PARENT_TESTS),
                         ("original spec table", TESTS)):
        f, g_ = run_table(title, tests, doc)
        failures += f
        gaps += g_
    print("TOTAL: %s%s" % ("all passed" if not failures else "%d FAILURES" % failures,
                           "" if not gaps else
                           ", %d known source gap(s) (GAP rows: NE 10m has no land "
                           "under that coordinate; the raw source polygon misses it too)"
                           % gaps))
    return failures


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--build", action="store_true", help="build the asset")
    ap.add_argument("--verify", action="store_true",
                    help="run the point-in-polygon test table on the asset")
    args = ap.parse_args()
    if not args.build and not args.verify:
        args.build = True
    if args.build:
        build()
    if args.verify:
        return 1 if verify() else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
