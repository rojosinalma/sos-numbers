import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory stand-in for the single platform channel the app depends on
/// (`dev.rojo.sos_numbers/native`, implemented in MainActivity.kt).
///
/// Every call is recorded so tests can assert on the real [MethodCall]
/// arguments, and `prefGet`/`prefSet` are backed by a map so the manual
/// country selection path behaves exactly as it does on a device.
class FakeNative {
  FakeNative({
    this.networkIso,
    this.simIso,
    this.localeIso,
    this.hasSim = false,
    this.locationPermitted = false,
    this.grantPermissionWhenAsked = false,
    this.fix,
    this.dialerAvailable = true,
    Map<String, String>? prefs,
  }) : prefs = <String, String>{...?prefs};

  static const MethodChannel channel =
      MethodChannel('dev.rojo.sos_numbers/native');

  /// A `location` return value in the shape MainActivity.kt sends.
  static Map<String, Object?> geoFix(
    double lat,
    double lon, {
    double? accuracy = 25,
    String provider = 'gps',
    int ageMs = 1200,
  }) =>
      <String, Object?>{
        'lat': lat,
        'lon': lon,
        'accuracy': accuracy,
        'provider': provider,
        'ageMs': ageMs,
      };

  String? networkIso;
  String? simIso;
  String? localeIso;
  bool hasSim;
  bool locationPermitted;
  bool grantPermissionWhenAsked;

  /// Simulates "Don't ask again": the system dialog will never show.
  bool permanentlyDenied = false;
  int settingsOpened = 0;

  /// What `location` returns; null means "no fix available".
  Map<String, Object?>? fix;
  bool dialerAvailable;

  final Map<String, String> prefs;
  final List<MethodCall> calls = <MethodCall>[];

  List<MethodCall> callsTo(String method) => calls
      .where((MethodCall c) => c.method == method)
      .toList(growable: false);

  MethodCall? lastCallTo(String method) {
    final List<MethodCall> matches = callsTo(method);
    return matches.isEmpty ? null : matches.last;
  }

  /// Arguments of the last call to [method], as the codec delivers them.
  Map<Object?, Object?> lastArgs(String method) {
    final MethodCall? call = lastCallTo(method);
    expect(call, isNotNull, reason: 'no $method call was made');
    return call!.arguments as Map<Object?, Object?>;
  }

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, _handle);
    addTearDown(uninstall);
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'telephonyHints':
        return <String, Object?>{
          'networkIso': networkIso,
          'simIso': simIso,
          'localeIso': localeIso,
          'hasSim': hasSim,
        };
      case 'hasLocationPermission':
        return locationPermitted;
      case 'isLocationPermanentlyDenied':
        return !locationPermitted && permanentlyDenied;
      case 'requestLocationPermission':
        if (grantPermissionWhenAsked) locationPermitted = true;
        return locationPermitted;
      case 'openAppSettings':
        settingsOpened++;
        return true;
      case 'location':
        return fix;
      case 'openDialer':
        return dialerAvailable;
      case 'prefGet':
        return prefs[_arg(call, 'key') as String];
      case 'prefSet':
        final String key = _arg(call, 'key') as String;
        final String? value = _arg(call, 'value') as String?;
        if (value == null) {
          prefs.remove(key);
        } else {
          prefs[key] = value;
        }
        return null;
      default:
        return null;
    }
  }

  static Object? _arg(MethodCall call, String name) =>
      (call.arguments as Map<Object?, Object?>)[name];
}

/// Backs `Clipboard.setData` / `Clipboard.getData` with a variable, since the
/// real ones go out over `flutter/platform` and are no-ops under test.
class FakeClipboard {
  String? text;
  final List<String?> writes = <String?>[];

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          text = (call.arguments as Map<Object?, Object?>)['text'] as String?;
          writes.add(text);
          return null;
        case 'Clipboard.getData':
          final String? current = text;
          return current == null ? null : <String, Object?>{'text': current};
        default:
          return null;
      }
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
  }
}
