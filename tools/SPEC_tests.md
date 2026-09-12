# Task spec: expand the Dart test suite

Project: /home/rojo/dev/sos-numbers (Flutter, Android-only).

Toolchain is NOT on PATH by default. Every command must start with:

    source ~/toolchains/env.sh

Then `flutter test` and `flutter analyze` work. Gradle/APK builds are NOT your concern.

## Constraints

- Touch ONLY `test/` files. Do not modify `lib/`, `android/`, `pubspec.yaml`, `assets/` or `tools/`.
- If you find a genuine bug in `lib/`, do NOT fix it. Write the test that exposes it, mark it
  `skip: 'BUG: <description>'` so the suite stays green, and report it prominently.
- No new dependencies. `flutter_test` only.
- Tests must use the REAL bundled assets, never mocked datasets. The point is to verify the
  shipped data and the real decoders.
- Both `flutter analyze` (zero issues) and `flutter test` (all green) must pass when you finish.

## Context

`test/widget_test.dart` already covers: dataset coverage/dialability/search, offline border lookup
for eight cities and open ocean, and one widget test asserting the mobile-network country wins.
Read it first, then extend. Split into multiple files under `test/` if that reads better.

The only platform dependency is one MethodChannel, `dev.rojo.sos_numbers/native`, mocked via
`TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler`.
Its methods and return shapes (see `lib/src/native.dart`):

| Method | Args | Returns |
|---|---|---|
| `telephonyHints` | - | `{networkIso, simIso, localeIso, hasSim}` |
| `hasLocationPermission` | - | bool |
| `requestLocationPermission` | - | bool |
| `location` | `timeoutMs`, `maxAgeMs` | `{lat, lon, accuracy, provider, ageMs}` or null |
| `openDialer` | `number` | bool |
| `prefGet` | `key` | String? |
| `prefSet` | `key`, `value` | null |

Detection priority is manual > gps > network > sim > locale, implemented in
`lib/src/detection.dart`. Preferences are faked by having your mock handler back `prefGet`/`prefSet`
with an in-memory map, so the manual-selection path is testable.

## Cases to cover

Detection logic (`CountryDetector`, unit level where possible):

1. Manual choice beats every other signal, and beats a GPS fix that says otherwise.
2. GPS beats the mobile network when they disagree, and `signalsDisagree` is true.
3. Network beats SIM; SIM beats locale.
4. An unknown/garbage ISO from any signal is ignored, falling through to the next one
   (e.g. `networkIso: 'ZZ'`, `''`, `'usa'`, lowercase `'de'` which must still work).
5. All signals null/absent gives `CountrySource.none` and a null ISO.
6. Location refine when permission is denied: source stays put, `locationError` is set,
   nothing crashes.
7. Location refine when the fix lands in the ocean: `gpsIso` stays null, error message set,
   previous source still used.

Widget behaviour (`SosNumbersApp` / `HomePage`):

8. Weak signal (SIM or locale only) renders the "Verify this country" warning banner; a network
   or GPS result does not.
9. The disagreement banner appears when GPS and network differ and names both codes.
10. Tapping the big emergency button invokes `openDialer` with the right number; assert on the
    actual captured `MethodCall` arguments.
11. Long-pressing a service tile copies to the clipboard (mock the `flutter/platform` channel's
    `Clipboard.setData` or assert via `Clipboard.getData`) and shows a snackbar.
12. No country detected at all renders the "Country not determined" state with a
    "Choose country" button.
13. The country picker opens, searching narrows the list, tapping a country persists it via
    `prefSet` and the header then shows "Chosen by you".
14. A country with no universal number (e.g. `JP`) shows "MAIN EMERGENCY NUMBER" rather than
    "ALL EMERGENCY SERVICES", and still lists police/ambulance/fire tiles.

Data integrity (against the real asset):

15. Every ISO code in the borders asset that appears in the numbers dataset round-trips, and
    report (do not fail on) any border code with no numbers entry, or vice versa.
16. Notes are never null, names are never empty, and no number contains whitespace.

## Report back

Files written, total test count, pass/fail, `flutter analyze` result, any bug you exposed with a
`skip` marker (quote the test name and what is wrong), and the list from case 15.
