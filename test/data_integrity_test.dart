import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sos_numbers/src/borders.dart';
import 'package:sos_numbers/src/numbers_repository.dart';

/// Integrity of the two shipped assets, read exactly as the app reads them.
/// Nothing here is mocked or fixtured: a failure means the generators produced
/// something the app cannot safely show.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late NumbersRepository repo;
  late Map<String, Object?> numbersJson;
  late Map<String, Object?> numbersRaw;
  late List<String> borderCodes;

  setUpAll(() async {
    repo = await NumbersRepository.load();

    numbersJson = json.decode(
      await rootBundle.loadString('assets/data/emergency_numbers.json'),
    ) as Map<String, Object?>;
    numbersRaw =
        (numbersJson['countries']! as Map<Object?, Object?>).cast<String, Object?>();

    final Map<String, Object?> geo = json.decode(
      await rootBundle.loadString('assets/geo/country_borders.json'),
    ) as Map<String, Object?>;
    borderCodes = (geo['countries']! as List<Object?>)
        .map((Object? e) =>
            ((e! as Map<Object?, Object?>)['c']! as String).toUpperCase())
        .toList(growable: false);
  });

  group('borders vs numbers', () {
    test('border codes are well formed and unique', () {
      final RegExp alpha2 = RegExp(r'^[A-Z]{2}$');
      for (final String code in borderCodes) {
        expect(alpha2.hasMatch(code), isTrue, reason: 'bad border code "$code"');
      }
      expect(borderCodes.toSet(), hasLength(borderCodes.length),
          reason: 'a country appears twice in the border asset');
      expect(borderCodes.length, greaterThanOrEqualTo(200));
    });

    test('every border code that has numbers round-trips', () {
      final Set<String> numbers = repo.all
          .map((CountryNumbers c) => c.iso)
          .toSet();
      final Set<String> shared =
          borderCodes.where(numbers.contains).toSet();

      expect(shared, hasLength(greaterThanOrEqualTo(200)),
          reason: 'the two assets barely overlap, something is wrong');

      for (final String code in shared) {
        final CountryNumbers? c = repo.forIso(code);
        expect(c, isNotNull, reason: '$code vanished from the repository');
        expect(c!.iso, code, reason: '$code does not round-trip');
        expect(repo.has(code.toLowerCase()), isTrue,
            reason: '$code is not found case-insensitively');
        expect(repo.forIso(code.toLowerCase())!.iso, code);
        expect(c.primary, isNotNull, reason: '$code has no dialable number');
      }
    });

    test('report the asymmetry between the two assets', () {
      final Set<String> numbers =
          repo.all.map((CountryNumbers c) => c.iso).toSet();
      final Set<String> borders = borderCodes.toSet();

      final List<String> bordersWithoutNumbers =
          borders.difference(numbers).toList()..sort();
      final List<String> numbersWithoutBorders =
          numbers.difference(borders).toList()..sort();

      debugPrint('borders: ${borders.length} codes, '
          'numbers: ${numbers.length} codes, '
          'shared: ${borders.intersection(numbers).length}');
      debugPrint('border codes with no numbers entry '
          '(${bordersWithoutNumbers.length}): '
          '${bordersWithoutNumbers.join(', ')}');
      debugPrint('numbers entries with no border geometry '
          '(${numbersWithoutBorders.length}): '
          '${numbersWithoutBorders.map((String iso) => '$iso '
              '(${repo.forIso(iso)!.name})').join(', ')}');

      // Reported, not enforced: neither list is an error on its own.
      expect(bordersWithoutNumbers, isA<List<String>>());
      expect(numbersWithoutBorders, isA<List<String>>());
    });

    test('report which country a fix inside a border-less territory resolves to',
        () async {
      // Territories that have their own numbers entry but no polygon of their
      // own: a fix there resolves to the parent country, so the app shows the
      // parent's numbers. Reported, not enforced.
      const Map<String, (double, double)> capitals = <String, (double, double)>{
        'BQ': (12.1508, -68.2767), // Kralendijk
        'CC': (-12.1642, 96.8710), // West Island
        'CX': (-10.4475, 105.6904), // Flying Fish Cove
        'GF': (4.9227, -52.3269), // Cayenne
        'GP': (16.2412, -61.5340), // Pointe-a-Pitre
        'MQ': (14.6161, -61.0588), // Fort-de-France
        'RE': (-20.8789, 55.4481), // Saint-Denis
        'TK': (-9.3800, -171.2200), // Fakaofo
        'YT': (-12.7806, 45.2278), // Mamoudzou
      };

      for (final MapEntry<String, (double, double)> e in capitals.entries) {
        final String? got = await Borders.countryAt(e.value.$1, e.value.$2);
        final CountryNumbers own = repo.forIso(e.key)!;
        final CountryNumbers? resolved = repo.forIso(got);
        debugPrint('${e.key} (${own.name}) capital resolves to '
            '${got ?? 'no country'}'
            '${resolved == null ? '' : ' (${resolved.name})'}: '
            'own primary ${own.primary}, '
            'shown primary ${resolved?.primary ?? 'none'}');
      }
    });
  });

  group('numbers dataset', () {
    test('the envelope is sane', () {
      expect(numbersJson['schema'], isNotNull);
      expect(numbersJson['source'], isA<String>());
      expect((numbersJson['source']! as String), isNotEmpty);
      expect(DateTime.parse(numbersJson['generated_utc']! as String).year,
          greaterThanOrEqualTo(2024));
      expect(repo.generatedUtc, numbersJson['generated_utc']);
      expect(repo.length, numbersRaw.length);
    });

    test('notes are never null', () {
      numbersRaw.forEach((String iso, Object? value) {
        final Map<Object?, Object?> entry = value! as Map<Object?, Object?>;
        expect(entry.containsKey('notes'), isTrue,
            reason: '$iso has no notes key');
        expect(entry['notes'], isA<String>(),
            reason: '$iso has null or non-string notes');
      });
      for (final CountryNumbers c in repo.all) {
        expect(c.notes, isNotNull);
      }
    });

    test('names are never empty and never padded', () {
      for (final CountryNumbers c in repo.all) {
        expect(c.name, isNotEmpty, reason: '${c.iso} has no name');
        expect(c.name.trim(), c.name, reason: '${c.iso} name is padded');
        expect(c.name.trim(), isNotEmpty, reason: '${c.iso} name is blank');
      }
    });

    test('no number contains whitespace', () {
      final RegExp whitespace = RegExp(r'\s');
      for (final CountryNumbers c in repo.all) {
        for (final (String field, String? number) in <(String, String?)>[
          ('general', c.general),
          ('police', c.police),
          ('ambulance', c.ambulance),
          ('fire', c.fire),
          ('primary', c.primary),
        ]) {
          if (number == null) continue;
          expect(whitespace.hasMatch(number), isFalse,
              reason: '${c.iso} $field is "$number"');
          expect(number, isNotEmpty, reason: '${c.iso} $field is empty');
        }
      }
    });

    test('the key and the entry agree on the ISO code', () {
      numbersRaw.forEach((String iso, Object? value) {
        final Map<Object?, Object?> entry = value! as Map<Object?, Object?>;
        expect((entry['iso']! as String).toUpperCase(), iso.toUpperCase(),
            reason: 'key $iso disagrees with its entry');
        expect(RegExp(r'^[A-Za-z]{2}$').hasMatch(iso), isTrue,
            reason: '$iso is not an alpha-2 code');
      });
    });

    test('the service list matches the fields that are present', () {
      for (final CountryNumbers c in repo.all) {
        final int expected = <String?>[c.police, c.ambulance, c.fire]
            .where((String? n) => n != null)
            .length;
        expect(c.services, hasLength(expected), reason: c.iso);
        for (final ServiceNumber s in c.services) {
          expect(s.number, isNotEmpty);
          expect(s.service, isNot(Service.general));
        }
        expect(c.hasUniversalNumber, c.general != null, reason: c.iso);
        if (c.hasUniversalNumber) expect(c.primary, c.general, reason: c.iso);
      }
    });

    test('search is case and code insensitive across the whole dataset', () {
      for (final CountryNumbers c in repo.all) {
        expect(
          repo.search(c.iso.toLowerCase()).map((CountryNumbers x) => x.iso),
          contains(c.iso),
          reason: 'searching ${c.iso} does not find it',
        );
        expect(
          repo.search(c.name.toUpperCase()).map((CountryNumbers x) => x.iso),
          contains(c.iso),
          reason: 'searching ${c.name} does not find it',
        );
      }
      expect(repo.search('   ').length, repo.length,
          reason: 'a blank query lists everything');
    });

    test('the list is sorted by name, case insensitively', () {
      final List<String> names =
          repo.all.map((CountryNumbers c) => c.name.toLowerCase()).toList();
      final List<String> sorted = List<String>.of(names)..sort();
      expect(names, sorted);
    });
  });
}
