# Task spec: emergency numbers dataset

Work ONLY inside /home/rojo/dev/sos-numbers. Ruby is NOT installed. Use python3, stdlib only,
no pip installs. Do not create files other than the two deliverables plus a cache file.

## Deliverables

1. `tools/gen_emergency_numbers.py` - reproducible generator
2. `assets/data/emergency_numbers.json` - its output

## Source

English Wikipedia, "List of emergency telephone numbers". Fetch raw wikitext:

    curl -sL 'https://en.wikipedia.org/w/api.php?action=parse&page=List_of_emergency_telephone_numbers&prop=wikitext&format=json&formatversion=2' -o tools/wikitext.cache.json

Cache it so reruns don't refetch. The page has per-continent tables; column order and count
VARY per table, so read each table's header row. Cells contain wiki markup, templates like
{{nowrap|112}}, <ref>...</ref> tags, footnote markers, rowspan/colspan. Handle all of it.

## Output schema (exactly this shape)

    {
      "schema": 1,
      "generated_utc": "2026-09-11T00:00:00Z",
      "source": "https://en.wikipedia.org/wiki/List_of_emergency_telephone_numbers",
      "countries": {
        "DE": {
          "iso": "DE",
          "name": "Germany",
          "general": "112",
          "police": "110",
          "ambulance": "112",
          "fire": "112",
          "notes": "112 works across the EU."
        }
      }
    }

Field rules:

- `countries` keys are UPPERCASE ISO 3166-1 alpha-2 codes.
- `name`: common English name, wiki markup / footnotes / parentheticals stripped.
- `general`, `police`, `ambulance`, `fire`: a single dialable string, or null when the source
  has no number. Strip whitespace, dots, dashes, parentheses ("1-1-2" becomes "112"). If a cell
  lists several numbers, put the primary one in the field and mention the rest in `notes`.
- `general`: the number reaching all services. If police == ambulance == fire, use it.
  Else if source text explicitly names a universal number (usually 112 or 911), use that.
  Else null.
- `notes`: plain text, max ~240 chars, markup stripped. May be "" but never null.
- Drop entries where every number is null.

## ISO mapping

Wikipedia gives names, not codes. Hardcode a comprehensive name -> alpha-2 dict in the script:
all 249 ISO 3166-1 entries plus Wikipedia aliases. Examples of aliases to cover:
United States of America -> US, South Korea / Republic of Korea / Korea, South -> KR,
Czechia / Czech Republic -> CZ, Ivory Coast / Cote d'Ivoire -> CI,
DR Congo / Democratic Republic of the Congo -> CD, Republic of the Congo -> CG,
Eswatini / Swaziland -> SZ, Myanmar / Burma -> MM, East Timor / Timor-Leste -> TL,
Vatican City / Holy See -> VA, Macau / Macao -> MO, Hong Kong -> HK, Palestine -> PS,
Turkey / Turkiye -> TR, the Netherlands -> NL, plus UK crown dependencies and overseas
territories. Log every unmatched source row to stderr.

## Quality bar

This is emergency data. Accuracy matters more than elegance.

- Script prints a summary: total countries, count with a general number, counts missing
  police/ambulance/fire, and all unmapped source rows.
- Coverage target: at least 190 ISO countries in the output. If the parse yields fewer, fix
  the parser rather than lowering the bar.
- Add a curated override dict applied AFTER parsing, and confirm these end up correct.
  Only override when the parsed value is missing or contradicts this list:

      US 911 all | CA 911 all | MX 911 all
      GB police 999, general 999 (note 112 also works) | IE 112 all
      DE police 110, fire 112, ambulance 112, general 112
      FR police 17, fire 18, ambulance 15, general 112
      ES/IT/NL/BE/PT/AT/PL/SE/NO/DK/FI/GR/TR/UA 112 general
      CH general 112, police 117, fire 118, ambulance 144
      RU general 112, police 102, ambulance 103, fire 101
      JP police 110, fire 119, ambulance 119
      KR police 112, fire 119, ambulance 119
      CN police 110, fire 119, ambulance 120
      IN 112 | ID 112 | PH 911 | MY 999 | AU 000 | NZ 111
      SG police 999, fire 995, ambulance 995
      TH police 191, ambulance 1669, fire 199
      VN police 113, fire 114, ambulance 115
      ZA police 10111, ambulance 10177, general 112
      EG police 122, ambulance 123, fire 180 | MA police 19, ambulance 15
      BR police 190, ambulance 192, fire 193
      AR general 911, police 101, fire 100, ambulance 107
      CL police 133, fire 132, ambulance 131
      CO 123 | PE 105 | UY 911
      IL police 100, fire 102, ambulance 101
      AE general 999, ambulance 998, fire 997
      SA police 999, ambulance 997, fire 998 | QA 999
      KE 999 | NG 112 | GH 112 | TZ 112 | ET 991
      PK 15 | BD 999 | LK 119 | NP 100 | KZ 112 | GE 112 | AM 112 | AZ 112

- Validate the final file: `json.load` it, assert every entry has all required keys, and assert
  every non-null number matches `^[0-9*#+]{2,12}$`.
- Write with `json.dump(..., indent=1, sort_keys=True, ensure_ascii=False)`.

## Report back

Absolute paths, JSON file size, the coverage summary numbers, the unmapped-row list, and
confirmation that the spot-check values above are correct in the output.
