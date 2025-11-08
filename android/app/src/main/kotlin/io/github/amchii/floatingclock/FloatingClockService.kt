package io.github.amchii.floatingclock

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.TextView
import android.widget.LinearLayout
import android.text.TextUtils
import android.graphics.drawable.GradientDrawable
import android.graphics.Typeface
import androidx.core.app.NotificationCompat
import java.util.*

class FloatingClockService : Service() {
    private lateinit var windowManager: WindowManager
    private var overlayView: View? = null
    private var containerView: View? = null
    private var textView: TextView? = null
    // offset in milliseconds to apply to system time (ntpTime - systemTime)
    private var offsetMillis: Long = 0L
    private var label: String? = null
    private var displayPrecision = DisplayPrecision.CENTISECOND
    private var updateIntervalMs = 10L
    private val handler = Handler(Looper.getMainLooper())
    private val updateRunnable = object : Runnable {
        override fun run() {
            updateTime()
            handler.postDelayed(this, updateIntervalMs)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        createOverlay()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Update offset/label from Intent extras if provided. Calling startOverlay again
        // with different extras will update the displayed time source.
        intent?.let {
            offsetMillis = it.getLongExtra("offset", 0L)
            label = it.getStringExtra("label")
            applyPrecision(it.getStringExtra("precision"))
        } ?: applyPrecision(null)
        startForegroundWithNotification()
        // Avoid scheduling multiple update runnables when startOverlay is
        // invoked repeatedly to update the offset/label; remove previous
        // callbacks first.
        handler.removeCallbacks(updateRunnable)
        handler.post(updateRunnable)
        // Force an immediate update
        updateTime()
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(updateRunnable)
        removeOverlay()
        val intent = Intent("io.github.amchii.floatingclock.OVERLAY_STOPPED")
        intent.setPackage(packageName)
        sendBroadcast(intent)
        super.onDestroy()
    }

    private fun startForegroundWithNotification() {
        val channelId = "floating_clock_channel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(channelId, "悬浮时间", NotificationManager.IMPORTANCE_LOW)
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }

        val notificationIntent = Intent(this, MainActivity::class.java)
        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE else PendingIntent.FLAG_UPDATE_CURRENT
        val pendingIntent = PendingIntent.getActivity(this, 0, notificationIntent, pendingFlags)

        val notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle("悬浮时间")
            .setContentText("悬浮时间正在运行")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()

        startForeground(1, notification)
    }

    private fun createOverlay() {
        if (!Settings.canDrawOverlays(this)) return

        val layoutParams = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        )

        layoutParams.gravity = Gravity.START or Gravity.TOP
        layoutParams.x = 0
        layoutParams.y = 200

        // Horizontal layout: alias (small, left), time (center, monospace), close button (right)
        val container = LinearLayout(this)
        container.orientation = LinearLayout.HORIZONTAL

        val density = resources.displayMetrics.density
        val bg = GradientDrawable()
        bg.cornerRadius = 8 * density
        // slightly more transparent background so underlying content is readable
        bg.setColor(0x88000000.toInt())
        container.background = bg
        val pad = (8 * density).toInt()
        container.setPadding(pad, (6 * density).toInt(), pad, (6 * density).toInt())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) container.elevation = 6f

        // Alias TextView: small, single line, marquee for long aliases.
        val aliasTv = TextView(this)
        aliasTv.setTextColor(0xFFFFFFFF.toInt())
        aliasTv.textSize = 12f
        aliasTv.isSingleLine = true
        aliasTv.ellipsize = TextUtils.TruncateAt.MARQUEE
        aliasTv.isSelected = true
        aliasTv.setHorizontallyScrolling(true)

        // Restrict alias width so it doesn't push the time display; allow marquee inside.
        val aliasMaxWidth = (120 * density).toInt()
        aliasTv.maxWidth = aliasMaxWidth
        val aliasLp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        aliasLp.marginEnd = (8 * density).toInt()
        container.addView(aliasTv, aliasLp)

        val tv = TextView(this)
        tv.typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
        tv.setTextColor(0xFFFFFFFF.toInt())
        tv.setShadowLayer(3f, 0f, 1f, 0x80000000.toInt())
        tv.textSize = 20f
        tv.isSingleLine = true
        tv.ellipsize = TextUtils.TruncateAt.END
        tv.text = currentTimeString()

        val tvLp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        tvLp.weight = 1f
        tvLp.marginEnd = (6 * density).toInt()
        container.addView(tv, tvLp)

        val closeBtn = TextView(this)
        closeBtn.text = "✕"
        closeBtn.setTextColor(0xFFFFFFFF.toInt())
        closeBtn.textSize = 12f
        val closeSize = (28 * density).toInt()
        closeBtn.setPadding((6 * density).toInt(), (2 * density).toInt(), (6 * density).toInt(), (2 * density).toInt())
        closeBtn.minWidth = closeSize
        closeBtn.minHeight = closeSize
        val closeBg = GradientDrawable()
        closeBg.shape = GradientDrawable.OVAL
        closeBg.setColor(0x99FF4444.toInt())
        closeBtn.background = closeBg
        // Center the '✕' inside the circular background and remove extra font padding
        closeBtn.setGravity(Gravity.CENTER)
        closeBtn.setIncludeFontPadding(false)
        val closeLp = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        closeLp.gravity = Gravity.CENTER_VERTICAL
        container.addView(closeBtn, closeLp)

        closeBtn.setOnClickListener {
            stopSelf()
        }

        // Dragging handler on the whole container
        container.setOnTouchListener(object : View.OnTouchListener {
            private var initialX = 0
            private var initialY = 0
            private var initialTouchX = 0f
            private var initialTouchY = 0f

            override fun onTouch(v: View?, event: MotionEvent?): Boolean {
                when (event?.action) {
                    MotionEvent.ACTION_DOWN -> {
                        initialX = layoutParams.x
                        initialY = layoutParams.y
                        initialTouchX = event.rawX
                        initialTouchY = event.rawY
                        return true
                    }
                    MotionEvent.ACTION_MOVE -> {
                        val dx = (event.rawX - initialTouchX).toInt()
                        val dy = (event.rawY - initialTouchY).toInt()
                        layoutParams.x = initialX + dx
                        layoutParams.y = initialY + dy
                        try {
                            windowManager.updateViewLayout(container, layoutParams)
                        } catch (e: Exception) {
                        }
                        return true
                    }
                }
                return false
            }
        })

        // Keep references to alias and time views so updateTime() can set text.
        textView = tv
        containerView = container
        overlayView = container
        // store alias view in tag so updateTime can access it without new field
        container.tag = aliasTv
        try {
            windowManager.addView(container, layoutParams)
        } catch (e: Exception) {
        }
    }

    private fun removeOverlay() {
        try {
            overlayView?.let { windowManager.removeView(it) }
        } catch (e: Exception) {
        }
        overlayView = null
        textView = null
        containerView = null
    }

    private fun updateTime() {
        textView?.post {
            textView?.text = currentTimeString()
            val aliasTv = containerView?.tag as? TextView
            aliasTv?.text = label ?: ""
            // ensure marquee is (re-)enabled
            aliasTv?.isSelected = true
        }
    }

    private fun currentTimeString(): String {
        val nowMs = System.currentTimeMillis() + offsetMillis
        val cal = Calendar.getInstance()
        cal.timeInMillis = nowMs
        val h = cal.get(Calendar.HOUR_OF_DAY)
        val m = cal.get(Calendar.MINUTE)
        val s = cal.get(Calendar.SECOND)
        val base = String.format(Locale.getDefault(), "%02d:%02d:%02d", h, m, s)
        val fraction = if (displayPrecision == DisplayPrecision.CENTISECOND) {
            String.format(Locale.getDefault(), "%02d", cal.get(Calendar.MILLISECOND) / 10)
        } else {
            (cal.get(Calendar.MILLISECOND) / 100).toString()
        }
        // Overlay should show only the time (no alias), keep it compact.
        return "$base.$fraction"
    }

    private fun applyPrecision(raw: String?) {
        val newPrecision = when (raw) {
            "decisecond" -> DisplayPrecision.DECISECOND
            else -> DisplayPrecision.CENTISECOND
        }
        displayPrecision = newPrecision
        updateIntervalMs = if (newPrecision == DisplayPrecision.CENTISECOND) 10L else 100L
    }
}

private enum class DisplayPrecision {
    CENTISECOND,
    DECISECOND
}
