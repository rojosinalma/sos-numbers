# Emergency Numbers

Android app that shows the emergency phone numbers for the country you are standing in.
Works fully offline. No internet permission, no third-party plugins, no accounts.

## How it decides where you are

In order of trust, first one that resolves wins:

1. A country you picked manually
2. GPS, matched against border data bundled in the app
3. The country of the mobile network your phone is registered to (correct while roaming)
4. The country that issued your SIM (weak: where you are *from*, not where you *are*)
5. Your phone's language setting (weakest)

The screen always says which signal was used, and warns when it is a weak one.

## Numbers

243 countries and territories, from Wikipedia's
[List of emergency telephone numbers](https://en.wikipedia.org/wiki/List_of_emergency_telephone_numbers),
with a curated override table for commonly travelled countries. Tapping a number opens your
dialer with it pre-filled; the app never places a call itself.

If a number does not connect, try **112** or **911**. Most networks route both to local services.

## Build

Requires Flutter stable and an Android SDK. See `AGENTS.md` for the toolchain used here.

```
flutter test
flutter build apk --release --split-per-abi
```

Data assets are generated, not hand-edited: `tools/gen_emergency_numbers.py`,
`tools/gen_country_borders.py`, `tools/gen_icons.py` (python3, stdlib only).
