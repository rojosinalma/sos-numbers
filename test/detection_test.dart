import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sos_numbers/src/detection.dart';
import 'package:sos_numbers/src/native.dart';
import 'package:sos_numbers/src/numbers_repository.dart';

import 'support/fake_native.dart';

/// Unit-level coverage of the detection priority chain:
/// manual > gps > network > sim > locale.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NumbersRepository repo;

  setUpAll(() async {
    repo = await NumbersRepository.load();
  });

  // Berlin, Paris and a point in the middle of the South Atlantic.
  const (double, double) berlin = (52.5200, 13.4050);
  const (double, double) paris = (48.8566, 2.3522);
  const (double, double) ocean = (0.0, -30.0);

  group('priority', () {
    test('a manual choice beats every other signal', () async {
      final FakeNative native = FakeNative(
        networkIso: 'DE',
        simIso: 'AR',
        localeIso: 'US',
        hasSim: true,
      )..install();
      final CountryDetector detector = CountryDetector(repo);

      await detector.setManual('jp');
      final Detection d = await detector.detectQuick();

      expect(d.iso, 'JP');
      expect(d.source, CountrySource.manual);
      expect(d.isManual, isTrue);
      expect(d.source.label, 'Chosen by you');
      expect(d.source.isTrustworthy, isTrue);
      // The weaker signals are still reported, just not used.
      expect(d.networkIso, 'DE');
      expect(d.simIso, 'AR');
      expect(d.localeIso, 'US');
      expect(native.prefs.values, contains('JP'));
    });

    test('a manual choice beats a GPS fix that says otherwise', () async {
      FakeNative(
        networkIso: 'DE',
        locationPermitted: true,
        fix: FakeNative.geoFix(berlin.$1, berlin.$2),
      ).install();
      final CountryDetector detector = CountryDetector(repo);

      await detector.setManual('FR');
      final Detection quick = await detector.detectQuick();
      final Detection refined = await detector.refineWithLocation(quick);

      expect(refined.gpsIso, 'DE', reason: 'the fix was still resolved');
      expect(refined.iso, 'FR');
      expect(refined.source, CountrySource.manual);
      expect(refined.locationError, isNull);
    });

    test('clearing the manual choice hands control back to the signals',
        () async {
      FakeNative(networkIso: 'DE').install();
      final CountryDetector detector = CountryDetector(repo);

      await detector.setManual('JP');
      expect((await detector.detectQuick()).source, CountrySource.manual);

      await detector.setManual(null);
      final Detection d = await detector.detectQuick();
      expect(d.iso, 'DE');
      expect(d.source, CountrySource.network);
      expect(d.manualIso, isNull);
    });

    test('GPS beats the mobile network, and the disagreement is flagged',
        () async {
      FakeNative(
        networkIso: 'DE',
        simIso: 'DE',
        localeIso: 'DE',
        locationPermitted: true,
        fix: FakeNative.geoFix(paris.$1, paris.$2, accuracy: 12),
      ).install();
      final CountryDetector detector = CountryDetector(repo);

      final Detection quick = await detector.detectQuick();
      expect(quick.iso, 'DE');
      expect(quick.source, CountrySource.network);
      expect(quick.signalsDisagree, isFalse);

      final Detection refined = await detector.refineWithLocation(quick);
      expect(refined.gpsIso, 'FR');
      expect(refined.iso, 'FR');
      expect(refined.source, CountrySource.gps);
      expect(refined.signalsDisagree, isTrue);
      expect(refined.locationPermitted, isTrue);
      expect(refined.locationTried, isTrue);
      expect(refined.locationError, isNull);
      expect(refined.fix?.provider, 'gps');
      expect(refined.fix?.accuracyMetres, 12);
      expect(refined.source.isTrustworthy, isTrue);
    });

    test('agreeing GPS and network do not count as a disagreement', () async {
      FakeNative(
        networkIso: 'DE',
        locationPermitted: true,
        fix: FakeNative.geoFix(berlin.$1, berlin.$2),
      ).install();
      final CountryDetector detector = CountryDetector(repo);

      final Detection refined =
          await detector.refineWithLocation(await detector.detectQuick());
      expect(refined.iso, 'DE');
      expect(refined.source, CountrySource.gps);
      expect(refined.signalsDisagree, isFalse);
    });

    test('the network beats the SIM', () async {
      FakeNative(networkIso: 'DE', simIso: 'AR', localeIso: 'US', hasSim: true)
          .install();

      final Detection d = await CountryDetector(repo).detectQuick();
      expect(d.iso, 'DE');
      expect(d.source, CountrySource.network);
    });

    test('the SIM beats the locale', () async {
      FakeNative(simIso: 'AR', localeIso: 'US', hasSim: true).install();

      final Detection d = await CountryDetector(repo).detectQuick();
      expect(d.iso, 'AR');
      expect(d.source, CountrySource.sim);
      expect(d.source.isTrustworthy, isFalse,
          reason: 'the SIM says where you are from, not where you are');
    });

    test('the locale is used when nothing better exists', () async {
      FakeNative(localeIso: 'US').install();

      final Detection d = await CountryDetector(repo).detectQuick();
      expect(d.iso, 'US');
      expect(d.source, CountrySource.locale);
      expect(d.source.isTrustworthy, isFalse);
    });

    test('no signals at all leaves the country undetermined', () async {
      FakeNative().install();

      final Detection d = await CountryDetector(repo).detectQuick();
      expect(d.iso, isNull);
      expect(d.source, CountrySource.none);
      expect(d.source.label, 'Not determined');
      expect(d.networkIso, isNull);
      expect(d.simIso, isNull);
      expect(d.localeIso, isNull);
      expect(d.manualIso, isNull);
      expect(d.signalsDisagree, isFalse);
    });

    test('a missing channel implementation does not crash detection', () async {
      // No mock handler installed at all, i.e. the platform side is not there.
      // Every Native call funnels through one guard that swallows
      // MissingPluginException, so detection degrades to "not determined"
      // and the UI falls back to manual selection instead of a red screen.
      final Detection d = await CountryDetector(repo).detectQuick();
      expect(d.iso, isNull);
      expect(d.source, CountrySource.none);
    });
  });

  group('garbage signals', () {
    test('an unknown code falls through to the next signal', () async {
      FakeNative(networkIso: 'ZZ', simIso: 'AR').install();

      final Detection d = await CountryDetector(repo).detectQuick();
      expect(d.networkIso, isNull, reason: 'ZZ is not a country we know');
      expect(d.iso, 'AR');
      expect(d.source, CountrySource.sim);
    });

    test('an empty and an over-long code are both ignored', () async {
      FakeNative(networkIso: '', simIso: 'usa', localeIso: 'DE').install();

      final Detection d = await CountryDetector(repo).detectQuick();
      expect(d.networkIso, isNull);
      expect(d.simIso, isNull, reason: '"usa" is alpha-3, not alpha-2');
      expect(d.iso, 'DE');
      expect(d.source, CountrySource.locale);
    });

    test('a lowercase code still works', () async {
      FakeNative(networkIso: 'de').install();

      final Detection d = await CountryDetector(repo).detectQuick();
      expect(d.networkIso, 'DE');
      expect(d.iso, 'DE');
      expect(d.source, CountrySource.network);
    });

    test('a padded code still works', () async {
      FakeNative(networkIso: ' fr ').install();

      final Detection d = await CountryDetector(repo).detectQuick();
      expect(d.iso, 'FR');
      expect(d.source, CountrySource.network);
    });

    test('every signal being garbage leaves nothing determined', () async {
      FakeNative(networkIso: 'ZZ', simIso: 'XX', localeIso: '??').install();

      final Detection d = await CountryDetector(repo).detectQuick();
      expect(d.iso, isNull);
      expect(d.source, CountrySource.none);
    });

    test('a stored manual choice for an unknown country is ignored', () async {
      FakeNative(networkIso: 'DE', prefs: <String, String>{'manual_iso': 'ZZ'})
          .install();

      final Detection d = await CountryDetector(repo).detectQuick();
      expect(d.manualIso, isNull);
      expect(d.iso, 'DE');
      expect(d.source, CountrySource.network);
    });
  });

  group('location refine', () {
    test('a denied permission leaves the previous source in place', () async {
      final FakeNative native = FakeNative(networkIso: 'DE')..install();
      final CountryDetector detector = CountryDetector(repo);

      final Detection quick = await detector.detectQuick();
      final Detection refined =
          await detector.refineWithLocation(quick, requestPermission: true);

      expect(refined.iso, 'DE');
      expect(refined.source, CountrySource.network);
      expect(refined.gpsIso, isNull);
      expect(refined.locationPermitted, isFalse);
      expect(refined.locationTried, isTrue);
      expect(refined.locationError, 'Location permission not granted');
      expect(refined.fix, isNull);
      expect(native.callsTo('requestLocationPermission'), hasLength(1));
      expect(native.callsTo('location'), isEmpty,
          reason: 'never ask for a fix without permission');
    });

    test('no permission and no request does not even ask', () async {
      final FakeNative native = FakeNative(localeIso: 'US')..install();
      final CountryDetector detector = CountryDetector(repo);

      final Detection refined =
          await detector.refineWithLocation(await detector.detectQuick());

      expect(refined.source, CountrySource.locale);
      expect(refined.locationError, 'Location permission not granted');
      expect(native.callsTo('requestLocationPermission'), isEmpty);
    });

    test('a granted permission is used immediately', () async {
      final FakeNative native = FakeNative(
        networkIso: 'DE',
        grantPermissionWhenAsked: true,
        fix: FakeNative.geoFix(paris.$1, paris.$2),
      )..install();
      final CountryDetector detector = CountryDetector(repo);

      final Detection refined = await detector.refineWithLocation(
        await detector.detectQuick(),
        requestPermission: true,
      );

      expect(refined.source, CountrySource.gps);
      expect(refined.iso, 'FR');
      expect(native.callsTo('location'), hasLength(1));
      final Map<Object?, Object?> args = native.lastArgs('location');
      expect(args['timeoutMs'], isA<int>());
      expect(args['maxAgeMs'], isA<int>());
    });

    test('a fix in the ocean matches no country', () async {
      FakeNative(
        networkIso: 'DE',
        locationPermitted: true,
        fix: FakeNative.geoFix(ocean.$1, ocean.$2, provider: 'network'),
      ).install();
      final CountryDetector detector = CountryDetector(repo);

      final Detection refined =
          await detector.refineWithLocation(await detector.detectQuick());

      expect(refined.gpsIso, isNull);
      expect(refined.iso, 'DE');
      expect(refined.source, CountrySource.network,
          reason: 'fall back to the signal we already had');
      expect(refined.locationError, 'Location is not inside any country');
      expect(refined.fix?.latitude, 0);
      expect(refined.signalsDisagree, isFalse);
    });

    test('an unavailable fix is reported without losing the country', () async {
      FakeNative(networkIso: 'DE', locationPermitted: true).install();
      final CountryDetector detector = CountryDetector(repo);

      final Detection refined =
          await detector.refineWithLocation(await detector.detectQuick());

      expect(refined.iso, 'DE');
      expect(refined.source, CountrySource.network);
      expect(refined.locationError, 'No recent location fix available');
      expect(refined.locationTried, isTrue);
    });

    test('refining with no other signal at all still yields the GPS country',
        () async {
      FakeNative(
        locationPermitted: true,
        fix: FakeNative.geoFix(paris.$1, paris.$2),
      ).install();
      final CountryDetector detector = CountryDetector(repo);

      final Detection quick = await detector.detectQuick();
      expect(quick.source, CountrySource.none);

      final Detection refined = await detector.refineWithLocation(quick);
      expect(refined.iso, 'FR');
      expect(refined.source, CountrySource.gps);
      expect(refined.signalsDisagree, isFalse,
          reason: 'there is no network signal to disagree with');
    });

    test('a later fix in the ocean drops the stale GPS country', () async {
      final FakeNative native = FakeNative(
        networkIso: 'DE',
        locationPermitted: true,
        fix: FakeNative.geoFix(paris.$1, paris.$2),
      )..install();
      final CountryDetector detector = CountryDetector(repo);

      final Detection inParis =
          await detector.refineWithLocation(await detector.detectQuick());
      expect(inParis.source, CountrySource.gps);
      expect(inParis.gpsIso, 'FR');

      // Same session, a new fix that resolves to nothing.
      native.fix = FakeNative.geoFix(ocean.$1, ocean.$2);
      final Detection atSea = await detector.refineWithLocation(inParis);

      expect(atSea.gpsIso, isNull);
      expect(atSea.source, CountrySource.network);
      expect(atSea.iso, 'DE');
      expect(atSea.locationError, 'Location is not inside any country');
    });

    test('a successful fix clears an earlier location error', () async {
      final FakeNative native = FakeNative(networkIso: 'DE')..install();
      final CountryDetector detector = CountryDetector(repo);

      final Detection denied = await detector.refineWithLocation(
        await detector.detectQuick(),
        requestPermission: true,
      );
      expect(denied.locationError, 'Location permission not granted');

      native.locationPermitted = true;
      native.fix = FakeNative.geoFix(paris.$1, paris.$2);
      final Detection granted = await detector.refineWithLocation(denied);

      expect(granted.gpsIso, 'FR');
      expect(granted.locationError, isNull);
    });
  });

  group('CountrySource labels', () {
    test('every source has a label and a caveat', () {
      for (final CountrySource s in CountrySource.values) {
        expect(s.label, isNotEmpty);
        expect(s.caveat, isNotEmpty);
      }
    });

    test('only manual, GPS and network are trustworthy', () {
      expect(
        CountrySource.values
            .where((CountrySource s) => s.isTrustworthy)
            .toSet(),
        <CountrySource>{
          CountrySource.manual,
          CountrySource.gps,
          CountrySource.network,
        },
      );
    });

    test('the weak sources tell the user to check', () {
      expect(CountrySource.sim.caveat, contains('Check this is right'));
      expect(CountrySource.locale.caveat, contains('Check this is right'));
    });
  });

  group('Native decoding', () {
    test('telephonyHints tolerates junk from the platform', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FakeNative.channel,
              (MethodCall call) async {
        if (call.method != 'telephonyHints') return null;
        return <String, Object?>{
          'networkIso': 42,
          'simIso': 'D',
          'localeIso': 'de',
          'hasSim': 'yes',
        };
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(FakeNative.channel, null);
      });

      final TelephonyHints hints = await Native.telephonyHints();
      expect(hints.networkIso, isNull, reason: 'not a String');
      expect(hints.simIso, isNull, reason: 'not two letters');
      expect(hints.localeIso, 'DE');
      expect(hints.hasSim, isFalse, reason: 'only a real bool counts');
    });

    test('a platform exception is swallowed rather than thrown', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FakeNative.channel,
              (MethodCall call) async {
        throw PlatformException(code: 'boom');
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(FakeNative.channel, null);
      });

      expect((await Native.telephonyHints()).networkIso, isNull);
      expect(await Native.hasLocationPermission(), isFalse);
      expect(await Native.requestLocationPermission(), isFalse);
      expect(await Native.location(), isNull);
      expect(await Native.openDialer('112'), isFalse);
      expect(await Native.prefGet('manual_iso'), isNull);
      await Native.prefSet('manual_iso', 'DE'); // must not throw
    });

    test('a location reply without coordinates is not a fix', () async {
      FakeNative(fix: <String, Object?>{'provider': 'gps'}).install();
      expect(await Native.location(), isNull);
    });
  });
}
