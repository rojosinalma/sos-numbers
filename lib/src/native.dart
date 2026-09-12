import 'dart:async';

import 'package:flutter/services.dart';

/// Everything the Dart side needs from Android, over one channel.
/// Implemented in android/app/src/main/kotlin/dev/rojo/sos_numbers/MainActivity.kt
class Native {
  static const MethodChannel _channel =
      MethodChannel('dev.rojo.sos_numbers/native');

  /// Backstop so a lost native reply can never hang the UI forever.
  static const Duration _permissionTimeout = Duration(minutes: 2);

  /// Country hints that need no permission and no network.
  static Future<TelephonyHints> telephonyHints() async {
    final Map<Object?, Object?>? r =
        await _call<Map<Object?, Object?>>('telephonyHints');
    if (r == null) return const TelephonyHints();
    return TelephonyHints(
      networkIso: _iso(r['networkIso']),
      simIso: _iso(r['simIso']),
      localeIso: _iso(r['localeIso']),
      hasSim: r['hasSim'] == true,
    );
  }

  static Future<bool> hasLocationPermission() async =>
      await _call<bool>('hasLocationPermission') ?? false;

  /// Shows the system permission dialog. Returns true if granted.
  static Future<bool> requestLocationPermission() async =>
      await _call<bool>(
        'requestLocationPermission',
        timeout: _permissionTimeout,
      ) ??
      false;

  /// True when the user has denied location permanently, so the system dialog
  /// will never appear again and the only way forward is app settings.
  static Future<bool> isLocationPermanentlyDenied() async =>
      await _call<bool>('isLocationPermanentlyDenied') ?? false;

  static Future<bool> openAppSettings() async =>
      await _call<bool>('openAppSettings') ?? false;

  /// A position from GPS/network providers. Never touches the internet.
  /// Returns null when unavailable (no permission, no provider, timeout) and
  /// also when the only fix on offer is older than [maxAge]: a stale fix from
  /// the last country is worse than no fix at all.
  static Future<GeoFix?> location({
    Duration timeout = const Duration(seconds: 12),
    Duration maxAge = const Duration(minutes: 30),
  }) async {
    final Map<Object?, Object?>? r = await _call<Map<Object?, Object?>>(
      'location',
      args: <String, Object>{
        'timeoutMs': timeout.inMilliseconds,
        'maxAgeMs': maxAge.inMilliseconds,
      },
      timeout: timeout + const Duration(seconds: 5),
    );
    if (r == null) return null;
    final double? lat = (r['lat'] as num?)?.toDouble();
    final double? lon = (r['lon'] as num?)?.toDouble();
    if (lat == null || lon == null) return null;

    final int ageMs = (r['ageMs'] as num?)?.toInt() ?? 0;
    if (ageMs > maxAge.inMilliseconds) return null;

    return GeoFix(
      latitude: lat,
      longitude: lon,
      accuracyMetres: (r['accuracy'] as num?)?.toDouble(),
      provider: r['provider'] as String? ?? 'unknown',
      ageMs: ageMs,
    );
  }

  /// Opens the system dialer with the number pre-filled. Deliberately does not
  /// place the call itself: ACTION_CALL is barred from emergency numbers by
  /// Android anyway, and one accidental tap should never ring the police.
  static Future<bool> openDialer(String number) async =>
      await _call<bool>('openDialer', args: <String, Object>{'number': number}) ??
      false;

  static Future<String?> prefGet(String key) =>
      _call<String>('prefGet', args: <String, Object>{'key': key});

  /// Returns true when the write reached native storage.
  static Future<bool> prefSet(String key, String? value) async {
    try {
      await _channel.invokeMethod<void>('prefSet', <String, Object?>{
        'key': key,
        'value': value,
      });
      return true;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Every channel call funnels through here so a missing native side, a
  /// PlatformException or a lost reply all degrade to "no data" rather than an
  /// uncaught error on the one screen that matters.
  static Future<T?> _call<T>(
    String method, {
    Map<String, Object?>? args,
    Duration? timeout,
  }) async {
    try {
      Future<T?> f = _channel.invokeMethod<T>(method, args);
      if (timeout != null) {
        f = f.timeout(timeout, onTimeout: () => null);
      }
      return await f;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static String? _iso(Object? v) {
    if (v is! String) return null;
    final String s = v.trim().toUpperCase();
    if (s.length != 2) return null;
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(s)) return null;
    return s;
  }
}

class TelephonyHints {
  const TelephonyHints({
    this.networkIso,
    this.simIso,
    this.localeIso,
    this.hasSim = false,
  });

  /// Country of the mobile network the phone is currently registered to.
  /// This is the best offline signal for "where am I", including while roaming.
  final String? networkIso;

  /// Country that issued the SIM. This is "where I am from", not "where I am".
  final String? simIso;

  /// Region from the device locale. Weakest signal, but always present.
  final String? localeIso;

  final bool hasSim;
}

class GeoFix {
  const GeoFix({
    required this.latitude,
    required this.longitude,
    required this.accuracyMetres,
    required this.provider,
    required this.ageMs,
  });

  final double latitude;
  final double longitude;
  final double? accuracyMetres;
  final String provider;
  final int ageMs;
}
