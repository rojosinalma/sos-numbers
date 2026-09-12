# Task spec: add overseas-territory geometry to the borders asset

Project: /home/rojo/dev/sos-numbers. python3 stdlib only, no pip, no Ruby.
Touch ONLY `tools/gen_country_borders.py`, `tools/SPEC_borders.md` and
`assets/geo/country_borders.json`. Another agent is editing `lib/` and `android/`
concurrently — do not touch those, and do not run flutter/gradle.

## The bug being fixed

Natural Earth admin-0 folds several inhabited overseas territories into their parent country,
so the offline GPS lookup returns the parent's emergency numbers. Confirmed wrong answer:
a phone in Kralendijk, Bonaire resolves to `NL` and is shown **112**, but `BQ`'s real
emergency number is **911**. Mayotte, Cocos and Tokelau resolve to nothing at all.

Nine ISO codes are in `assets/data/emergency_numbers.json` but have no geometry:
`BQ CC CX GF GP MQ RE TK YT`.

## The data that fixes it

`ne_10m_admin_0_map_units` has real geometry for all nine (already downloaded and cached at
`tools/mapunits.cache.geojson`, 13.5 MB, 298 features; re-download from
`https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_admin_0_map_units.geojson`
if the cache is missing). Verified present: `BQ` Caribbean Netherlands, `CC` Cocos Is.,
`CX` Christmas I., `GF` French Guiana, `GP` Guadeloupe, `MQ` Martinique, `RE` Réunion,
`TK` Tokelau, `YT` Mayotte. Do not fabricate geometry from bounding boxes — use these features.

## What to build

1. Compute the overlay set **dynamically**: every ISO code that map-units provides but the
   admin-0 pass did not emit. Report the full list. If it comes out larger than ~30 codes,
   include them all anyway as long as each one is a real ISO 3166-1 alpha-2 code with geometry;
   more specific territories strictly improve the lookup. Log anything you exclude and why.
2. Run those features through the exact same pipeline as the existing countries (Douglas-Peucker
   eps 0.002 with the small-ring exemptions, quantise by scale 1000, delta encode, bbox).
3. Emit them under a NEW top-level key `subunits`, an array with the same country-object shape
   (`c`, `n`, `b`, `r`) as `countries`. Do NOT merge them into `countries`.
   Bump `schema` from 1 to 2. Keep `countries` exactly as it is today, including its ordering.
   The Dart side will test `subunits` first and fall back to `countries`, so precedence is
   explicit rather than depending on array order.
4. Keep the generator idempotent and re-runnable, with the map-units download cached like the
   others (`tools/*.cache.*` is git-ignored).
5. Update the format section of `tools/SPEC_borders.md`: document `subunits`, the schema bump,
   the lookup order the Dart side must use, and why the overlay exists.

## Verification (must pass before reporting success)

Extend the generator's `--verify` to test `subunits` first, then `countries`, and confirm:

    Kralendijk, Bonaire      12.151, -68.277 -> BQ   (was NL: the actual bug)
    Oranjestad, Sint Eust.   17.485, -62.976 -> BQ
    Mamoudzou, Mayotte      -12.780,  45.228 -> YT   (was null)
    Nukunonu, Tokelau        -9.169, -171.819 -> TK  (was null)
    West Island, Cocos      -12.157,  96.826 -> CC   (was null)
    Flying Fish Cove, CX    -10.422, 105.679 -> CX   (was AU)
    Cayenne, French Guiana    4.922, -52.313 -> GF   (was FR)
    Fort-de-France, MQ       14.616, -61.058 -> MQ   (was null)
    Pointe-à-Pitre, GP       16.241, -61.533 -> GP   (was FR)
    Saint-Denis, Réunion    -20.882,  55.450 -> RE   (was FR)

And confirm the overlay did NOT break the parents — every one of these must be unchanged:

    Amsterdam    52.374,   4.890 -> NL
    Paris        48.857,   2.352 -> FR
    Sydney      -33.869, 151.209 -> AU
    Wellington  -41.289, 174.777 -> NZ
    Willemstad   12.117, -68.933 -> CW
    Oranjestad   12.524, -70.027 -> AW

Then re-run the FULL 32-case verification table already in the spec — all must still pass.

Also assert programmatically that every `subunits` entry's `b` exactly equals the min/max of its
own delta-decoded points, that every ring length is even and >= 6, and that all values are ints.

## Size budget

The asset is currently 2.56 MB and must stay under 3.5 MB. Report the new size.

## Report back

New file size, the dynamically computed overlay list, the two verification tables (territories and
unbroken parents), confirmation the original 32 cases still pass, and the exact text you added to
SPEC_borders.md.
