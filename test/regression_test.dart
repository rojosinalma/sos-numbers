import 'package:flutter_test/flutter_test.dart';
import 'package:sos_numbers/src/borders.dart';
import 'package:sos_numbers/src/detection.dart';
import 'package:sos_numbers/src/native.dart';
import 'package:sos_numbers/src/numbers_repository.dart';

import 'support/fake_native.dart';

/// Regression tests for the bugs found in the first adversarial review.
/// Each test names the failure it guards against; if one goes red, read the
/// name before touching the assertion.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NumbersRepository repo;
  setUpAll(() async => repo = await NumbersRepository.load());

  group('F2: stale location fixes are never trusted', () {
    test('a fix older than maxAge is rejected on the Dart side too', () async {
      FakeNative(
        locationPermitted: true,
        fix: FakeNative.geoFix(52.52, 13.405, ageMs: 3 * 24 * 3600 * 1000),
      ).install();

      final GeoFix? fix =
          await Native.location(maxAge: const Duration(minutes: 30));
      expect(fix, isNull,
          reason: 'a three-day-old Berlin fix must not outrank the network');
    });

    test('a fresh fix passes', () async {
      FakeNative(
        locationPermitted: true,
        fix: FakeNative.geoFix(52.52, 13.405, ageMs: 5000),
      ).install();

      final GeoFix? fix = await Native.location();
      expect(fix, isNotNull);
      expect(fix!.ageMs, 5000);
    });

    test('stale fix leaves the network country in charge', () async {
      FakeNative(
        networkIso: 'JP',
        locationPermitted: true,
        fix: FakeNative.geoFix(52.52, 13.405, ageMs: 3 * 24 * 3600 * 1000),
      ).install();
      final CountryDetector detector = CountryDetector(repo);

      final Detection d =
          await detector.refineWithLocation(await detector.detectQuick());
      expect(d.iso, 'JP');
      expect(d.source, CountrySource.network);
      expect(d.gpsIso, isNull);
      expect(d.locationError, 'No recent location fix available');
    });
  });

  group('F4: overseas territories resolve to their own numbers', () {
    test('Bonaire is BQ (911), not the Netherlands (112)', () async {
      final String? iso = await Borders.countryAt(12.151, -68.277);
      expect(iso, 'BQ');
      expect(repo.forIso('BQ')!.primary, '911');
      expect(repo.forIso('NL')!.primary, '112',
          reason: 'sanity: the two really do differ');
    });

    test('subunits take precedence over their parent', () async {
      final Map<String, (double, double)> territories =
          <String, (double, double)>{
        'GF': (4.922, -52.313), // Cayenne, was FR
        'GP': (16.241, -61.533), // Pointe-a-Pitre, was FR
        'MQ': (14.616, -61.058), // Fort-de-France, was null
        'RE': (-20.882, 55.450), // Saint-Denis, was FR
        'YT': (-12.787, 45.275), // Dzaoudzi, was null
        'CC': (-12.157, 96.826), // West Island, was null
        'CX': (-10.4506, 105.6906), // Christmas Island airport, was AU
        'TK': (-9.350, -171.1934), // Fakaofo, was null
      };
      for (final MapEntry<String, (double, double)> e in territories.entries) {
        expect(await Borders.countryAt(e.value.$1, e.value.$2), e.key,
            reason: 'expected ${e.key}');
        expect(repo.has(e.key), isTrue,
            reason: '${e.key} must have numbers or the hit is wasted');
      }
    });

    test('the parents are untouched by the overlay', () async {
      expect(await Borders.countryAt(52.374, 4.890), 'NL'); // Amsterdam
      expect(await Borders.countryAt(48.857, 2.352), 'FR'); // Paris
      expect(await Borders.countryAt(-33.869, 151.209), 'AU'); // Sydney
      expect(await Borders.countryAt(12.117, -68.933), 'CW'); // Willemstad
    });
  });

  group('F3: a later location result fully replaces the earlier one', () {
    test('GPS hit on a country with no numbers is surfaced, not hidden',
        () async {
      // Heard Island (HM) has border geometry but no emergency numbers.
      final FakeNative native = FakeNative(
        networkIso: 'AU',
        locationPermitted: true,
        fix: FakeNative.geoFix(-53.1, 73.5),
      )..install();
      final CountryDetector detector = CountryDetector(repo);

      final Detection d =
          await detector.refineWithLocation(await detector.detectQuick());
      expect(native.callsTo('location'), hasLength(1));
      expect(d.iso, 'AU', reason: 'falls through to the network');
      expect(d.source, CountrySource.network);
      expect(d.gpsIso, isNull);
      expect(d.gpsUnsupportedIso, 'HM');
      expect(d.locationError, 'No emergency numbers on file for HM');
    });

    test('permission denied after a good fix clears the GPS country',
        () async {
      final FakeNative native = FakeNative(
        networkIso: 'DE',
        locationPermitted: true,
        fix: FakeNative.geoFix(48.857, 2.352),
      )..install();
      final CountryDetector detector = CountryDetector(repo);

      final Detection inParis =
          await detector.refineWithLocation(await detector.detectQuick());
      expect(inParis.source, CountrySource.gps);

      // User revokes location in settings and comes back.
      native.locationPermitted = false;
      final Detection revoked = await detector.refineWithLocation(inParis);
      expect(revoked.gpsIso, isNull);
      expect(revoked.fix, isNull);
      expect(revoked.source, CountrySource.network);
      expect(revoked.iso, 'DE');
      expect(revoked.locationPermitted, isFalse);
    });
  });

  group('F10: permanent denial is reported so the UI can route to settings', () {
    test('detectQuick surfaces permanent denial', () async {
      FakeNative(networkIso: 'DE')
        ..permanentlyDenied = true
        ..install();

      final Detection d = await CountryDetector(repo).detectQuick();
      expect(d.locationPermitted, isFalse);
      expect(d.locationPermanentlyDenied, isTrue);
    });

    test('refine with permanent denial names app settings in the error',
        () async {
      FakeNative(networkIso: 'DE')
        ..permanentlyDenied = true
        ..install();
      final CountryDetector detector = CountryDetector(repo);

      final Detection d = await detector.refineWithLocation(
        await detector.detectQuick(),
        requestPermission: true,
      );
      expect(d.locationPermanentlyDenied, isTrue);
      expect(d.locationError, contains('app settings'));
      expect(d.iso, 'DE', reason: 'numbers stay on screen');
    });
  });

  group('F21: a failed preference write is reported', () {
    test('setManual returns true when the write succeeds', () async {
      FakeNative().install();
      expect(await CountryDetector(repo).setManual('JP'), isTrue);
    });

    test('setManual returns false when the channel is missing', () async {
      // No handler installed: MissingPluginException on every call.
      expect(await CountryDetector(repo).setManual('JP'), isFalse);
    });
  });
}
