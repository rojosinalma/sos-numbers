import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sos_numbers/main.dart';
import 'package:sos_numbers/src/borders.dart';
import 'package:sos_numbers/src/numbers_repository.dart';

import 'support/fake_native.dart';

/// Widget behaviour of SosNumbersApp / HomePage, driven only through the real
/// assets and the mocked platform channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const (double, double) paris = (48.8566, 2.3522);
  const (double, double) berlin = (52.5200, 13.4050);

  /// A viewport tall enough that the whole ListView is laid out, so banners
  /// further down the page can be found without scrolling.
  ///
  /// The asset load is done through [WidgetTester.runAsync] first: rootBundle
  /// needs real async, which the fake clock inside testWidgets cannot drive.
  /// NumbersRepository caches its instance, so this happens once per suite.
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => NumbersRepository.load());
    await tester.pumpWidget(const SosNumbersApp());
    await tester.pumpAndSettle();
  }

  /// Border lookups run in a real isolate, which the fake async clock inside
  /// testWidgets cannot drive. Resolving the point up front puts it in the
  /// Borders result cache, so the widget's own lookup returns straight away.
  Future<void> warmBorders(WidgetTester tester, (double, double) point) async {
    await tester.runAsync(() => Borders.countryAt(point.$1, point.$2));
  }

  /// Lets a SnackBar time out, otherwise its dismissal timer outlives the test.
  Future<void> settleSnackBar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  group('weak signal warning', () {
    testWidgets('a SIM-only result warns the user to verify the country',
        (WidgetTester tester) async {
      FakeNative(simIso: 'AR', hasSim: true).install();
      await pumpApp(tester);

      expect(find.text('Argentina'), findsOneWidget);
      expect(find.text('From your SIM card'), findsOneWidget);
      expect(find.text('Verify this country'), findsOneWidget);
      expect(
        find.textContaining('The country that issued your SIM'),
        findsOneWidget,
      );
      expect(find.text('Allow location'), findsOneWidget);
    });

    testWidgets('a locale-only result warns too',
        (WidgetTester tester) async {
      FakeNative(localeIso: 'US').install();
      await pumpApp(tester);

      expect(find.text('United States'), findsOneWidget);
      expect(find.text('From your phone language'), findsOneWidget);
      expect(find.text('Verify this country'), findsOneWidget);
      expect(find.textContaining('Only a guess from your phone language'),
          findsOneWidget);
    });

    testWidgets('a mobile network result does not warn',
        (WidgetTester tester) async {
      FakeNative(networkIso: 'DE', simIso: 'AR', hasSim: true).install();
      await pumpApp(tester);

      expect(find.text('Germany'), findsOneWidget);
      expect(find.text('From your mobile network'), findsOneWidget);
      expect(find.text('Verify this country'), findsNothing);
    });

    testWidgets('a GPS result does not warn', (WidgetTester tester) async {
      await warmBorders(tester, berlin);
      FakeNative(
        simIso: 'AR',
        hasSim: true,
        locationPermitted: true,
        fix: FakeNative.geoFix(berlin.$1, berlin.$2),
      ).install();
      await pumpApp(tester);

      expect(find.text('Germany'), findsOneWidget);
      expect(find.text('From your location'), findsOneWidget);
      expect(find.text('Verify this country'), findsNothing);
    });
  });

  group('disagreement banner', () {
    testWidgets('names both codes when GPS and network differ',
        (WidgetTester tester) async {
      await warmBorders(tester, paris);
      FakeNative(
        networkIso: 'DE',
        locationPermitted: true,
        fix: FakeNative.geoFix(paris.$1, paris.$2),
      ).install();
      await pumpApp(tester);

      expect(find.text('France'), findsOneWidget);
      expect(find.text('Near a border?'), findsOneWidget);
      expect(
        find.textContaining(
          'Your location says FR but your mobile network says DE',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Showing FR'), findsOneWidget);
      expect(find.text('Verify this country'), findsNothing,
          reason: 'GPS is a trustworthy source');
    });

    testWidgets('is absent when the signals agree',
        (WidgetTester tester) async {
      await warmBorders(tester, berlin);
      FakeNative(
        networkIso: 'DE',
        locationPermitted: true,
        fix: FakeNative.geoFix(berlin.$1, berlin.$2),
      ).install();
      await pumpApp(tester);

      expect(find.text('Near a border?'), findsNothing);
    });
  });

  group('dialing', () {
    testWidgets('tapping the big button opens the dialer with the number',
        (WidgetTester tester) async {
      final FakeNative native = FakeNative(networkIso: 'DE')..install();
      await pumpApp(tester);

      expect(native.callsTo('openDialer'), isEmpty);
      await tester.tap(find.text('ALL EMERGENCY SERVICES'));
      await tester.pumpAndSettle();

      expect(native.callsTo('openDialer'), hasLength(1));
      expect(native.lastCallTo('openDialer')!.arguments,
          <String, Object?>{'number': '112'});
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('tapping a service tile dials that service',
        (WidgetTester tester) async {
      final FakeNative native = FakeNative(networkIso: 'AR')..install();
      await pumpApp(tester);

      await tester.tap(find.text('Ambulance'));
      await tester.pumpAndSettle();

      expect(native.lastCallTo('openDialer')!.arguments,
          <String, Object?>{'number': '107'});
    });

    testWidgets('a missing dialer is reported instead of failing silently',
        (WidgetTester tester) async {
      FakeNative(networkIso: 'DE', dialerAvailable: false).install();
      await pumpApp(tester);

      await tester.tap(find.text('ALL EMERGENCY SERVICES'));
      await tester.pumpAndSettle();

      expect(find.text('No dialer app available. Number: 112'), findsOneWidget);
      await settleSnackBar(tester);
    });
  });

  group('copying', () {
    testWidgets('long-pressing a service tile copies it and says so',
        (WidgetTester tester) async {
      final FakeClipboard clipboard = FakeClipboard()..install();
      FakeNative(networkIso: 'AR').install();
      await pumpApp(tester);

      await tester.longPress(find.text('Ambulance'));
      await tester.pumpAndSettle();

      expect(clipboard.writes, <String>['107']);
      expect((await Clipboard.getData(Clipboard.kTextPlain))?.text, '107');
      expect(find.text('Copied 107'), findsOneWidget);
      await settleSnackBar(tester);
    });

    testWidgets('long-pressing the big button copies the primary number',
        (WidgetTester tester) async {
      final FakeClipboard clipboard = FakeClipboard()..install();
      FakeNative(networkIso: 'DE').install();
      await pumpApp(tester);

      await tester.longPress(find.text('ALL EMERGENCY SERVICES'));
      await tester.pumpAndSettle();

      expect(clipboard.writes, <String>['112']);
      expect(find.text('Copied 112'), findsOneWidget);
      await settleSnackBar(tester);
    });
  });

  group('no country', () {
    testWidgets('offers a manual choice when nothing is detected',
        (WidgetTester tester) async {
      FakeNative().install();
      await pumpApp(tester);

      expect(find.text('Country not determined'), findsOneWidget);
      expect(
        find.textContaining('Pick your country to see its emergency numbers'),
        findsOneWidget,
      );
      expect(find.textContaining('112 or 911'), findsWidgets,
          reason: 'the fallback advice must be visible when we have nothing');
      expect(find.widgetWithText(FilledButton, 'Choose country'),
          findsOneWidget);
      expect(find.text('Unknown country'), findsOneWidget);
      expect(find.text('??'), findsOneWidget);
      expect(find.text('ALL EMERGENCY SERVICES'), findsNothing);
      expect(find.text('MAIN EMERGENCY NUMBER'), findsNothing);
    });
  });

  group('country picker', () {
    testWidgets('searching narrows the list and a choice is persisted',
        (WidgetTester tester) async {
      final FakeNative native = FakeNative(networkIso: 'DE')..install();
      await pumpApp(tester);

      expect(find.text('Germany'), findsOneWidget);
      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, 'Choose country'), findsOneWidget);
      expect(find.text('Search country or code'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'japa');
      await tester.pumpAndSettle();
      expect(find.text('Japan'), findsOneWidget);
      expect(find.text('Germany'), findsNothing);
      expect(find.text('Argentina'), findsNothing);

      await tester.enterText(find.byType(TextField), 'zzzzz');
      await tester.pumpAndSettle();
      expect(find.text('No match'), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);

      await tester.enterText(find.byType(TextField), 'JP');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Japan'));
      await tester.pumpAndSettle();

      expect(native.lastArgs('prefSet')['value'], 'JP');
      expect(native.prefs.values, contains('JP'));
      expect(find.text('Japan'), findsOneWidget);
      expect(find.text('Chosen by you'), findsOneWidget);
      expect(find.text('From your mobile network'), findsNothing);
      expect(find.text('110'), findsWidgets);
    });

    testWidgets('a manual choice can be handed back to automatic detection',
        (WidgetTester tester) async {
      FakeNative(
        networkIso: 'DE',
        prefs: <String, String>{'manual_iso': 'JP'},
      ).install();
      await pumpApp(tester);

      expect(find.text('Chosen by you'), findsOneWidget);
      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Back to automatic detection'));
      await tester.pumpAndSettle();

      expect(find.text('Germany'), findsOneWidget);
      expect(find.text('From your mobile network'), findsOneWidget);
    });

    testWidgets('dismissing the picker changes nothing',
        (WidgetTester tester) async {
      final FakeNative native = FakeNative(networkIso: 'DE')..install();
      await pumpApp(tester);

      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      expect(find.text('Germany'), findsOneWidget);
      expect(find.text('From your mobile network'), findsOneWidget);
      expect(native.callsTo('prefSet').where((MethodCall c) =>
          (c.arguments as Map<Object?, Object?>)['key'] == 'manual_iso'),
          isEmpty);
    });
  });

  group('countries without a universal number', () {
    testWidgets('Japan shows a main number and every service',
        (WidgetTester tester) async {
      FakeNative(networkIso: 'JP').install();
      await pumpApp(tester);

      expect(find.text('Japan'), findsOneWidget);
      expect(find.text('MAIN EMERGENCY NUMBER'), findsOneWidget);
      expect(find.text('ALL EMERGENCY SERVICES'), findsNothing);
      expect(find.text('Police'), findsOneWidget);
      expect(find.text('Ambulance'), findsOneWidget);
      expect(find.text('Fire'), findsOneWidget);
      expect(find.text('110'), findsNWidgets(2), reason: 'button and police');
      expect(find.text('119'), findsNWidgets(2), reason: 'ambulance and fire');
      expect(find.text('Local notes'), findsOneWidget);
    });

    testWidgets('Germany shows the universal label',
        (WidgetTester tester) async {
      FakeNative(networkIso: 'DE').install();
      await pumpApp(tester);

      expect(find.text('ALL EMERGENCY SERVICES'), findsOneWidget);
      expect(find.text('MAIN EMERGENCY NUMBER'), findsNothing);
    });
  });

  group('detection details', () {
    testWidgets('the details card reports every signal',
        (WidgetTester tester) async {
      FakeNative(networkIso: 'DE', simIso: 'AR', localeIso: 'US', hasSim: true)
          .install();
      await pumpApp(tester);

      await tester.tap(find.text('How this was detected'));
      await tester.pumpAndSettle();

      expect(find.text('Mobile network'), findsOneWidget);
      expect(find.text('DE'), findsWidgets);
      expect(find.text('AR'), findsOneWidget);
      expect(find.text('US'), findsOneWidget);
      expect(find.text('permission not granted'), findsOneWidget);
      expect(find.text('DE · From your mobile network'), findsOneWidget);
    });

    testWidgets('the refresh button re-runs detection',
        (WidgetTester tester) async {
      final FakeNative native = FakeNative(networkIso: 'DE')..install();
      await pumpApp(tester);
      expect(find.text('Germany'), findsOneWidget);

      native.networkIso = 'FR';
      await tester.tap(find.byTooltip('Detect again'));
      await tester.pumpAndSettle();

      expect(find.text('France'), findsOneWidget);
      expect(find.text('Germany'), findsNothing);
    });

    testWidgets('the offline disclaimer is always shown',
        (WidgetTester tester) async {
      FakeNative(networkIso: 'DE').install();
      await pumpApp(tester);

      expect(find.text('Works fully offline. No internet permission.'),
          findsOneWidget);
      expect(find.textContaining('try 112 or 911'), findsOneWidget);
    });
  });

  group('location permission flow', () {
    testWidgets('permission is requested once and remembered',
        (WidgetTester tester) async {
      final FakeNative native = FakeNative(simIso: 'AR', hasSim: true)
        ..install();
      await pumpApp(tester);

      expect(native.callsTo('requestLocationPermission'), hasLength(1));
      expect(native.prefs['asked_location'], '1');

      // A second launch must not nag.
      native.calls.clear();
      await pumpApp(tester);
      expect(native.callsTo('requestLocationPermission'), isEmpty);
      expect(find.text('From your SIM card'), findsOneWidget);
    });

    testWidgets('a manual choice never spends a location fix',
        (WidgetTester tester) async {
      final FakeNative native = FakeNative(
        networkIso: 'DE',
        locationPermitted: true,
        fix: FakeNative.geoFix(paris.$1, paris.$2),
        prefs: <String, String>{'manual_iso': 'JP'},
      )..install();
      await pumpApp(tester);

      expect(find.text('Japan'), findsOneWidget);
      expect(find.text('Chosen by you'), findsOneWidget);
      expect(native.callsTo('location'), isEmpty);
    });

    testWidgets('the warning banner can ask for permission again',
        (WidgetTester tester) async {
      await warmBorders(tester, paris);
      final FakeNative native = FakeNative(simIso: 'AR', hasSim: true)
        ..install();
      await pumpApp(tester);

      expect(find.text('Verify this country'), findsOneWidget);
      native.grantPermissionWhenAsked = true;
      native.fix = FakeNative.geoFix(paris.$1, paris.$2);

      await tester.tap(find.text('Allow location'));
      await tester.pumpAndSettle();

      expect(find.text('France'), findsOneWidget);
      expect(find.text('From your location'), findsOneWidget);
      expect(find.text('Verify this country'), findsNothing);
    });
  });
}
