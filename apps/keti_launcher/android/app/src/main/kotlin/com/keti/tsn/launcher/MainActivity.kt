package com.keti.tsn.launcher

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.location.LocationManager
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * The host side of the launcher.
 *
 * Two jobs Flutter cannot do on its own: enumerate and start the other apps on the tablet (this
 * is a HOME replacement, so if it cannot open Settings and a browser the tablet is bricked for
 * anyone holding it), and ask for the runtime permissions BLE scanning needs.
 *
 * Permissions are handled here rather than by adding permission_handler. The rig tablet is a
 * TB-8504F on Android 7.1, where the only thing BLE scanning needs is ACCESS_FINE_LOCATION plus
 * location services actually switched on -- a dozen lines, against a plugin that would have to be
 * kept building for API 25.
 */
class MainActivity : FlutterActivity() {
    private val channel = "keti/launcher"
    private val permissionRequest = 4711

    /** Icons are expensive on this hardware; the same package is asked for on every drawer open. */
    private val iconCache = HashMap<String, ByteArray>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel).setMethodCallHandler { call, result ->
            when (call.method) {
                "listApps" -> result.success(listApps())
                "launch" -> {
                    val pkg = call.argument<String>("package")
                    result.success(pkg != null && launch(pkg))
                }
                "openSettings" -> {
                    startActivity(Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(true)
                }
                "openHomeSettings" -> {
                    // The picker that makes this app the default HOME. On 7.1 there is no
                    // ACTION_HOME_SETTINGS, so fall back to the app list.
                    val intent = if (Build.VERSION.SDK_INT >= 24) {
                        Intent(Settings.ACTION_HOME_SETTINGS)
                    } else {
                        Intent(Settings.ACTION_MANAGE_APPLICATIONS_SETTINGS)
                    }
                    startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(true)
                }
                "openLocationSettings" -> {
                    startActivity(
                        Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(true)
                }
                "isDefaultHome" -> result.success(isDefaultHome())
                "locationEnabled" -> result.success(locationEnabled())
                "requestBlePermissions" -> {
                    requestBlePermissions()
                    result.success(missingBlePermissions().isEmpty())
                }
                "blePermissionsGranted" -> result.success(missingBlePermissions().isEmpty())
                else -> result.notImplemented()
            }
        }
    }

    // -----------------------------------------------------------------------
    // apps
    // -----------------------------------------------------------------------

    /**
     * Every activity that answers MAIN/LAUNCHER, minus ourselves -- a launcher listing itself is
     * a loop the user can only escape by pressing home again.
     */
    private fun listApps(): List<Map<String, Any>> {
        val pm = packageManager
        val intent = Intent(Intent.ACTION_MAIN, null).addCategory(Intent.CATEGORY_LAUNCHER)
        val found: List<ResolveInfo> = pm.queryIntentActivities(intent, 0)
        val out = ArrayList<Map<String, Any>>(found.size)
        for (info in found) {
            val pkg = info.activityInfo.packageName ?: continue
            if (pkg == packageName) continue
            val label = info.loadLabel(pm)?.toString() ?: pkg
            out.add(mapOf("package" to pkg, "label" to label, "icon" to iconFor(pkg, info)))
        }
        out.sortWith(compareBy { (it["label"] as String).lowercase() })
        return out
    }

    private fun iconFor(pkg: String, info: ResolveInfo): ByteArray {
        iconCache[pkg]?.let { return it }
        val png = try {
            drawableToPng(info.loadIcon(packageManager))
        } catch (e: Exception) {
            ByteArray(0)
        }
        iconCache[pkg] = png
        return png
    }

    /**
     * 96 px is the drawer's draw size at this panel's 213 dpi. Adaptive icons on newer devices
     * are not BitmapDrawables, so everything goes through a Canvas rather than a cast.
     */
    private fun drawableToPng(drawable: Drawable): ByteArray {
        val size = 96
        val bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
            Bitmap.createScaledBitmap(drawable.bitmap, size, size, true)
        } else {
            val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)
            drawable.setBounds(0, 0, size, size)
            drawable.draw(canvas)
            bmp
        }
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
        return stream.toByteArray()
    }

    private fun launch(pkg: String): Boolean {
        val intent = packageManager.getLaunchIntentForPackage(pkg) ?: return false
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    // -----------------------------------------------------------------------
    // launcher / permission state
    // -----------------------------------------------------------------------

    private fun isDefaultHome(): Boolean {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
        val res = packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)
        return res?.activityInfo?.packageName == packageName
    }

    /**
     * On API 23..30 a BLE scan silently returns nothing when location services are off, with no
     * error anywhere. This tablet is API 25, so the state is worth showing rather than debugging.
     */
    private fun locationEnabled(): Boolean {
        if (Build.VERSION.SDK_INT < 23) return true
        val lm = getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return true
        return try {
            lm.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        } catch (e: Exception) {
            true
        }
    }

    private fun missingBlePermissions(): List<String> {
        val wanted = if (Build.VERSION.SDK_INT >= 31) {
            listOf(
                android.Manifest.permission.BLUETOOTH_SCAN,
                android.Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            listOf(android.Manifest.permission.ACCESS_FINE_LOCATION)
        }
        return wanted.filter {
            checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestBlePermissions() {
        if (Build.VERSION.SDK_INT < 23) return
        val missing = missingBlePermissions()
        if (missing.isEmpty()) return
        ActivityCompat.requestPermissions(this as Activity, missing.toTypedArray(), permissionRequest)
    }
}
