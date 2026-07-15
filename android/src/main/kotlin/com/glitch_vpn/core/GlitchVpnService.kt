package com.glitch_vpn.core

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.Handler
import android.os.Looper
import android.content.pm.ServiceInfo
import android.util.Log
import androidx.core.app.NotificationCompat
import java.util.Locale
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor

class GlitchVpnService : VpnService() {

    companion object {
        const val ACTION_DISCONNECT = "com.glitch_vpn.core.ACTION_DISCONNECT"
        const val ACTION_FINALIZE   = "com.glitch_vpn.core.ACTION_FINALIZE"
        const val ACTION_UPDATE     = "com.glitch_vpn.core.ACTION_UPDATE"

        const val EXTRA_ADDRESSES = "addresses"
        const val EXTRA_ROUTES    = "routes"
        const val EXTRA_MTU       = "mtu"
        const val EXTRA_SESSION   = "sessionName"
        const val EXTRA_NOTIF_TITLE    = "notifTitle"
        const val EXTRA_NOTIF_SUBTITLE = "notifSubtitle"
        const val EXTRA_NOTIF_SHOW_DISCONNECT = "notifShowDisconnect"
        const val EXTRA_COUNTRY_LINE = "countryLine"
        const val EXTRA_STATS_LINE = "statsLine"
        const val EXTRA_DISCONNECT_TEXT = "disconnectActionText"
        const val EXTRA_DNS       = "dnsAddress"
        const val EXTRA_SPLIT_TYPE = "splitType"
        const val EXTRA_SPLIT_APPS = "splitApps"

        const val EXTRA_RESULT_RECEIVER = "com.glitch_vpn.core.EXTRA_RESULT_RECEIVER"
        const val EXTRA_FD    = "com.glitch_vpn.core.EXTRA_FD"
        const val EXTRA_ERROR = "com.glitch_vpn.core.EXTRA_ERROR"
        const val RESULT_TUN_READY = 1
        const val RESULT_TUN_ERROR = -1

        private const val NOTIF_CHANNEL_ID = "glitch_vpn_core"
        private const val NOTIF_ID = 1
        private const val TAG = "GlitchVpnService"

        @Volatile var tunFd: Int = -1
        @Volatile private var ownerPfd: ParcelFileDescriptor? = null
        @Volatile private var finalized: Boolean = false
        @Volatile private var headlessEngine: FlutterEngine? = null
        @Volatile private var wakeLock: android.os.PowerManager.WakeLock? = null

        // Resolves the JNI symbol; Dart's dlopen maps the same in-process copy,
        // so this reads the live engine's counters (one Go runtime).
        init {
            try {
                System.loadLibrary("glitchcore")
            } catch (t: Throwable) {
                Log.w(TAG, "loadLibrary glitchcore failed: ${t.message}")
            }
        }
    }

    // "rx,tx" from the Go core, or "" - keeps the notification's counters
    // moving after the Dart isolate is gone.
    private external fun nativeEngineTraffic(): String

    // Keepalive: periodic notification updates signal the OS the service is active,
    // discouraging aggressive OEM battery management from freezing the process.
    private var keepAliveHandler: Handler? = null
    private var keepAliveRunnable: Runnable? = null
    private var connectedSinceMs: Long = 0L

    private var lastTitle: String = "Glitch VPN"
    private var lastCountryLine: String = ""
    private var lastStatsLine: String = ""
    private var lastDisconnectText: String = "Disconnect"
    @Volatile private var disconnecting: Boolean = false

    override fun onBind(intent: Intent?): IBinder? = super.onBind(intent)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        Log.i(TAG, "onStartCommand action=$action")

        if (action == null || action == ACTION_UPDATE) { // ACTION_UPDATE also keeps the lock held
             synchronized(this) {
                 if (wakeLock == null) {
                     val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
                     wakeLock = pm.newWakeLock(android.os.PowerManager.PARTIAL_WAKE_LOCK, "GlitchVpn::CoreWakeLock")
                     wakeLock?.setReferenceCounted(false)
                 }
                 if (wakeLock?.isHeld == false) {
                     wakeLock?.acquire(24 * 60 * 60 * 1000L) // 24 hours
                     Log.i(TAG, "WakeLock acquired")
                 }
             }
        }

        return when (action) {
            ACTION_DISCONNECT -> handleActionDisconnect(intent)
            ACTION_FINALIZE   -> handleActionFinalize()
            ACTION_UPDATE     -> handleActionUpdate(intent)
            else              -> handleActionStart(intent)
        }
    }

    private fun startAsForeground(title: String?, subtitle: String?): Int {
        val n = buildNotification(title, subtitle ?: lastCountryLine.ifBlank { null })
        return when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> {
                // Android 14+: SPECIAL_USE is required for VPN services
                startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            }
            else -> {
                // Android 10-13 and below: don't specify foregroundServiceType
                // (SPECIAL_USE constant doesn't exist pre-API 34, and manifest only declares specialUse)
                startForeground(NOTIF_ID, n)
                0
            }
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(NOTIF_CHANNEL_ID) == null) {
            val ch = NotificationChannel(
                NOTIF_CHANNEL_ID,
                "Glitch VPN",
                NotificationManager.IMPORTANCE_LOW
            )
            nm.createNotificationChannel(ch)
        }
    }

    // Mirrors the Dart _formatNotifStats humanizer so the notification looks the
    // same whether the app is foreground or gone (Locale.US to keep a dot
    // decimal separator regardless of device locale).
    private fun humanBytes(b: Long): String {
        if (b < 1024) return "$b B"
        val units = arrayOf("KB", "MB", "GB", "TB")
        var v = b / 1024.0
        var i = 0
        while (v >= 1024 && i < units.size - 1) {
            v /= 1024
            i++
        }
        val digits = if (v >= 100) 0 else 1
        return "${String.format(Locale.US, "%.${digits}f", v)} ${units[i]}"
    }

    private fun formatStatsLine(rx: Long, tx: Long): String =
        "↓ ${humanBytes(rx)}   ↑ ${humanBytes(tx)}"

    // Keeps the previous stats line on any error (JNI missing, core not yet up).
    private fun refreshNativeStats() {
        try {
            val raw = nativeEngineTraffic()
            if (raw.isBlank()) return
            val parts = raw.split(",")
            if (parts.size != 2) return
            val rx = parts[0].toLongOrNull() ?: return
            val tx = parts[1].toLongOrNull() ?: return
            lastStatsLine = formatStatsLine(rx, tx)
        } catch (_: Throwable) {
        }
    }

    private fun formatDuration(ms: Long): String {
        val totalSeconds = (ms / 1000).toInt()
        val hours = totalSeconds / 3600
        val minutes = (totalSeconds % 3600) / 60
        val seconds = totalSeconds % 60
        return when {
            hours > 0 -> "${hours}h ${minutes}m"
            minutes > 0 -> "${minutes}m ${seconds}s"
            else -> "${seconds}s"
        }
    }

    private fun buildNotification(
        title: String? = null,
        countryLine: String? = null,
        statsLine: String? = null,
        showDisconnectAction: Boolean = true
    ): Notification {
        createNotificationChannel()

        if (!title.isNullOrBlank()) lastTitle = title
        if (!countryLine.isNullOrBlank()) lastCountryLine = countryLine
        if (statsLine != null) lastStatsLine = statsLine

        val lines = mutableListOf<String>()
        if (lastCountryLine.isNotBlank()) lines.add(lastCountryLine)
        if (lastStatsLine.isNotBlank()) lines.add(lastStatsLine)
        if (connectedSinceMs > 0) {
            val elapsed = System.currentTimeMillis() - connectedSinceMs
            lines.add(formatDuration(elapsed))
        }
        val bigText = lines.joinToString("\n")

        val contentText = when {
            lastCountryLine.isNotBlank() -> lastCountryLine
            lines.isNotEmpty() -> lines.first()
            else -> "Connected"
        }

        val disconnectIntent = Intent(this, GlitchVpnService::class.java).apply {
            action = ACTION_DISCONNECT
        }
        val piFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else PendingIntent.FLAG_UPDATE_CURRENT
        val disconnectPending: PendingIntent =
            PendingIntent.getService(this, 1001, disconnectIntent, piFlags)

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentPending = launchIntent?.let {
            PendingIntent.getActivity(this, 1000, it, piFlags)
        }

        val builder = NotificationCompat.Builder(this, NOTIF_CHANNEL_ID)
            .setContentTitle(lastTitle)
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOnlyAlertOnce(true)
            .setContentIntent(contentPending)
        if (bigText.isNotBlank()) {
            builder.setStyle(NotificationCompat.BigTextStyle().bigText(bigText))
        }
        if (showDisconnectAction) {
            builder.addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                lastDisconnectText,
                disconnectPending
            )
        }
        return builder.build()
    }

    private fun sendTunReady(intent: Intent?, fd: Int) {
        val rr = if (Build.VERSION.SDK_INT >= 33) {
            intent?.getParcelableExtra(EXTRA_RESULT_RECEIVER, android.os.ResultReceiver::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent?.getParcelableExtra(EXTRA_RESULT_RECEIVER)
        }
        val b = Bundle().apply { putInt(EXTRA_FD, fd) }
        rr?.send(RESULT_TUN_READY, b)
        Log.i(TAG, "sendTunReady fd=$fd (rr=${rr != null})")
    }

    private fun sendTunError(intent: Intent?, msg: String) {
        val rr = if (Build.VERSION.SDK_INT >= 33) {
            intent?.getParcelableExtra(EXTRA_RESULT_RECEIVER, android.os.ResultReceiver::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent?.getParcelableExtra(EXTRA_RESULT_RECEIVER)
        }
        val b = Bundle().apply { putString(EXTRA_ERROR, msg) }
        rr?.send(RESULT_TUN_ERROR, b)
        Log.e(TAG, "sendTunError: $msg (rr=${rr != null})")
    }

    private fun startKeepAliveUpdates() {
        connectedSinceMs = System.currentTimeMillis()
        val handler = Handler(Looper.getMainLooper())
        keepAliveHandler = handler
        val runnable = object : Runnable {
            override fun run() {
                try {
                    refreshNativeStats()
                    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    nm.notify(NOTIF_ID, buildNotification())
                } catch (t: Throwable) {
                    Log.w(TAG, "keepalive notification update failed: ${t.message}")
                }
                handler.postDelayed(this, 1_000L)
            }
        }
        keepAliveRunnable = runnable
        handler.postDelayed(runnable, 1_000L)
    }

    private fun stopKeepAliveUpdates() {
        keepAliveRunnable?.let { keepAliveHandler?.removeCallbacks(it) }
        keepAliveHandler = null
        keepAliveRunnable = null
    }

    private fun handleActionStart(intent: Intent?): Int {
        disconnecting = false
        val title = intent?.getStringExtra(EXTRA_NOTIF_TITLE)
        val subtitle = intent?.getStringExtra(EXTRA_NOTIF_SUBTITLE)
        if (!title.isNullOrBlank()) lastTitle = title
        val countryLine = intent?.getStringExtra(EXTRA_COUNTRY_LINE)
        if (!countryLine.isNullOrBlank()) lastCountryLine = countryLine
        val disconnectText = intent?.getStringExtra(EXTRA_DISCONNECT_TEXT)
        if (!disconnectText.isNullOrBlank()) lastDisconnectText = disconnectText
        startAsForeground(title ?: "Glitch VPN", subtitle ?: "Connecting…")

        val builder = Builder()
        val sessionName = intent?.getStringExtra(EXTRA_SESSION) ?: "GlitchVPN"
        val mtu = intent?.getIntExtra(EXTRA_MTU, 1420) ?: 1420
        
        val addresses = intent?.getStringArrayExtra(EXTRA_ADDRESSES) ?: arrayOf("10.0.0.2/32")

        val routes = intent?.getStringArrayExtra(EXTRA_ROUTES) ?: arrayOf("0.0.0.0/0")

        builder.setSession(sessionName)
        builder.setMtu(mtu)

        // Split tunneling extras come first so we can decide whether to disallow our own app
        val splitType = intent?.getStringExtra(EXTRA_SPLIT_TYPE)
        val splitApps = if (Build.VERSION.SDK_INT >= 33) {
            intent?.getStringArrayExtra(EXTRA_SPLIT_APPS)
        } else {
            @Suppress("DEPRECATION")
            intent?.getStringArrayExtra(EXTRA_SPLIT_APPS)
        }

        // Disallow our own app unless we're in whitelist mode (cannot mix allowed+disallowed)
        if (splitType?.lowercase() != "whitelist") {
            try { 
                Log.i(TAG, "Disallowing self package: $packageName")
                builder.addDisallowedApplication(packageName) 
            } catch (e: Throwable) {
                Log.e(TAG, "CRITICAL: Failed to disallow self ($packageName): ${e.message}")
            }
        }

        val dnsFromIntent = intent?.getStringExtra(EXTRA_DNS)
        try {
            if (!dnsFromIntent.isNullOrBlank()) {
                builder.addDnsServer(dnsFromIntent)
            } else {
                builder.addDnsServer("1.1.1.1"); builder.addDnsServer("1.0.0.1")
            }
        } catch (_: Throwable) {}

        if (!splitApps.isNullOrEmpty()) {
            when (splitType?.lowercase()) {
                "whitelist" -> {
                    for (pkg in splitApps) try { builder.addAllowedApplication(pkg) } catch (e: Throwable) {
                        Log.e(TAG, "Failed to allow $pkg: ${e.message}")
                    }
                }
                "blacklist" -> {
                    for (pkg in splitApps) try { builder.addDisallowedApplication(pkg) } catch (e: Throwable) {
                        Log.e(TAG, "Failed to disallow $pkg: ${e.message}")
                    }
                }
                else -> {}
            }
        }
        
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                builder.allowFamily(android.system.OsConstants.AF_INET)
                // builder.allowFamily(android.system.OsConstants.AF_INET6) // if IPv6 needed
            }
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to allowFamily: ${e.message}")
        }

        for (addr in addresses) {
            val p = addr.split("/")
            if (p.size == 2) try { builder.addAddress(p[0], p[1].toIntOrNull() ?: 32) } catch (_: Throwable) {}
        }
        for (route in routes) {
            val p = route.split("/")
            if (p.size == 2) try { builder.addRoute(p[0], p[1].toIntOrNull() ?: 0) } catch (_: Throwable) {}
        }

        return try {
            // fdsan: keep the PFD (no detachFd) - Java retains ownership; Go
            // dup()s the raw fd and closes only its copy; handleActionFinalize()
            // closes the original via PFD.close().
            val pfd = builder.establish()
            if (pfd == null) {
                sendTunError(intent, "establish() returned null")
                stopSelf()
                Service.START_NOT_STICKY
            } else {
                val engineFd = pfd.getFd()

                tunFd = engineFd
                ownerPfd = pfd
                finalized = false

                Log.i(TAG, "TUN established, kept PFD ownership, engineFd=$engineFd")
                sendTunReady(intent, engineFd)
                startKeepAliveUpdates()
                Service.START_STICKY
            }
        } catch (t: Throwable) {
            sendTunError(intent, "Failed to establish TUN: ${t.message}")
            stopSelf()
            Service.START_NOT_STICKY
        }
    }

    private fun requestCoreDisconnect(intent: Intent?, source: String, safetyDelayMs: Long): Int {
        Log.i(TAG, "$source received")
        disconnecting = true
        stopKeepAliveUpdates()
        val t = intent?.getStringExtra(EXTRA_NOTIF_TITLE)
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val title = if (t.isNullOrBlank()) "Disconnecting" else t
        nm.notify(NOTIF_ID, buildNotification(title, null, null, false))
        // Signal Dart/UI only - do not close the PFD here.
        GlitchVpnCorePlugin.notifyDisconnectPressed()

        // If the UI is attached (Dart is running), the notifyDisconnectPressed
        // channel above already drove the disconnect. Do NOT start the headless
        // engine then - it's heavy, blocks the main thread, and causes an ANR.
        if (!GlitchVpnCorePlugin.isUiAttached()) {
            Log.i(TAG, "UI detached -> starting headless disconnect")
            startHeadlessDisconnect(intent)
        } else {
            Log.i(TAG, "UI attached -> skipping headless disconnect to avoid ANR")
        }

        // Safety net: if ACTION_FINALIZE never arrives (race/crash), self-finalize.
        Handler(Looper.getMainLooper()).postDelayed({
            if (disconnecting && !finalized) {
                Log.w(TAG, "Safety timeout: forcing finalize after $source")
                handleActionFinalize()
            }
        }, safetyDelayMs)

        return Service.START_STICKY
    }

    private fun handleActionDisconnect(intent: Intent?): Int {
        return requestCoreDisconnect(intent, "ACTION_DISCONNECT", 15_000)
    }

    override fun onRevoke() {
        Log.w(TAG, "VPN revoked by Android; requesting core disconnect")
        Handler(Looper.getMainLooper()).post {
            requestCoreDisconnect(null, "onRevoke", 5_000)
        }
    }

    private fun startHeadlessDisconnect(intent: Intent?) {
        if (headlessEngine != null) {
            Log.i(TAG, "Headless engine already running")
            return
        }
        try {
            val appCtx = applicationContext
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(appCtx)
            loader.ensureInitializationComplete(appCtx, null)

            val engine = FlutterEngine(appCtx)
            engine.plugins.add(GlitchVpnCorePlugin())

            val maybeTitle = intent?.getStringExtra(EXTRA_NOTIF_TITLE)
            val maybeSubtitle = intent?.getStringExtra(EXTRA_NOTIF_SUBTITLE)
            if (!maybeTitle.isNullOrBlank() || !maybeSubtitle.isNullOrBlank()) {
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(NOTIF_ID, buildNotification(maybeTitle, maybeSubtitle ?: lastCountryLine.ifBlank { null }))
            }

            val entrypoint = try {
                // Newer API: (bundlePath, libraryUri, functionName)
                DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(),
                    "package:glitch_vpn_core/glitch_vpn_core.dart",
                    "glitchVpnCoreBackgroundDisconnect"
                )
            } catch (_: NoSuchMethodError) {
                // Older API: (bundlePath, functionName) - function must be reachable from root
                DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(),
                    "glitchVpnCoreBackgroundDisconnect"
                )
            }
            engine.dartExecutor.executeDartEntrypoint(entrypoint)

            headlessEngine = engine

            // Auto-clean the engine after a timeout so it doesn't linger in memory.
            Handler(Looper.getMainLooper()).postDelayed({
                try {
                    headlessEngine?.destroy()
                } catch (_: Throwable) {}
                headlessEngine = null
            }, 15000)
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to start headless FlutterEngine: ${t.message}")
        }
    }

    private fun handleActionUpdate(intent: Intent?): Int {
        // Ignore updates after disconnect - prevents race where a buffered stats update
        // re-creates the notification after ACTION_FINALIZE already cancelled it.
        if (disconnecting || finalized) {
            Log.i(TAG, "Ignoring ACTION_UPDATE: disconnecting=$disconnecting finalized=$finalized")
            return Service.START_NOT_STICKY
        }

        val title = intent?.getStringExtra(EXTRA_NOTIF_TITLE)
        val countryLine = intent?.getStringExtra(EXTRA_COUNTRY_LINE)
            ?: intent?.getStringExtra(EXTRA_NOTIF_SUBTITLE) // backwards compat
        val statsLine = intent?.getStringExtra(EXTRA_STATS_LINE)
        val disconnectText = intent?.getStringExtra(EXTRA_DISCONNECT_TEXT)
        val showDisconnect =
            intent?.getBooleanExtra(EXTRA_NOTIF_SHOW_DISCONNECT, true) ?: true

        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIF_ID, buildNotification(title, countryLine, statsLine, showDisconnect))
        if (!disconnectText.isNullOrBlank()) lastDisconnectText = disconnectText
        return Service.START_STICKY
    }

    private fun handleActionFinalize(): Int {
        Log.i(TAG, "ACTION_FINALIZE received -> clearing state")
        stopKeepAliveUpdates()
        finalized = true
        
        synchronized(this) {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
                Log.i(TAG, "WakeLock released")
            }
            wakeLock = null
        }

        // Close the PFD - Kotlin owns the original fd, Go works with a dup'd copy.
        // Go already closed its dup'd copy when the engine stopped.
        try {
            ownerPfd?.close()
            Log.i(TAG, "PFD closed by finalize")
        } catch (t: Throwable) {
            Log.w(TAG, "PFD close error (expected if already closed): ${t.message}")
        }
        ownerPfd = null
        tunFd = -1

        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(NOTIF_ID)
        } catch (_: Throwable) {}
        try { stopForeground(Service.STOP_FOREGROUND_REMOVE) } catch (_: Throwable) {}
        stopSelf()
        return Service.START_NOT_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        stopKeepAliveUpdates()
        Log.i(TAG, "onDestroy finalized=$finalized")
        if (!finalized) {
            // Service destroyed without finalize (e.g. system kill) - close PFD to release TUN.
            try {
                ownerPfd?.close()
                Log.i(TAG, "PFD closed by onDestroy (not finalized)")
            } catch (t: Throwable) {
                Log.w(TAG, "PFD close in onDestroy error: ${t.message}")
            }
        }
        ownerPfd = null
        tunFd = -1
    }
}
