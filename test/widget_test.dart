import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sos_numbers/main.dart';
import 'package:sos_numbers/src/borders.dart';
import 'package:sos_numbers/src/numbers_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('emergency numbers dataset', () {
    test('loads and covers the world', () async {
      final NumbersRepository repo = await NumbersRepository.load();
      expect(repo.length, greaterThanOrEqualTo(190));
      expect(repo.all.length, repo.length);
    });

    test('known countries carry the right numbers', () async {
      final NumbersRepository repo = await NumbersRepository.load();

      expect(repo.forIso('DE')!.general, '112');
      expect(repo.forIso('DE')!.police, '110');
      expect(repo.forIso('US')!.general, '911');
      expect(repo.forIso('GB')!.police, '999');
      expect(repo.forIso('AR')!.general, '911');
      expect(repo.forIso('AR')!.ambulance, '107');
      expect(repo.forIso('JP')!.police, '110');
      expect(repo.forIso('JP')!.fire, '119');
      expect(repo.forIso('AU')!.general, '000');
      expect(repo.forIso('NZ')!.general, '111');
    });

    test('every entry is dialable', () async {
      final NumbersRepository repo = await NumbersRepository.load();
      final RegExp dialable = RegExp(r'^[0-9*#+]{2,12}$');
      for (final CountryNumbers c in repo.all) {
        expect(c.primary, isNotNull, reason: '${c.iso} has no number at all');
        for (final String? n in <String?>[
          c.general,
          c.police,
          c.ambulance,
          c.fire,
        ]) {
          if (n != null) {
            expect(dialable.hasMatch(n), isTrue,
                reason: '${c.iso} has non-dialable "$n"');
          }
        }
      }
    });

    test('search finds countries by name and code', () async {
      final NumbersRepository repo = await NumbersRepository.load();
      expect(repo.search('german').map((CountryNumbers c) => c.iso),
          contains('DE'));
      expect(repo.search('jp').map((CountryNumbers c) => c.iso), contains('JP'));
      expect(repo.search('zzzzz'), isEmpty);
    });
  });

  group('offline border lookup', () {
    test('resolves cities to the right country', () async {
      final Map<String, (double, double)> cities = <String, (double, double)>{
        'DE': (52.5200, 13.4050),
        'FR': (48.8566, 2.3522),
        'GB': (51.5074, -0.1278),
        'US': (40.7128, -74.0060),
        'AR': (-34.6037, -58.3816),
        'JP': (35.6762, 139.6503),
        'AU': (-33.8688, 151.2093),
        'ZA': (-33.9249, 18.4241),
      };
      for (final MapEntry<String, (double, double)> e in cities.entries) {
        final (double lat, double lon) = e.value;
        expect(await Borders.countryAt(lat, lon), e.key,
            reason: 'expected ${e.key}');
      }
    });

    test('open ocean resolves to nothing', () async {
      expect(await Borders.countryAt(0, -30), isNull);
    });

    test('every resolved code exists in the numbers dataset', () async {
      final NumbersRepository repo = await NumbersRepository.load();
      for (final (double, double) point in <(double, double)>[
        (52.52, 13.405),
        (-34.6037, -58.3816),
        (1.3521, 103.8198),
      ]) {
        final String? iso = await Borders.countryAt(point.$1, point.$2);
        expect(repo.has(iso), isTrue, reason: '$iso missing from dataset');
      }
    });
  });

  group('app', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('dev.rojo.sos_numbers/native'),
        (MethodCall call) async => switch (call.method) {
          'telephonyHints' => <String, Object?>{
              'networkIso': 'DE',
              'simIso': 'AR',
              'localeIso': 'US',
              'hasSim': true,
            },
          'hasLocationPermission' => false,
          'requestLocationPermission' => false,
          'prefGet' => null,
          'prefSet' => null,
          'openDialer' => true,
          _ => null,
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('dev.rojo.sos_numbers/native'),
        null,
      );
    });

    testWidgets('shows the network country and its number', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const SosNumbersApp());
      await tester.pumpAndSettle();

      expect(find.text('Germany'), findsOneWidget);
      expect(find.text('112'), findsWidgets);
      expect(find.text('110'), findsOneWidget); // police
      expect(find.text('From your mobile network'), findsOneWidget);
    });
  });
}
