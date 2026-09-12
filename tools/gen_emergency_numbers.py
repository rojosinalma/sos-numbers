#!/usr/bin/env python3
"""Generate assets/data/emergency_numbers.json from English Wikipedia.

Source page: "List of emergency telephone numbers" (raw wikitext via the MediaWiki
action=parse API).  Standard library only, no third-party dependencies.

Usage:
    python3 tools/gen_emergency_numbers.py            # use cache if present
    python3 tools/gen_emergency_numbers.py --refresh  # force refetch
"""

from __future__ import annotations

import argparse
import datetime as _dt
import html
import json
import os
import re
import sys
import unicodedata
import urllib.request

# --------------------------------------------------------------------------- #
# Paths / constants
# --------------------------------------------------------------------------- #

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(TOOLS_DIR)
CACHE_PATH = os.path.join(TOOLS_DIR, "wikitext.cache.json")
OUT_PATH = os.path.join(PROJECT_DIR, "assets", "data", "emergency_numbers.json")

PAGE = "List_of_emergency_telephone_numbers"
API_URL = (
    "https://en.wikipedia.org/w/api.php?action=parse&page=" + PAGE +
    "&prop=wikitext&format=json&formatversion=2"
)
SOURCE_URL = "https://en.wikipedia.org/wiki/List_of_emergency_telephone_numbers"
USER_AGENT = "sos-numbers-dataset-generator/1.0 (offline emergency dialer asset)"

SCHEMA = 1
NOTES_MAX = 240
NUMBER_RE = re.compile(r"^[0-9*#+]{2,12}$")
# Numbers that are meaningful as an "all services" number when shared.
UNIVERSAL_NUMBERS = {"112", "911", "999", "000", "111"}

FIELDS = ("general", "police", "ambulance", "fire")

# --------------------------------------------------------------------------- #
# ISO 3166-1 alpha-2: canonical English name + aliases used by Wikipedia
# All 249 officially assigned codes, plus XK (user-assigned, Kosovo).
# --------------------------------------------------------------------------- #

ISO_ENTRIES: dict[str, tuple[str, tuple[str, ...]]] = {
    "AD": ("Andorra", ()),
    "AE": ("United Arab Emirates", ("UAE", "Emirates")),
    "AF": ("Afghanistan", ("Islamic Emirate of Afghanistan",)),
    "AG": ("Antigua and Barbuda", ("Antigua & Barbuda", "Antigua")),
    "AI": ("Anguilla", ()),
    "AL": ("Albania", ()),
    "AM": ("Armenia", ()),
    "AO": ("Angola", ()),
    "AQ": ("Antarctica", ()),
    "AR": ("Argentina", ()),
    "AS": ("American Samoa", ("Samoa (American)",)),
    "AT": ("Austria", ()),
    "AU": ("Australia", ()),
    "AW": ("Aruba", ()),
    "AX": ("Åland Islands", ("Aland Islands", "Åland", "Aland")),
    "AZ": ("Azerbaijan", ()),
    "BA": ("Bosnia and Herzegovina", ("Bosnia & Herzegovina", "Bosnia")),
    "BB": ("Barbados", ()),
    "BD": ("Bangladesh", ()),
    "BE": ("Belgium", ()),
    "BF": ("Burkina Faso", ()),
    "BG": ("Bulgaria", ()),
    "BH": ("Bahrain", ()),
    "BI": ("Burundi", ()),
    "BJ": ("Benin", ()),
    "BL": ("Saint Barthélemy", ("Saint Barthelemy", "St Barthelemy", "St. Barthelemy")),
    "BM": ("Bermuda", ()),
    "BN": ("Brunei", ("Brunei Darussalam",)),
    "BO": ("Bolivia", ("Plurinational State of Bolivia",)),
    "BQ": ("Caribbean Netherlands", (
        "Bonaire, Sint Eustatius and Saba", "Caribbean NL", "Bonaire",
        "Bonaire, Saint Eustatius and Saba", "BES islands")),
    "BR": ("Brazil", ()),
    "BS": ("Bahamas", ("The Bahamas",)),
    "BT": ("Bhutan", ()),
    "BV": ("Bouvet Island", ()),
    "BW": ("Botswana", ()),
    "BY": ("Belarus", ()),
    "BZ": ("Belize", ()),
    "CA": ("Canada", ()),
    "CC": ("Cocos (Keeling) Islands", (
        "Cocos (Keeling) Island", "Cocos Islands", "Keeling Islands")),
    "CD": ("Democratic Republic of the Congo", (
        "DR Congo", "DRC", "Democratic Republic of Congo", "Congo-Kinshasa",
        "Congo (Dem. Rep.)", "Congo, Democratic Republic of the", "Zaire")),
    "CF": ("Central African Republic", ("Central African Rep.",)),
    "CG": ("Republic of the Congo", (
        "Congo", "Republic of Congo", "Congo-Brazzaville", "Congo (Rep.)",
        "Congo, Republic of the")),
    "CH": ("Switzerland", ("Swiss Confederation",)),
    "CI": ("Côte d'Ivoire", ("Cote d'Ivoire", "Ivory Coast")),
    "CK": ("Cook Islands", ()),
    "CL": ("Chile", ()),
    "CM": ("Cameroon", ()),
    "CN": ("China", (
        "People's Republic of China", "PR China", "PRC", "Mainland China")),
    "CO": ("Colombia", ()),
    "CR": ("Costa Rica", ()),
    "CU": ("Cuba", ()),
    "CV": ("Cape Verde", ("Cabo Verde",)),
    "CW": ("Curaçao", ("Curacao",)),
    "CX": ("Christmas Island", ()),
    "CY": ("Cyprus", ()),
    "CZ": ("Czechia", ("Czech Republic",)),
    "DE": ("Germany", ("Federal Republic of Germany",)),
    "DJ": ("Djibouti", ()),
    "DK": ("Denmark", ()),
    "DM": ("Dominica", ()),
    "DO": ("Dominican Republic", ()),
    "DZ": ("Algeria", ()),
    "EC": ("Ecuador", ()),
    "EE": ("Estonia", ()),
    "EG": ("Egypt", ()),
    "EH": ("Western Sahara", ("Sahrawi Arab Democratic Republic",)),
    "ER": ("Eritrea", ()),
    "ES": ("Spain", ()),
    "ET": ("Ethiopia", ()),
    "FI": ("Finland", ()),
    "FJ": ("Fiji", ()),
    "FK": ("Falkland Islands", ("Falkland Islands (Malvinas)", "Malvinas")),
    "FM": ("Micronesia", ("Federated States of Micronesia",)),
    "FO": ("Faroe Islands", ("Faeroe Islands",)),
    "FR": ("France", ("French Republic",)),
    "GA": ("Gabon", ()),
    "GB": ("United Kingdom", (
        "UK", "Great Britain", "Britain", "Britain (UK)",
        "United Kingdom of Great Britain and Northern Ireland", "England")),
    "GD": ("Grenada", ()),
    "GE": ("Georgia", ()),
    "GF": ("French Guiana", ()),
    "GG": ("Guernsey", ("Bailiwick of Guernsey",)),
    "GH": ("Ghana", ()),
    "GI": ("Gibraltar", ()),
    "GL": ("Greenland", ()),
    "GM": ("Gambia", ("The Gambia",)),
    "GN": ("Guinea", ()),
    "GP": ("Guadeloupe", ()),
    "GQ": ("Equatorial Guinea", ()),
    "GR": ("Greece", ("Hellenic Republic", "Ellada")),
    "GS": ("South Georgia and the South Sandwich Islands", (
        "South Georgia & the South Sandwich Islands", "South Georgia")),
    "GT": ("Guatemala", ()),
    "GU": ("Guam", ()),
    "GW": ("Guinea-Bissau", ()),
    "GY": ("Guyana", ()),
    "HK": ("Hong Kong", ("Hong Kong SAR", "Hong Kong SAR China")),
    "HM": ("Heard Island and McDonald Islands", (
        "Heard Island & McDonald Islands",)),
    "HN": ("Honduras", ()),
    "HR": ("Croatia", ()),
    "HT": ("Haiti", ()),
    "HU": ("Hungary", ()),
    "ID": ("Indonesia", ()),
    "IE": ("Ireland", ("Republic of Ireland", "Éire", "Eire")),
    "IL": ("Israel", ()),
    "IM": ("Isle of Man", ()),
    "IN": ("India", ()),
    "IO": ("British Indian Ocean Territory", ("Diego Garcia",)),
    "IQ": ("Iraq", ()),
    "IR": ("Iran", ("Islamic Republic of Iran", "Persia")),
    "IS": ("Iceland", ()),
    "IT": ("Italy", ()),
    "JE": ("Jersey", ("Bailiwick of Jersey",)),
    "JM": ("Jamaica", ()),
    "JO": ("Jordan", ()),
    "JP": ("Japan", ()),
    "KE": ("Kenya", ()),
    "KG": ("Kyrgyzstan", ("Kyrgyz Republic",)),
    "KH": ("Cambodia", ("Kampuchea",)),
    "KI": ("Kiribati", ()),
    "KM": ("Comoros", ("The Comoros",)),
    "KN": ("Saint Kitts and Nevis", ("St Kitts & Nevis", "Saint Kitts")),
    "KP": ("North Korea", (
        "Democratic People's Republic of Korea", "DPRK", "Korea, North",
        "Korea (North)")),
    "KR": ("South Korea", (
        "Republic of Korea", "Korea, South", "Korea (South)", "Korea", "ROK")),
    "KW": ("Kuwait", ()),
    "KY": ("Cayman Islands", ()),
    "KZ": ("Kazakhstan", ()),
    "LA": ("Laos", ("Lao People's Democratic Republic", "Lao PDR")),
    "LB": ("Lebanon", ()),
    "LC": ("Saint Lucia", ("St Lucia",)),
    "LI": ("Liechtenstein", ()),
    "LK": ("Sri Lanka", ("Ceylon",)),
    "LR": ("Liberia", ()),
    "LS": ("Lesotho", ()),
    "LT": ("Lithuania", ()),
    "LU": ("Luxembourg", ()),
    "LV": ("Latvia", ()),
    "LY": ("Libya", ()),
    "MA": ("Morocco", ()),
    "MC": ("Monaco", ()),
    "MD": ("Moldova", ("Republic of Moldova",)),
    "ME": ("Montenegro", ()),
    "MF": ("Saint Martin", (
        "Saint Martin (French part)", "St Martin (French)",
        "Collectivity of Saint Martin")),
    "MG": ("Madagascar", ()),
    "MH": ("Marshall Islands", ()),
    "MK": ("North Macedonia", (
        "Macedonia", "Republic of North Macedonia", "FYROM")),
    "ML": ("Mali", ()),
    "MM": ("Myanmar", ("Burma", "Myanmar (Burma)")),
    "MN": ("Mongolia", ()),
    "MO": ("Macau", ("Macao", "Macau SAR")),
    "MP": ("Northern Mariana Islands", ()),
    "MQ": ("Martinique", ()),
    "MR": ("Mauritania", ()),
    "MS": ("Montserrat", ()),
    "MT": ("Malta", ()),
    "MU": ("Mauritius", ()),
    "MV": ("Maldives", ()),
    "MW": ("Malawi", ()),
    "MX": ("Mexico", ()),
    "MY": ("Malaysia", ()),
    "MZ": ("Mozambique", ()),
    "NA": ("Namibia", ()),
    "NC": ("New Caledonia", ()),
    "NE": ("Niger", ()),
    "NF": ("Norfolk Island", ()),
    "NG": ("Nigeria", ()),
    "NI": ("Nicaragua", ()),
    "NL": ("Netherlands", ("The Netherlands", "Holland")),
    "NO": ("Norway", ()),
    "NP": ("Nepal", ()),
    "NR": ("Nauru", ()),
    "NU": ("Niue", ()),
    "NZ": ("New Zealand", ("Aotearoa",)),
    "OM": ("Oman", ()),
    "PA": ("Panama", ()),
    "PE": ("Peru", ()),
    "PF": ("French Polynesia", ("Tahiti",)),
    "PG": ("Papua New Guinea", ()),
    "PH": ("Philippines", ("The Philippines",)),
    "PK": ("Pakistan", ()),
    "PL": ("Poland", ()),
    "PM": ("Saint Pierre and Miquelon", ("St Pierre & Miquelon",)),
    "PN": ("Pitcairn Islands", ("Pitcairn",)),
    "PR": ("Puerto Rico", ()),
    "PS": ("Palestine", (
        "State of Palestine", "Palestinian territories", "Palestine, State of",
        "West Bank", "Gaza", "Gaza Strip")),
    "PT": ("Portugal", ()),
    "PW": ("Palau", ()),
    "PY": ("Paraguay", ()),
    "QA": ("Qatar", ()),
    "RE": ("Réunion", ("Reunion",)),
    "RO": ("Romania", ()),
    "RS": ("Serbia", ()),
    "RU": ("Russia", ("Russian Federation",)),
    "RW": ("Rwanda", ()),
    "SA": ("Saudi Arabia", ()),
    "SB": ("Solomon Islands", ()),
    "SC": ("Seychelles", ()),
    "SD": ("Sudan", ()),
    "SE": ("Sweden", ()),
    "SG": ("Singapore", ()),
    "SH": ("Saint Helena, Ascension and Tristan da Cunha", (
        "Saint Helena", "St Helena", "Ascension Island", "Ascension",
        "Tristan da Cunha", "Saint Helena, Ascension and Tristan da Cunha")),
    "SI": ("Slovenia", ()),
    "SJ": ("Svalbard and Jan Mayen", ("Svalbard", "Jan Mayen")),
    "SK": ("Slovakia", ()),
    "SL": ("Sierra Leone", ()),
    "SM": ("San Marino", ()),
    "SN": ("Senegal", ()),
    "SO": ("Somalia", ()),
    "SR": ("Suriname", ()),
    "SS": ("South Sudan", ()),
    "ST": ("Sao Tome and Principe", (
        "São Tomé and Príncipe", "Sao Tome & Principe", "Sao Tome")),
    "SV": ("El Salvador", ()),
    "SX": ("Sint Maarten", ("Sint Maarten (Dutch part)", "St Maarten (Dutch)")),
    "SY": ("Syria", ("Syrian Arab Republic",)),
    "SZ": ("Eswatini", ("Swaziland", "Eswatini (Swaziland)")),
    "TC": ("Turks and Caicos Islands", (
        "Turks and Caicos", "Turks & Caicos Is", "Turks & Caicos Islands")),
    "TD": ("Chad", ()),
    "TF": ("French Southern Territories", (
        "French Southern and Antarctic Lands", "French S. Terr.")),
    "TG": ("Togo", ()),
    "TH": ("Thailand", ("Siam",)),
    "TJ": ("Tajikistan", ()),
    "TK": ("Tokelau", ()),
    "TL": ("Timor-Leste", ("East Timor",)),
    "TM": ("Turkmenistan", ()),
    "TN": ("Tunisia", ()),
    "TO": ("Tonga", ()),
    "TR": ("Turkey", ("Türkiye", "Turkiye")),
    "TT": ("Trinidad and Tobago", ("Trinidad & Tobago", "Trinidad")),
    "TV": ("Tuvalu", ()),
    "TW": ("Taiwan", (
        "Republic of China", "Chinese Taipei", "Taiwan, Province of China")),
    "TZ": ("Tanzania", ("United Republic of Tanzania",)),
    "UA": ("Ukraine", ()),
    "UG": ("Uganda", ()),
    "UM": ("United States Minor Outlying Islands", (
        "US minor outlying islands", "U.S. Minor Outlying Islands")),
    "US": ("United States", (
        "United States of America", "USA", "U.S.A.", "U.S.", "America")),
    "UY": ("Uruguay", ()),
    "UZ": ("Uzbekistan", ()),
    "VA": ("Vatican City", ("Holy See", "Vatican", "Vatican City State")),
    "VC": ("Saint Vincent and the Grenadines", (
        "St Vincent", "Saint Vincent", "St Vincent & the Grenadines")),
    "VE": ("Venezuela", ("Bolivarian Republic of Venezuela",)),
    "VG": ("British Virgin Islands", (
        "Virgin Islands (UK)", "Virgin Islands, British")),
    "VI": ("United States Virgin Islands", (
        "U.S. Virgin Islands", "US Virgin Islands", "Virgin Islands (US)",
        "Virgin Islands, U.S.", "American Virgin Islands")),
    "VN": ("Vietnam", ("Viet Nam",)),
    "VU": ("Vanuatu", ()),
    "WF": ("Wallis and Futuna", ("Wallis & Futuna", "Wallis and Futuna Islands")),
    "WS": ("Samoa", ("Samoa (western)", "Western Samoa")),
    "YE": ("Yemen", ()),
    "YT": ("Mayotte", ()),
    "ZA": ("South Africa", ()),
    "ZM": ("Zambia", ()),
    "ZW": ("Zimbabwe", ()),
    # Not officially assigned by ISO 3166-1; XK is the de-facto user-assigned
    # code for Kosovo and is what applications expect.
    "XK": ("Kosovo", ("Republic of Kosovo",)),
}

# Source rows that intentionally have no ISO 3166-1 alpha-2 code.  They are
# still logged, but flagged as expected so real regressions stand out.
KNOWN_NON_ISO = {
    "abkhazia", "south ossetia", "transnistria", "northern cyprus",
    "akrotiri dhekelia", "clipperton island",
}


def _norm_name(name: str) -> str:
    """Normalise a country name for dictionary lookup."""
    n = unicodedata.normalize("NFKD", name)
    n = "".join(c for c in n if not unicodedata.combining(c))
    n = n.lower()
    n = n.replace("&", " and ")
    n = re.sub(r"[’'`´.,()\[\]/\\-]", " ", n)
    n = re.sub(r"\s+", " ", n).strip()
    for prefix in ("the ",):
        if n.startswith(prefix):
            n = n[len(prefix):]
    n = re.sub(r"\band\b", " ", n)
    n = re.sub(r"\bof\b", " ", n)
    n = re.sub(r"\s+", " ", n).strip()
    return n


def _build_name_to_iso() -> dict[str, str]:
    mapping: dict[str, str] = {}
    for code, (canonical, aliases) in ISO_ENTRIES.items():
        for name in (canonical, *aliases):
            key = _norm_name(name)
            if key in mapping and mapping[key] != code:
                raise SystemExit(
                    f"ISO alias conflict: {name!r} -> {mapping[key]} and {code}")
            mapping[key] = code
    return mapping


NAME_TO_ISO = _build_name_to_iso()

# --------------------------------------------------------------------------- #
# Curated overrides, applied after parsing.  Only the listed fields are forced.
# --------------------------------------------------------------------------- #

OVERRIDES: dict[str, dict[str, str]] = {
    "US": {"general": "911", "police": "911", "ambulance": "911", "fire": "911"},
    "CA": {"general": "911", "police": "911", "ambulance": "911", "fire": "911"},
    "MX": {"general": "911", "police": "911", "ambulance": "911", "fire": "911"},
    "GB": {"police": "999", "general": "999"},
    "IE": {"general": "112", "police": "112", "ambulance": "112", "fire": "112"},
    "DE": {"police": "110", "fire": "112", "ambulance": "112", "general": "112"},
    "FR": {"police": "17", "fire": "18", "ambulance": "15", "general": "112"},
    "ES": {"general": "112"},
    "IT": {"general": "112"},
    "NL": {"general": "112"},
    "BE": {"general": "112"},
    "PT": {"general": "112"},
    "AT": {"general": "112"},
    "PL": {"general": "112"},
    "SE": {"general": "112"},
    "NO": {"general": "112"},
    "DK": {"general": "112"},
    "FI": {"general": "112"},
    "GR": {"general": "112"},
    "TR": {"general": "112"},
    "UA": {"general": "112"},
    "CH": {"general": "112", "police": "117", "fire": "118", "ambulance": "144"},
    "RU": {"general": "112", "police": "102", "ambulance": "103", "fire": "101"},
    "JP": {"police": "110", "fire": "119", "ambulance": "119"},
    "KR": {"police": "112", "fire": "119", "ambulance": "119"},
    "CN": {"police": "110", "fire": "119", "ambulance": "120"},
    "IN": {"general": "112"},
    "ID": {"general": "112"},
    "PH": {"general": "911"},
    "MY": {"general": "999"},
    "AU": {"general": "000"},
    "NZ": {"general": "111"},
    "SG": {"police": "999", "fire": "995", "ambulance": "995"},
    "TH": {"police": "191", "ambulance": "1669", "fire": "199"},
    "VN": {"police": "113", "fire": "114", "ambulance": "115"},
    "ZA": {"police": "10111", "ambulance": "10177", "general": "112"},
    "EG": {"police": "122", "ambulance": "123", "fire": "180"},
    "MA": {"police": "19", "ambulance": "15"},
    "BR": {"police": "190", "ambulance": "192", "fire": "193"},
    "AR": {"general": "911", "police": "101", "fire": "100", "ambulance": "107"},
    "CL": {"police": "133", "fire": "132", "ambulance": "131"},
    "CO": {"general": "123"},
    "PE": {"general": "105"},
    "UY": {"general": "911"},
    "IL": {"police": "100", "fire": "102", "ambulance": "101"},
    "AE": {"general": "999", "ambulance": "998", "fire": "997"},
    "SA": {"police": "999", "ambulance": "997", "fire": "998"},
    "QA": {"general": "999"},
    "KE": {"general": "999"},
    "NG": {"general": "112"},
    "GH": {"general": "112"},
    "TZ": {"general": "112"},
    "ET": {"general": "991"},
    "PK": {"general": "15"},
    "BD": {"general": "999"},
    "LK": {"general": "119"},
    "NP": {"general": "100"},
    "KZ": {"general": "112"},
    "GE": {"general": "112"},
    "AM": {"general": "112"},
    "AZ": {"general": "112"},
}

# Extra note text guaranteed to be present for a few countries.
NOTE_ADDENDA = {
    "GB": "112 also works.",
}

# --------------------------------------------------------------------------- #
# Fetching
# --------------------------------------------------------------------------- #


def fetch_wikitext(refresh: bool = False) -> str:
    if not refresh and os.path.exists(CACHE_PATH):
        with open(CACHE_PATH, encoding="utf-8") as fh:
            payload = json.load(fh)
    else:
        req = urllib.request.Request(API_URL, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode("utf-8")
        payload = json.loads(raw)
        with open(CACHE_PATH, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False)
        print(f"fetched and cached {CACHE_PATH}", file=sys.stderr)
    return payload["parse"]["wikitext"]


# --------------------------------------------------------------------------- #
# Wikitext cleaning
# --------------------------------------------------------------------------- #

REF_SELF_CLOSING = re.compile(r"<ref[^>]*/\s*>", re.I)
REF_BLOCK = re.compile(r"<ref[^>]*>.*?</ref\s*>", re.I | re.S)
COMMENT = re.compile(r"<!--.*?-->", re.S)

# Templates whose first positional argument is the visible text.
KEEP_FIRST_ARG = {"nowrap", "nobr", "ill", "lang", "linktext", "sic", "wrap"}
# Templates that contribute nothing to plain text.
DROP_TEMPLATES = {
    "efn", "efn-ua", "notetag", "ref", "refn", "sfn", "citation needed",
    "cn", "fact", "citation", "cite web", "cite news", "cite book",
    "cite journal", "cite tweet", "cite press release", "webarchive",
    "legend", "legend-col", "columns-list", "reflist", "notelist",
    "short description", "pp-semi-indef", "see also", "portal", "val",
    "flagicon", "flagcountry", "flagdeco", "clarify", "dubious",
    "better source needed", "update inline", "when",
}
FLAG_TEMPLATES = {"flag", "flag list", "flagu", "flagcountry", "flagicon"}


def _split_template_args(body: str) -> list[str]:
    """Split a template body on top-level pipes."""
    args, depth_c, depth_b, buf = [], 0, 0, []
    i = 0
    while i < len(body):
        ch = body[i]
        nxt = body[i:i + 2]
        if nxt == "{{":
            depth_c += 1
            buf.append(nxt)
            i += 2
            continue
        if nxt == "}}":
            depth_c -= 1
            buf.append(nxt)
            i += 2
            continue
        if nxt == "[[":
            depth_b += 1
            buf.append(nxt)
            i += 2
            continue
        if nxt == "]]":
            depth_b -= 1
            buf.append(nxt)
            i += 2
            continue
        if ch == "|" and depth_c == 0 and depth_b == 0:
            args.append("".join(buf))
            buf = []
            i += 1
            continue
        buf.append(ch)
        i += 1
    args.append("".join(buf))
    return args


def _render_template(name: str, args: list[str]) -> str:
    key = name.strip().lower()
    named = {}
    positional = []
    for a in args:
        m = re.match(r"^\s*([A-Za-z0-9_-]+)\s*=\s*(.*)$", a, re.S)
        if m:
            named[m.group(1).lower()] = m.group(2).strip()
        else:
            positional.append(a.strip())
    if key in FLAG_TEMPLATES:
        if named.get("name"):
            return named["name"]
        if key in ("flagicon", "flagdeco"):
            return ""
        return positional[0] if positional else ""
    if key in KEEP_FIRST_ARG:
        if key == "ill":
            return named.get("lt") or (positional[0] if positional else "")
        return positional[0] if positional else ""
    if key in DROP_TEMPLATES or key.startswith("cite ") or key.startswith("citation"):
        return ""
    # Unknown template: keep the longest positional argument, it is usually text.
    return max(positional, key=len) if positional else ""


TEMPLATE_INNER = re.compile(r"\{\{([^{}]*)\}\}", re.S)


def expand_templates(text: str) -> str:
    for _ in range(30):
        m = TEMPLATE_INNER.search(text)
        if not m:
            break
        body = m.group(1)
        parts = _split_template_args(body)
        rendered = _render_template(parts[0], parts[1:])
        text = text[:m.start()] + rendered + text[m.end():]
    return text


def strip_links(text: str) -> str:
    def repl_wiki(m: re.Match) -> str:
        inner = m.group(1)
        if "|" in inner:
            return inner.rsplit("|", 1)[1]
        return inner
    for _ in range(6):
        new = re.sub(r"\[\[([^\[\]]*)\]\]", repl_wiki, text)
        if new == text:
            break
        text = new
    # External links: [http://x label] -> label
    text = re.sub(r"\[(?:https?:|//)\S+\s+([^\]]*)\]", r"\1", text)
    text = re.sub(r"\[(?:https?:|//)\S+\]", "", text)
    return text


def clean_cell(raw: str, keep_bold: bool = False) -> str:
    """Strip wiki markup from a cell, optionally preserving ''' markers."""
    t = raw
    t = COMMENT.sub("", t)
    t = REF_SELF_CLOSING.sub("", t)
    t = REF_BLOCK.sub("", t)
    t = REF_SELF_CLOSING.sub("", t)
    t = expand_templates(t)
    t = strip_links(t)
    t = re.sub(r"<\s*br\s*/?\s*>", "; ", t, flags=re.I)
    t = re.sub(r"</?(?:small|sup|sub|span|div|p|b|i|u|li|ul|ol|nowiki)[^>]*>", "",
               t, flags=re.I)
    t = re.sub(r"<[^>]{1,80}>", "", t)
    t = html.unescape(t)
    if not keep_bold:
        t = t.replace("'''", "").replace("''", "")
    t = t.replace("\u200b", "")
    t = re.sub(r"^[\s*:;#]+", "", t)
    t = re.sub(r"[ \t]*\n[ \t]*", " ", t)
    t = re.sub(r"\s+", " ", t)
    t = re.sub(r"\s+([;,.])", r"\1", t)
    t = re.sub(r"^[\s;,.]+", "", t)
    return t.strip()


# --------------------------------------------------------------------------- #
# Table parsing
# --------------------------------------------------------------------------- #

ATTR_PREFIX = re.compile(
    r"^\s*((?:[A-Za-z-]+\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^|\s\"']+)\s*)+)\|(?!\|)")


class Cell:
    __slots__ = ("raw", "colspan", "is_header")

    def __init__(self, raw: str, colspan: int, is_header: bool) -> None:
        self.raw = raw
        self.colspan = colspan
        self.is_header = is_header


def _make_cell(body: str, is_header: bool) -> Cell:
    colspan = 1
    m = ATTR_PREFIX.match(body)
    if m:
        attrs = m.group(1)
        body = body[m.end():]
        cs = re.search(r"colspan\s*=\s*\"?'?(\d+)", attrs, re.I)
        if cs:
            colspan = max(1, int(cs.group(1)))
    return Cell(body, colspan, is_header)


def parse_tables(wikitext: str) -> list[tuple[str, list[list[Cell]]]]:
    """Return [(section title, rows-of-cells), ...] for every wikitable."""
    sections = re.split(r"\n==+\s*([^=\n]+?)\s*==+\s*\n", wikitext)
    out = []
    # sections[0] is the lead; then (title, body) pairs
    for i in range(1, len(sections) - 1, 2):
        title = sections[i].strip()
        body = sections[i + 1]
        for table in re.findall(r"^\{\|.*?^\|\}", body, re.S | re.M):
            rows = _parse_table_rows(table)
            if rows:
                out.append((title, rows))
    return out


def _parse_table_rows(table: str) -> list[list[Cell]]:
    rows: list[list[Cell]] = []
    current: list[Cell] | None = None
    cell_buf: list[str] | None = None
    is_header = False

    def flush_cell() -> None:
        nonlocal cell_buf
        if cell_buf is not None and current is not None:
            current.append(_make_cell("\n".join(cell_buf), is_header))
        cell_buf = None

    def flush_row() -> None:
        nonlocal current
        flush_cell()
        if current:
            rows.append(current)
        current = None

    for line in table.split("\n"):
        if line.startswith("{|"):
            continue
        if line.startswith("|}"):
            break
        if re.match(r"^\|-", line):
            flush_row()
            current = []
            continue
        if line.startswith("!"):
            flush_cell()
            if current is None:
                current = []
            is_header = True
            cell_buf = [line[1:]]
            continue
        if line.startswith("|"):
            flush_cell()
            if current is None:
                current = []
            is_header = False
            cell_buf = [line[1:]]
            continue
        if cell_buf is not None:
            cell_buf.append(line)
    flush_row()
    return rows


COLUMN_PATTERNS = (
    ("country", re.compile(r"^(country|state|territory|country/territory|"
                           r"country or territory|location|region)", re.I)),
    ("police", re.compile(r"police", re.I)),
    ("ambulance", re.compile(r"ambulance|medical|ems", re.I)),
    ("fire", re.compile(r"fire", re.I)),
    ("notes", re.compile(r"note|other|comment|remark|additional", re.I)),
)


def header_layout(rows: list[list[Cell]]) -> dict[str, int] | None:
    """Read the table's header row and map field name -> column index."""
    for row in rows:
        if not any(c.is_header for c in row):
            continue
        layout: dict[str, int] = {}
        pos = 0
        for cell in row:
            text = clean_cell(cell.raw)
            for field, pattern in COLUMN_PATTERNS:
                if field in layout:
                    continue
                if pattern.search(text):
                    layout[field] = pos
                    break
            pos += cell.colspan
        if "country" in layout:
            return layout
    return None


def row_grid(row: list[Cell]) -> dict[int, Cell]:
    grid: dict[int, Cell] = {}
    pos = 0
    for cell in row:
        for k in range(cell.colspan):
            grid[pos + k] = cell
        pos += cell.colspan
    return grid


# --------------------------------------------------------------------------- #
# Number extraction
# --------------------------------------------------------------------------- #

NUM_TOKEN = re.compile(r"(?<![0-9])[*#+]?[0-9](?:[0-9 .\u2013\u2014-]*[0-9])?(?![0-9])")
BOLD = re.compile(r"'''(.+?)'''", re.S)


def normalise_number(token: str) -> str | None:
    num = re.sub(r"[^0-9*#+]", "", token)
    if NUMBER_RE.match(num):
        return num
    return None


def numbers_in(text: str) -> list[str]:
    # Parentheses are decoration around dialable digits, e.g. "(+690) 2116" and
    # "(0)21 555" - drop them so the number stays in one piece.
    text = text.replace("(", " ").replace(")", " ") \
        if re.search(r"\(\s*[+0-9]", text) else text
    found: list[str] = []
    for m in NUM_TOKEN.finditer(text):
        num = normalise_number(m.group(0))
        if num and num not in found:
            found.append(num)
    return found


def cell_numbers(raw: str) -> list[str]:
    """Numbers in a service cell, primary first.

    Bold text carries the dialable numbers on this page, so prefer it and only
    fall back to the whole cell when nothing is bold.
    """
    text = clean_cell(raw, keep_bold=True)
    bolds = BOLD.findall(text)
    if bolds:
        nums: list[str] = []
        for b in bolds:
            for n in numbers_in(b.replace("'''", "")):
                if n not in nums:
                    nums.append(n)
        if nums:
            return nums
    return numbers_in(text.replace("'''", ""))


MOBILE_GENERAL = re.compile(
    r"mobile (?:phones?|networks?|telephones?)[^.;:]{0,30}?[-\u2013\u2014:]\s*"
    r"([0-9]{3,4})", re.I)
# "General emergencies – 112", "Emergency call – 112", "General emergencies is
# also 110": the source naming a number that reaches every service.
GENERAL_PHRASE = re.compile(
    r"(?:general emergenc(?:y|ies)|emergency calls?|all emergenc(?:y|ies)|"
    r"single emergency number|universal emergency number)"
    r"[^.;]{0,15}?[-\u2013\u2014:]?\s*(?:is\s+also\s+|is\s+|are\s+)?"
    r"[*#]?([0-9]{3,4})\b", re.I)
YEAR = re.compile(r"^(?:19|20)\d\d$")


def derive_general(values: dict[str, str | None], notes: str) -> str | None:
    police, amb, fire = values["police"], values["ambulance"], values["fire"]
    if police and police == amb == fire:
        return police
    # A single number shared by the medical and fire services and known to be a
    # universal emergency number reaches every service in practice.
    if amb and amb == fire and amb in UNIVERSAL_NUMBERS:
        return amb
    if police and police == amb and police in UNIVERSAL_NUMBERS:
        return police
    if police and police == fire and police in UNIVERSAL_NUMBERS:
        return police
    m = GENERAL_PHRASE.search(notes)
    if m and not YEAR.match(m.group(1)):
        return m.group(1)
    m = MOBILE_GENERAL.search(notes)
    if m and m.group(1) in UNIVERSAL_NUMBERS:
        return m.group(1)
    return None


def trim_notes(text: str) -> str:
    text = re.sub(r"\s+", " ", text).strip()
    text = re.sub(r"^[;,.\s]+", "", text)
    if len(text) <= NOTES_MAX:
        return text.strip()
    cut = text[:NOTES_MAX]
    for sep in (". ", "; ", ", ", " "):
        idx = cut.rfind(sep)
        if idx >= NOTES_MAX * 0.6:
            cut = cut[:idx + (1 if sep.startswith(".") else 0)]
            break
    return cut.strip().rstrip(",;") + "..."


# --------------------------------------------------------------------------- #
# Row -> record
# --------------------------------------------------------------------------- #

FIELD_LABEL = {"police": "Police", "ambulance": "Ambulance", "fire": "Fire"}


def build_records(wikitext: str) -> tuple[dict[str, dict], list[tuple[str, str]]]:
    records: dict[str, dict] = {}
    unmapped: list[tuple[str, str]] = []

    for section, rows in parse_tables(wikitext):
        layout = header_layout(rows)
        if not layout:
            print(f"skipping table in section {section!r}: no header row",
                  file=sys.stderr)
            continue
        for row in rows:
            if any(c.is_header for c in row):
                continue
            grid = row_grid(row)
            country_cell = grid.get(layout["country"])
            if country_cell is None:
                continue
            name_raw = clean_cell(country_cell.raw)
            name = clean_name(name_raw)
            if not name:
                continue
            code = NAME_TO_ISO.get(_norm_name(name))
            if not code:
                unmapped.append((section, name))
                continue

            values: dict[str, str | None] = {"police": None, "ambulance": None,
                                             "fire": None}
            # Group the service columns by the physical cell backing them so a
            # colspan cell is only reported once.
            cells_by_id: dict[int, tuple[Cell, list[str]]] = {}
            for field in ("police", "ambulance", "fire"):
                col = layout.get(field)
                if col is None:
                    continue
                cell = grid.get(col)
                if cell is None or cell is grid.get(layout["country"]):
                    continue
                cells_by_id.setdefault(id(cell), (cell, []))[1].append(field)

            extra_bits: list[str] = []
            for cell, fields_for_cell in cells_by_id.values():
                nums = cell_numbers(cell.raw)
                for field in fields_for_cell:
                    values[field] = nums[0] if nums else None
                if set(fields_for_cell) == {"police", "ambulance", "fire"}:
                    label = "All services"
                else:
                    label = "/".join(FIELD_LABEL[f] for f in fields_for_cell)
                if len(nums) > 1:
                    extra_bits.append(f"{label} alternate: {', '.join(nums[1:])}.")
                elif not nums:
                    text = clean_cell(cell.raw)
                    if re.search(r"[A-Za-z]", text):
                        extra_bits.append(f"{label}: {text.rstrip('.')}.")

            notes_col = layout.get("notes")
            notes_raw = ""
            if notes_col is not None:
                cell = grid.get(notes_col)
                if cell is not None and cell is not grid.get(layout["country"]):
                    notes_raw = clean_cell(cell.raw)

            extra_bits = [b for b in extra_bits if b]
            notes = " ".join([*extra_bits, notes_raw]).strip()

            values["general"] = derive_general(values, notes)
            record = {
                "iso": code,
                "name": ISO_ENTRIES[code][0],
                "general": values["general"],
                "police": values["police"],
                "ambulance": values["ambulance"],
                "fire": values["fire"],
                "notes": notes,
                "_source_names": [name],
            }
            if code in records:
                merge_record(records[code], record, name)
            else:
                records[code] = record
    return records, unmapped


def clean_name(text: str) -> str:
    """Reduce a country cell to a plain name."""
    t = text.strip()
    t = re.sub(r"\s*\([^)]*\)\s*$", "", t)        # trailing parenthetical
    t = re.sub(r"\[[a-z0-9]\]", "", t, flags=re.I)  # footnote markers
    t = re.sub(r"\s+", " ", t)
    return t.strip(" ,;–-")


def merge_record(dst: dict, src: dict, src_name: str) -> None:
    """Fold a second source row for the same ISO code into the first."""
    differing = []
    for field in FIELDS:
        if dst.get(field) is None and src.get(field) is not None:
            dst[field] = src[field]
        elif src.get(field) is not None and dst.get(field) != src.get(field):
            differing.append(f"{field} {src[field]}")
    dst["_source_names"].append(src_name)
    bits = []
    if differing:
        bits.append(f"{src_name}: {', '.join(differing)}.")
    if src["notes"] and src["notes"] not in dst["notes"]:
        bits.append(src["notes"])
    if bits:
        dst["notes"] = " ".join([dst["notes"], *bits]).strip()


# --------------------------------------------------------------------------- #
# Overrides / assembly / validation
# --------------------------------------------------------------------------- #


def apply_overrides(records: dict[str, dict]) -> list[str]:
    changed: list[str] = []
    for code, fields in OVERRIDES.items():
        rec = records.get(code)
        if rec is None:
            print(f"override for {code} has no parsed row; creating entry",
                  file=sys.stderr)
            rec = records[code] = {
                "iso": code,
                "name": ISO_ENTRIES[code][0],
                "general": None, "police": None, "ambulance": None,
                "fire": None, "notes": "", "_source_names": ["(override only)"],
            }
        for field, value in fields.items():
            if rec.get(field) != value:
                changed.append(f"{code}.{field}: {rec.get(field)!r} -> {value!r}")
                rec[field] = value
    for code, addendum in NOTE_ADDENDA.items():
        rec = records.get(code)
        if rec is None:
            continue
        digits = re.sub(r"\D", "", addendum)
        if digits and digits not in rec["notes"]:
            rec["notes"] = (addendum + " " + rec["notes"]).strip()
    return changed


def finalise(records: dict[str, dict]) -> tuple[dict[str, dict], list[str]]:
    out: dict[str, dict] = {}
    dropped: list[str] = []
    for code, rec in records.items():
        if all(rec[f] is None for f in FIELDS):
            dropped.append(code)
            continue
        out[code] = {
            "iso": code,
            "name": rec["name"],
            "general": rec["general"],
            "police": rec["police"],
            "ambulance": rec["ambulance"],
            "fire": rec["fire"],
            "notes": trim_notes(rec["notes"]),
        }
    return out, dropped


REQUIRED_KEYS = ("iso", "name", "general", "police", "ambulance", "fire", "notes")


def validate(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    assert data["schema"] == SCHEMA, "bad schema"
    assert data["source"] == SOURCE_URL, "bad source"
    assert re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$",
                    data["generated_utc"]), "bad timestamp"
    countries = data["countries"]
    assert countries, "no countries"
    for code, rec in countries.items():
        assert re.match(r"^[A-Z]{2}$", code), f"bad key {code!r}"
        for key in REQUIRED_KEYS:
            assert key in rec, f"{code} missing {key}"
        assert set(rec) == set(REQUIRED_KEYS), f"{code} has extra keys"
        assert rec["iso"] == code, f"{code} iso mismatch"
        assert isinstance(rec["name"], str) and rec["name"], f"{code} bad name"
        assert isinstance(rec["notes"], str), f"{code} notes not a string"
        assert len(rec["notes"]) <= NOTES_MAX + 3, f"{code} notes too long"
        assert any(rec[f] for f in FIELDS), f"{code} has no numbers"
        for field in FIELDS:
            val = rec[field]
            assert val is None or (
                isinstance(val, str) and NUMBER_RE.match(val)
            ), f"{code}.{field} invalid: {val!r}"
    return data


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--refresh", action="store_true",
                    help="refetch the wikitext even if the cache exists")
    args = ap.parse_args()

    wikitext = fetch_wikitext(refresh=args.refresh)
    records, unmapped = build_records(wikitext)
    parsed_count = len(records)
    changed = apply_overrides(records)
    countries, dropped = finalise(records)

    payload = {
        "schema": SCHEMA,
        "generated_utc": _dt.datetime.now(_dt.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"),
        "source": SOURCE_URL,
        "countries": countries,
    }
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=1, sort_keys=True, ensure_ascii=False)
        fh.write("\n")

    data = validate(OUT_PATH)
    final = data["countries"]

    with_general = sum(1 for r in final.values() if r["general"])
    missing = {f: sum(1 for r in final.values() if not r[f])
               for f in ("police", "ambulance", "fire")}
    official_iso = sum(1 for c in final if c != "XK")

    print("--- emergency numbers dataset ---")
    print(f"output:                {OUT_PATH}")
    print(f"size:                  {os.path.getsize(OUT_PATH)} bytes")
    print(f"parsed source rows:    {parsed_count} mapped to ISO codes")
    print(f"total countries:       {len(final)} "
          f"({official_iso} officially assigned ISO 3166-1 codes + XK Kosovo)")
    print(f"with general number:   {with_general}")
    print(f"missing police:        {missing['police']}")
    print(f"missing ambulance:     {missing['ambulance']}")
    print(f"missing fire:          {missing['fire']}")
    print(f"dropped (all null):    {len(dropped)} {sorted(dropped)}")
    absent = sorted(c for c in ISO_ENTRIES if c != "XK" and c not in final)
    print(f"ISO codes not on page: {len(absent)} {absent}")
    print(f"override changes:      {len(changed)}")
    for line in changed:
        print(f"  {line}")
    print(f"unmapped source rows:  {len(unmapped)}")
    for section, name in unmapped:
        flag = "expected, no ISO 3166-1 code" if _norm_name(name) in KNOWN_NON_ISO \
            else "UNEXPECTED"
        print(f"  [{section}] {name} ({flag})", file=sys.stderr)
        print(f"  [{section}] {name} ({flag})")
    if len(final) < 190:
        print(f"ERROR: coverage {len(final)} < 190", file=sys.stderr)
        return 1
    print("validation: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
