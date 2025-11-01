package io.github.amchii.floatingclock

import android.app.ActivityManager
import android.app.PictureInPictureParams
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Rational
import java.io.ByteArrayOutputStream
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "floating_clock"
    private lateinit var channel: MethodChannel
    private val overlayStoppedAction = "io.github.amchii.floatingclock.OVERLAY_STOPPED"
    private val overlayStoppedReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (::channel.isInitialized) {
                channel.invokeMethod("onOverlayStopped", null)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val filter = IntentFilter(overlayStoppedAction)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(overlayStoppedReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(overlayStoppedReceiver, filter)
        }
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(overlayStoppedReceiver)
        } catch (_: IllegalArgumentException) {
        }
        super.onDestroy()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> {
                    result.success(Settings.canDrawOverlays(this))
                }
                "requestPermission" -> {
                    // Try to open the app-specific overlay permission page. Some OEM settings
                    // implementations are fragile, so fall back to the app details page when needed.
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        try {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.fromParts("package", packageName, null)
                            )
                            startActivity(intent)
                        } catch (e: Exception) {
                            // Fallback: open application details settings so the user can
                            // navigate to special app access -> Display over other apps.
                            val intent = Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.fromParts("package", packageName, null)
                            )
                            startActivity(intent)
                        }
                    }
                    result.success(true)
                }
                "getAppVersion" -> {
                    try {
                        val pInfo = packageManager.getPackageInfo(packageName, 0)
                        result.success(pInfo.versionName)
                    } catch (e: Exception) {
                        result.success(null)
                    }
                }
                "getAppIcon" -> {
                    try {
                        val pm = packageManager
                        val appInfo = pm.getApplicationInfo(packageName, 0)
                        val drawable = pm.getApplicationIcon(appInfo)

                        val bitmap: Bitmap = if (drawable is BitmapDrawable) {
                            drawable.bitmap
                        } else {
                            val width = if (drawable.intrinsicWidth > 0) drawable.intrinsicWidth else 128
                            val height = if (drawable.intrinsicHeight > 0) drawable.intrinsicHeight else 128
                            val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                            val canvas = Canvas(bmp)
                            drawable.setBounds(0, 0, canvas.width, canvas.height)
                            drawable.draw(canvas)
                            bmp
                        }

                        val stream = ByteArrayOutputStream()
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                        val bytes = stream.toByteArray()
                        result.success(bytes)
                    } catch (e: Exception) {
                        result.error("UNAVAILABLE", "Icon not available", null)
                    }
                }
                "startOverlay" -> {
                    if (!Settings.canDrawOverlays(this)) {
                        result.error("NO_PERMISSION", "Overlay permission not granted", null)
                        return@setMethodCallHandler
                    }
                    // Accept an optional offset (milliseconds) and label from Flutter.
                    val offsetNum = call.argument<Number>("offset")
                    val offset = offsetNum?.toLong() ?: 0L
                    val label = call.argument<String>("label")

                    val intent = Intent(this, FloatingClockService::class.java)
                    intent.putExtra("offset", offset)
                    if (label != null) intent.putExtra("label", label)

                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }
                "stopOverlay" -> {
                    val intent = Intent(this, FloatingClockService::class.java)
                    stopService(intent)
                    result.success(true)
                }
                "isOverlayRunning" -> {
                    val manager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                    @Suppress("DEPRECATION")
                    val running = manager.getRunningServices(Int.MAX_VALUE)
                        .any { it.service.className == FloatingClockService::class.java.name }
                    result.success(running)
                }
                "isPiPSupported" -> {
                    val supported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                        packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
                    result.success(supported)
                }
                "enterPiP" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val params = PictureInPictureParams.Builder()
                            .setAspectRatio(Rational(16, 9))
                            .build()
                        val success = try {
                            enterPictureInPictureMode(params)
                        } catch (e: Exception) {
                            result.error("PIP_FAILED", e.message, null)
                            return@setMethodCallHandler
                        }
                        result.success(success)
                    } else {
                        result.error("UNSUPPORTED", "Picture-in-picture not supported", null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun notifyPiPChanged(inPiP: Boolean) {
        if (::channel.isInitialized) {
            channel.invokeMethod("onPiPChanged", mapOf("isInPiP" to inPiP))
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode)
        notifyPiPChanged(isInPictureInPictureMode)
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration?
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        notifyPiPChanged(isInPictureInPictureMode)
    }
}
