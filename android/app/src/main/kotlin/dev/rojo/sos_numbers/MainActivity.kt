package dev.rojo.sos_numbers

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.telephony.TelephonyManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Every native capability the app needs, on one channel. No Flutter plugins are
 * used: the app must work with no network, no Play Services and no third-party
 * code in the emergency path.
 *
 * Invariants worth keeping:
 *  - every MethodChannel.Result is answered exactly once, on every path,
 *    including activity teardown;
 *  - a location fix older than the caller's maxAge is never returned, not even
 *    as a fallback - a stale fix from the previous country outranking the mobile
 *    network is the single most dangerous failure this app can have;
 *  - one field of telephony data failing never costs the others.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "dev.rojo.sos_numbers/native"
        const val PREFS = "sos_numbers"
        const val PREF_LOCATION_ASKED = "native_location_asked"
        const val LOCATION_REQUEST_CODE = 4711
        const val MIN_TIMEOUT_MS = 1_000L
        const val MAX_TIMEOUT_MS = 60_000L
    }

    private var pendingPermissionResult: MethodChannel.Result? = null

    /** Cancels any in-flight location request and replies to its Result. */
    private var cancelLocationRequest: (() -> Unit)? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> dispatch(call, result) }
    }

    override fun onDestroy() {
        // Any Result still pending must be answered, or the Dart future hangs and
        // the UI spinner never stops. Listeners must go, or they keep the engine
        // reachable and the GPS radio sampling.
        cancelLocationRequest?.invoke()
        cancelLocationRequest = null
        pendingPermissionResult?.let {
            pendingPermissionResult = null
            runCatching { it.success(false) }
        }
        super.onDestroy()
    }

    private fun dispatch(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "telephonyHints" -> result.success(telephonyHints())
            "hasLocationPermission" -> result.success(hasLocationPermission())
            "isLocationPermanentlyDenied" -> result.success(isLocationPermanentlyDenied())
            "requestLocationPermission" -> requestLocationPermission(result)
            "openAppSettings" -> result.success(openAppSettings())
            "location" -> resolveLocation(
                timeoutMs = (call.argument<Number>("timeoutMs")?.toLong() ?: 12_000L),
                maxAgeMs = (call.argument<Number>("maxAgeMs")?.toLong() ?: 1_800_000L),
                result = result
            )
            "openDialer" -> result.success(openDialer(call.argument<String>("number")))
            "prefGet" -> {
                val key = call.argument<String>("key")
                if (key == null) result.error("bad_args", "key is required", null)
                else result.success(prefs().getString(key, null))
            }
            "prefSet" -> {
                val key = call.argument<String>("key")
                val value = call.argument<String>("value")
                if (key == null) {
                    result.error("bad_args", "key is required", null)
                } else {
                    val ok = prefs().edit()
                        .apply { if (value == null) remove(key) else putString(key, value) }
                        .commit() // synchronous so Dart learns about a failed write
                    if (ok) result.success(null) else result.error("write_failed", "prefs commit failed", null)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun prefs() = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // ---------------------------------------------------------------- telephony

    /**
     * Country hints that cost nothing: no permission, no network, no radio work.
     * networkCountryIso is the country of the network the phone is registered to,
     * which is the single best offline answer to "which country am I in".
     *
     * Each field is guarded separately. TelephonyManager is documented to throw
     * on some subscription states and does so on assorted OEM ROMs and on devices
     * with no telephony hardware at all; the locale must survive that, because on
     * a Wi-Fi tablet it is the only signal there is.
     */
    private fun telephonyHints(): Map<String, Any?> {
        val locale = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                resources.configuration.locales[0]?.country
            } else {
                @Suppress("DEPRECATION")
                resources.configuration.locale?.country
            }
        }.getOrNull()

        val tm = runCatching {
            getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager?
        }.getOrNull()

        val network = runCatching { tm?.networkCountryIso }.getOrNull()
        val sim = runCatching { tm?.simCountryIso }.getOrNull()
        val simReady = runCatching { tm?.simState == TelephonyManager.SIM_STATE_READY }
            .getOrDefault(false)

        return mapOf(
            "networkIso" to network?.takeIf { it.isNotBlank() }?.uppercase(),
            "simIso" to sim?.takeIf { it.isNotBlank() }?.uppercase(),
            "localeIso" to locale?.takeIf { it.isNotBlank() }?.uppercase(),
            "hasSim" to simReady
        )
    }

    // --------------------------------------------------------------- permission

    private fun hasLocationPermission(): Boolean {
        val fine = ContextCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_COARSE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED
        return fine || coarse
    }

    /**
     * Android gives no direct "denied forever" signal. shouldShowRequestPermissionRationale
     * is false both before the first ask and after a permanent denial, so we
     * combine it with our own record of having asked at least once.
     */
    private fun isLocationPermanentlyDenied(): Boolean {
        if (hasLocationPermission()) return false
        val asked = prefs().getBoolean(PREF_LOCATION_ASKED, false)
        if (!asked) return false
        val rationaleFine = ActivityCompat.shouldShowRequestPermissionRationale(
            this, Manifest.permission.ACCESS_FINE_LOCATION
        )
        val rationaleCoarse = ActivityCompat.shouldShowRequestPermissionRationale(
            this, Manifest.permission.ACCESS_COARSE_LOCATION
        )
        return !rationaleFine && !rationaleCoarse
    }

    private fun requestLocationPermission(result: MethodChannel.Result) {
        if (hasLocationPermission()) {
            result.success(true)
            return
        }
        if (pendingPermissionResult != null) {
            result.success(false) // one dialog at a time
            return
        }
        pendingPermissionResult = result
        prefs().edit().putBoolean(PREF_LOCATION_ASKED, true).apply()
        runCatching {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION
                ),
                LOCATION_REQUEST_CODE
            )
        }.onFailure {
            // Activity finishing, or a ROM that refuses a second dialog: reply now
            // rather than leaving the Dart side waiting forever.
            pendingPermissionResult = null
            result.success(false)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != LOCATION_REQUEST_CODE) return
        val pending = pendingPermissionResult ?: return
        pendingPermissionResult = null
        pending.success(grantResults.any { it == PackageManager.PERMISSION_GRANTED })
    }

    private fun openAppSettings(): Boolean {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", packageName, null)
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    // ----------------------------------------------------------------- location

    /**
     * Cheapest acceptable fix: a recent cached position if there is one, else a
     * single live update from whichever provider answers first, with a hard timeout.
     *
     * maxAgeMs is enforced on EVERY path, including the fallbacks. Returning a
     * three-day-old fix from the last country as if it were current would make the
     * app show the wrong emergency numbers with a green "trustworthy" tick, and
     * outrank the mobile network that had the right answer.
     */
    private fun resolveLocation(timeoutMs: Long, maxAgeMs: Long, result: MethodChannel.Result) {
        if (!hasLocationPermission()) {
            result.success(null)
            return
        }
        val lm = runCatching {
            getSystemService(Context.LOCATION_SERVICE) as LocationManager?
        }.getOrNull()
        if (lm == null) {
            result.success(null)
            return
        }
        if (cancelLocationRequest != null) {
            result.success(null) // one request at a time; caller retries
            return
        }

        val now = System.currentTimeMillis()
        fun Location.isFresh() = now - time in 0..maxAgeMs

        val known = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) add(LocationManager.FUSED_PROVIDER)
            add(LocationManager.GPS_PROVIDER)
            add(LocationManager.NETWORK_PROVIDER)
            add(LocationManager.PASSIVE_PROVIDER)
        }.filter { p -> runCatching { lm.allProviders.contains(p) }.getOrDefault(false) }

        // 1. Cached fix, freshest first. Read from EVERY provider, not just the
        //    enabled ones: a fix cached before the user toggled GPS off is still
        //    a real fix, and the freshness check below is what decides.
        val cached = known
            .mapNotNull { p -> runCatching { lm.getLastKnownLocation(p) }.getOrNull() }
            .filter { it.isFresh() }
            .maxByOrNull { it.time }
        if (cached != null) {
            result.success(cached.toMap())
            return
        }

        // 2. Live single update with timeout, from every enabled provider at once,
        //    first answer wins. A country only needs kilometre accuracy, so the
        //    network provider indoors is as good as GPS and much faster.
        val live = known
            .filter { it != LocationManager.PASSIVE_PROVIDER }
            .filter { p -> runCatching { lm.isProviderEnabled(p) }.getOrDefault(false) }
        if (live.isEmpty()) {
            result.success(null)
            return
        }

        val handler = Handler(Looper.getMainLooper())
        val listeners = mutableListOf<LocationListener>()
        var settled = false

        fun finish(location: Location?) {
            if (settled) return
            settled = true
            cancelLocationRequest = null
            handler.removeCallbacksAndMessages(null)
            listeners.forEach { l -> runCatching { lm.removeUpdates(l) } }
            listeners.clear()
            // A live update is fresh by definition; still guard against a
            // provider replaying an old sample.
            result.success(location?.takeIf { it.isFresh() }?.toMap())
        }
        cancelLocationRequest = { finish(null) }

        live.forEach { provider ->
            val listener = object : LocationListener {
                override fun onLocationChanged(location: Location) = finish(location)

                @Deprecated("Required on API < 29")
                override fun onStatusChanged(p: String?, s: Int, e: Bundle?) = Unit

                override fun onProviderEnabled(p: String) = Unit
                override fun onProviderDisabled(p: String) = Unit
            }
            listeners += listener
            runCatching {
                lm.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
            }.onFailure { listeners.remove(listener) }
        }

        if (listeners.isEmpty()) {
            finish(null)
            return
        }
        handler.postDelayed({ finish(null) }, timeoutMs.coerceIn(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS))
    }

    private fun Location.toMap(): Map<String, Any?> = mapOf(
        "lat" to latitude,
        "lon" to longitude,
        "accuracy" to if (hasAccuracy()) accuracy.toDouble() else null,
        "provider" to (provider ?: "unknown"),
        "ageMs" to (System.currentTimeMillis() - time).coerceAtLeast(0L)
    )

    // ------------------------------------------------------------------- dialer

    /**
     * ACTION_DIAL, not ACTION_CALL: Android refuses to place emergency calls via
     * ACTION_CALL anyway, and the user should always be the one to press call.
     * Uri.fromParts keeps '*' and '#' intact where Uri.parse would treat '#' as
     * a fragment delimiter.
     */
    private fun openDialer(number: String?): Boolean {
        val cleaned = number?.filter { it.isDigit() || it == '+' || it == '*' || it == '#' }
        if (cleaned.isNullOrEmpty()) return false
        val intent = Intent(Intent.ACTION_DIAL, Uri.fromParts("tel", cleaned, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }
}
