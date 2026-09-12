import 'numbers_repository.dart';
import 'borders.dart';
import 'native.dart';

/// Where the displayed country came from, most trusted first.
enum CountrySource { manual, gps, network, sim, locale, none }

extension CountrySourceLabel on CountrySource {
  String get label => switch (this) {
        CountrySource.manual => 'Chosen by you',
        CountrySource.gps => 'From your location',
        CountrySource.network => 'From your mobile network',
        CountrySource.sim => 'From your SIM card',
        CountrySource.locale => 'From your phone language',
        CountrySource.none => 'Not determined',
      };

  /// How much this signal actually says about where the phone physically is.
  String get caveat => switch (this) {
        CountrySource.manual => 'You picked this country manually.',
        CountrySource.gps =>
          'Matched against offline border data. No internet used.',
        CountrySource.network =>
          'The country of the mobile network you are connected to. Reliable, '
              'including while roaming.',
        CountrySource.sim =>
          'The country that issued your SIM, which may not be where you are. '
              'Check this is right.',
        CountrySource.locale =>
          'Only a guess from your phone language. Very likely wrong if you are '
              'travelling. Check this is right.',
        CountrySource.none => 'Pick your country manually.',
      };

  bool get isTrustworthy =>
      this == CountrySource.manual ||
      this == CountrySource.gps ||
      this == CountrySource.network;
}

/// Immutable snapshot of every signal plus the choice made from them.
///
/// Deliberately has no `copyWith`: a `??`-merging copyWith cannot clear a field
/// back to null, which is exactly what a later location fix at sea needs to do
/// to `gpsIso`. Callers build a fresh Detection and run it through
/// [CountryDetector._pick].
class Detection {
  const Detection({
    required this.iso,
    required this.source,
    this.manualIso,
    this.gpsIso,
    this.gpsUnsupportedIso,
    this.networkIso,
    this.simIso,
    this.localeIso,
    this.fix,
    this.locationPermitted = false,
    this.locationPermanentlyDenied = false,
    this.locationTried = false,
    this.locationError,
  });

  final String? iso;
  final CountrySource source;

  final String? manualIso;

  /// GPS country, only when we have numbers for it.
  final String? gpsIso;

  /// GPS resolved to a real country that the numbers dataset does not cover.
  /// Shown in the details card so a successful fix is never reported as "no fix".
  final String? gpsUnsupportedIso;

  final String? networkIso;
  final String? simIso;
  final String? localeIso;

  final GeoFix? fix;
  final bool locationPermitted;
  final bool locationPermanentlyDenied;
  final bool locationTried;
  final String? locationError;

  bool get isManual => source == CountrySource.manual;

  /// True when GPS and the mobile network point at different countries, which
  /// happens legitimately near borders and is worth surfacing rather than hiding.
  bool get signalsDisagree =>
      gpsIso != null && networkIso != null && gpsIso != networkIso;
}

/// Resolves the current country from offline signals only.
///
/// Priority: a manual choice always wins, then GPS matched against bundled
/// borders, then the registered mobile network, then the SIM, then the locale.
class CountryDetector {
  CountryDetector(this._repo);

  static const String _manualPrefKey = 'manual_iso';

  final NumbersRepository _repo;

  /// Instant, permissionless pass. Good enough to show numbers immediately.
  /// Never throws: every native call degrades to null on failure.
  Future<Detection> detectQuick() async {
    final String? manual = _valid(await Native.prefGet(_manualPrefKey));
    final TelephonyHints hints = await Native.telephonyHints();
    final bool permitted = await Native.hasLocationPermission();
    final bool permanentlyDenied =
        !permitted && await Native.isLocationPermanentlyDenied();

    return _pick(Detection(
      iso: null,
      source: CountrySource.none,
      manualIso: manual,
      networkIso: _valid(hints.networkIso),
      simIso: _valid(hints.simIso),
      localeIso: _valid(hints.localeIso),
      locationPermitted: permitted,
      locationPermanentlyDenied: permanentlyDenied,
    ));
  }

  /// Adds a location fix to an existing detection. Safe to call after
  /// [detectQuick] has already put something on screen: it never throws and
  /// always returns a usable Detection, at worst [current] with an error note.
  Future<Detection> refineWithLocation(
    Detection current, {
    bool requestPermission = false,
  }) async {
    // Never trust the snapshot: the user may have granted or revoked location
    // in Settings since it was taken. Ask the OS every time.
    bool permitted = await Native.hasLocationPermission();
    if (!permitted && requestPermission) {
      permitted = await Native.requestLocationPermission();
    }
    if (!permitted) {
      final bool permanentlyDenied = await Native.isLocationPermanentlyDenied();
      return _withLocation(
        current,
        gpsIso: null,
        gpsUnsupportedIso: null,
        fix: null,
        permitted: false,
        permanentlyDenied: permanentlyDenied,
        error: permanentlyDenied
            ? 'Location permission denied. Enable it in app settings.'
            : 'Location permission not granted',
      );
    }

    final GeoFix? fix = await Native.location();
    if (fix == null) {
      return _withLocation(
        current,
        gpsIso: null,
        gpsUnsupportedIso: null,
        fix: null,
        permitted: true,
        permanentlyDenied: false,
        error: 'No recent location fix available',
      );
    }

    String? raw;
    try {
      raw = await Borders.countryAt(fix.latitude, fix.longitude);
    } catch (_) {
      // Isolate failure, OOM, corrupt asset: the numbers on screen stay put.
      return _withLocation(
        current,
        gpsIso: null,
        gpsUnsupportedIso: null,
        fix: fix,
        permitted: true,
        permanentlyDenied: false,
        error: 'Could not match location to a country',
      );
    }

    final String? iso = _valid(raw);
    return _withLocation(
      current,
      gpsIso: iso,
      gpsUnsupportedIso: (raw != null && iso == null) ? raw.toUpperCase() : null,
      fix: fix,
      permitted: true,
      permanentlyDenied: false,
      error: raw == null
          ? 'Location is not inside any country'
          : iso == null
              ? 'No emergency numbers on file for $raw'
              : null,
    );
  }

  /// Returns true when the choice was persisted. A failed write is reported so
  /// the UI can warn instead of silently reverting on the next detection.
  Future<bool> setManual(String? iso) =>
      Native.prefSet(_manualPrefKey, iso?.toUpperCase());

  Detection _withLocation(
    Detection d, {
    required String? gpsIso,
    required String? gpsUnsupportedIso,
    required GeoFix? fix,
    required bool permitted,
    required bool permanentlyDenied,
    required String? error,
  }) =>
      _pick(Detection(
        iso: null,
        source: CountrySource.none,
        manualIso: d.manualIso,
        gpsIso: gpsIso,
        gpsUnsupportedIso: gpsUnsupportedIso,
        networkIso: d.networkIso,
        simIso: d.simIso,
        localeIso: d.localeIso,
        fix: fix,
        locationPermitted: permitted,
        locationPermanentlyDenied: permanentlyDenied,
        locationTried: true,
        locationError: error,
      ));

  Detection _pick(Detection d) {
    final List<(String?, CountrySource)> ordered = <(String?, CountrySource)>[
      (d.manualIso, CountrySource.manual),
      (d.gpsIso, CountrySource.gps),
      (d.networkIso, CountrySource.network),
      (d.simIso, CountrySource.sim),
      (d.localeIso, CountrySource.locale),
    ];
    String? iso;
    CountrySource source = CountrySource.none;
    for (final (String? candidate, CountrySource s) in ordered) {
      if (candidate != null && _repo.has(candidate)) {
        iso = candidate;
        source = s;
        break;
      }
    }
    return Detection(
      iso: iso,
      source: source,
      manualIso: d.manualIso,
      gpsIso: d.gpsIso,
      gpsUnsupportedIso: d.gpsUnsupportedIso,
      networkIso: d.networkIso,
      simIso: d.simIso,
      localeIso: d.localeIso,
      fix: d.fix,
      locationPermitted: d.locationPermitted,
      locationPermanentlyDenied: d.locationPermanentlyDenied,
      locationTried: d.locationTried,
      locationError: d.locationError,
    );
  }

  String? _valid(String? iso) {
    if (iso == null) return null;
    final String s = iso.trim().toUpperCase();
    return _repo.has(s) ? s : null;
  }
}
