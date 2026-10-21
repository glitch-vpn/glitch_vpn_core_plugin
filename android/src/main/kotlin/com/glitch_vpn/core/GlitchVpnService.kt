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
import io.flutter.plugin.common.MethodChannel

class GlitchVpnService : VpnService() {

    companion object {
        const val ACTION_START      = "com.glitch_vpn.core.ACTION_START"
        const val ACTION_SYSTEM_START_DECLINED = "com.glitch_vpn.core.ACTION_SYSTEM_START_DECLINED"
        const val ACTION_DISCONNECT = "com.glitch_vpn.core.ACTION_DISCONNECT"
        const val ACTION_FINALIZE   = "com.glitch_vpn.core.ACTION_FINALIZE"
        const val ACTION_UPDATE     = "com.glitch_vpn.core.ACTION_UPDATE"
        const val ACTION_DISCONNECTING = "com.glitch_vpn.core.ACTION_DISCONNECTING"

        const val EXTRA_ADDRESSES = "addresses"
        const val EXTRA_ROUTES    = "routes"
        const val EXTRA_MTU       = "mtu"
        const val EXTRA_NOTIFICATION_TEXTS = "notificationTexts"
        const val EXTRA_CONNECTED = "connected"
        const val EXTRA_COUNTRY_LINE = "countryLine"
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
        // Runs the app's system-start handler and stays for the session it
        // starts: the tunnel it opened is torn down by that isolate's Dart.
        @Volatile private var systemStartEngine: FlutterEngine? = null
        @Volatile private var wakeLock: android.os.PowerManager.WakeLock? = null
        @Volatile private var instance: GlitchVpnService? = null

        /** Why the system started the service: "alwaysOn" or "restart". */
        @Volatile var systemStartReason: String? = null
            private set

        /** The service is up and in the foreground, so a plain start reaches it from anywhere. */
        @Volatile var inForeground: Boolean = false
            private set

        private fun channelOf(engine: FlutterEngine) =
            MethodChannel(engine.dartExecutor.binaryMessenger, GlitchVpnCorePlugin.CHANNEL_NAME)

        /** The UI's engine is gone: the system-start isolate takes the core's events back. */
        fun onUiDetached() {
            val engine = systemStartEngine ?: return
            Handler(Looper.getMainLooper()).post {
                channelOf(engine).invokeMethod("reclaimStatus", null)
            }
        }

        /**
         * (always-on, lockdown) while a tunnel runs; null with none or below
         * Android 10. Android answers only once the tunnel is up.
         */
        fun alwaysOnState(): Pair<Boolean, Boolean>? {
            val svc = instance ?: return null
            if (ownerPfd == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
            return svc.isAlwaysOn to svc.isLockdownEnabled
        }

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

    private enum class Phase { CONNECTING, CONNECTED, DISCONNECTING }

    private var phase = Phase.CONNECTING
    private var texts: NotificationTexts? = null
    private var countryLine: String = ""
    private var statsLine: String = ""
    @Volatile private var disconnecting: Boolean = false

    override fun onBind(intent: Intent?): IBinder? = super.onBind(intent)

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        Log.i(TAG, "onStartCommand action=$action")

        if (action == ACTION_START || action == ACTION_UPDATE) { // ACTION_UPDATE also keeps the lock held
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
            ACTION_DISCONNECT -> handleActionDisconnect()
            ACTION_DISCONNECTING -> handleActionDisconnecting()
            ACTION_FINALIZE   -> handleActionFinalize()
            ACTION_UPDATE     -> handleActionUpdate(intent)
            ACTION_START      -> handleActionStart(intent)
            ACTION_SYSTEM_START_DECLINED -> handleSystemStartDeclined()
            // The system's own start (always-on, android.net.VpnService) or a
            // sticky restart after the process died (null intent): no session
            // was asked for, and no engine is running in this process.
            else              -> handleSystemStart(if (intent == null) "restart" else "alwaysOn")
        }
    }

    private fun handleSystemStart(reason: String): Int {
        if (ownerPfd != null) {
            Log.i(TAG, "System start over a live tunnel: nothing to do")
            return Service.START_STICKY
        }
        disconnecting = false
        phase = Phase.CONNECTING
        connectedSinceMs = 0L
        countryLine = ""
        statsLine = ""
        texts = texts ?: PluginPrefs.notificationTexts(this)
        systemStartReason = reason
        try {
            startAsForeground()
        } catch (t: Throwable) {
            // A restart from the background may not go foreground (Android 12+).
            Log.w(TAG, "System start could not go foreground: ${t.message}")
            stopSelf()
            return Service.START_NOT_STICKY
        }

        if (PluginPrefs.systemStartHandle(this) == null) {
            Log.i(TAG, "System start with no handler registered: stopping")
            stopWithoutTunnel()
            return Service.START_NOT_STICKY
        }
        // A UI isolate already holds the core's events: the handler runs there.
        if (!GlitchVpnCorePlugin.runSystemStartInUi()) startSystemStartEngine()
        // A handler that neither connects nor returns must not hold the
        // service (and, under lockdown, the device's traffic) forever.
        Handler(Looper.getMainLooper()).postDelayed({
            if (ownerPfd == null && instance == this) {
                Log.w(TAG, "System start: no tunnel after 60s, stopping")
                stopWithoutTunnel()
            }
        }, 60_000)
        return Service.START_NOT_STICKY
    }

    private fun handleSystemStartDeclined(): Int {
        if (ownerPfd == null) {
            Log.i(TAG, "System start declined by the app: stopping")
            stopWithoutTunnel()
        }
        return Service.START_NOT_STICKY
    }

    private fun leaveForeground() {
        inForeground = false
        try { stopForeground(Service.STOP_FOREGROUND_REMOVE) } catch (_: Throwable) {}
    }

    private fun stopWithoutTunnel() {
        destroySystemStartEngine()
        leaveForeground()
        stopSelf()
    }

    private fun startSystemStartEngine() {
        if (systemStartEngine != null) return
        systemStartEngine = startHeadlessEngine("glitchVpnCoreSystemStart") ?: run {
            stopWithoutTunnel()
            return
        }
    }

    // Both headless entries live in the plugin's library. The engine registers
    // the app's plugins too, so a handler can read the app's own storage.
    private fun startHeadlessEngine(entrypoint: String): FlutterEngine? {
        var engine: FlutterEngine? = null
        return try {
            val appCtx = applicationContext
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(appCtx)
            loader.ensureInitializationComplete(appCtx, null)
            engine = FlutterEngine(appCtx)
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(),
                    "package:glitch_vpn_core/glitch_vpn_core.dart",
                    entrypoint
                )
            )
            engine
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to start the headless engine $entrypoint: ${t.message}")
            try { engine?.destroy() } catch (_: Throwable) {}
            null
        }
    }

    private fun destroySystemStartEngine() {
        val engine = systemStartEngine ?: return
        systemStartEngine = null
        try { engine.destroy() } catch (_: Throwable) {}
    }

    private fun startAsForeground(): Int {
        createNotificationChannel()
        val n = buildNotification()
        return when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> {
                // Android 14+: SPECIAL_USE is required for VPN services
                startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
                inForeground = true
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            }
            else -> {
                // Android 10-13 and below: don't specify foregroundServiceType
                // (SPECIAL_USE constant doesn't exist pre-API 34, and manifest only declares specialUse)
                startForeground(NOTIF_ID, n)
                inForeground = true
                0
            }
        }
    }

    // Before the app has sent its texts, the app's own label stands in.
    private fun appLabel(): String = applicationInfo.loadLabel(packageManager).toString()

    // Creating an existing channel again renames it, so a change of language
    // reaches the system's settings too.
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val name = texts?.channel?.ifBlank { null } ?: appLabel()
        nm.createNotificationChannel(
            NotificationChannel(NOTIF_CHANNEL_ID, name, NotificationManager.IMPORTANCE_LOW)
        )
    }

    // Locale.US keeps a dot decimal separator regardless of device locale.
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

    // Keeps the previous stats line on any error (JNI missing, core not yet
    // up). True when the core reported a running engine.
    private fun refreshNativeStats(): Boolean {
        try {
            val raw = nativeEngineTraffic()
            if (raw.isBlank()) return false
            val parts = raw.split(",")
            if (parts.size != 2) return false
            val rx = parts[0].toLongOrNull() ?: return false
            val tx = parts[1].toLongOrNull() ?: return false
            statsLine = formatStatsLine(rx, tx)
            return true
        } catch (_: Throwable) {
            return false
        }
    }

    private fun markConnected() {
        if (phase != Phase.CONNECTING) return
        phase = Phase.CONNECTED
        connectedSinceMs = System.currentTimeMillis()
    }

    // A clock reading needs no words, so it reads the same in every language.
    private fun formatDuration(ms: Long): String {
        val totalSeconds = ms / 1000
        val hours = totalSeconds / 3600
        val minutes = (totalSeconds % 3600) / 60
        val seconds = totalSeconds % 60
        return if (hours > 0) {
            String.format(Locale.US, "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            String.format(Locale.US, "%02d:%02d", minutes, seconds)
        }
    }

    private fun buildNotification(): Notification {
        val words = texts
        val lines = mutableListOf<String>()
        val contentText = when (phase) {
            Phase.CONNECTING -> words?.connecting.orEmpty()
            Phase.DISCONNECTING -> words?.disconnecting.orEmpty()
            Phase.CONNECTED -> {
                if (countryLine.isNotBlank()) lines.add(countryLine)
                if (statsLine.isNotBlank()) lines.add(statsLine)
                if (connectedSinceMs > 0) {
                    lines.add(formatDuration(System.currentTimeMillis() - connectedSinceMs))
                }
                countryLine.ifBlank { words?.connected.orEmpty() }
            }
        }
        val bigText = lines.joinToString("\n")
        val disconnectAction = words?.disconnectAction.orEmpty()
        val showDisconnectAction = phase != Phase.DISCONNECTING && disconnectAction.isNotBlank()

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
            .setContentTitle(words?.title?.ifBlank { null } ?: appLabel())
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
                disconnectAction,
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
        val handler = Handler(Looper.getMainLooper())
        keepAliveHandler = handler
        val runnable = object : Runnable {
            override fun run() {
                try {
                    // A running engine is connected even when the Dart side
                    // that would say so is gone.
                    if (refreshNativeStats()) markConnected()
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
        phase = Phase.CONNECTING
        connectedSinceMs = 0L
        countryLine = ""
        statsLine = ""
        NotificationTexts.fromBundle(intent?.getBundleExtra(EXTRA_NOTIFICATION_TEXTS))?.let {
            texts = it
            PluginPrefs.setNotificationTexts(this, it)
        }
        startAsForeground()

        val builder = Builder()
        // The system's VPN settings show the session name.
        val sessionName = texts?.title?.ifBlank { null } ?: appLabel()
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
        
        // A family with no route here is blocked by Android; allowFamily
        // would let it bypass the tunnel instead.
        for (addr in addresses) {
            val (ip, prefix) = splitCidr(addr) ?: continue
            try { builder.addAddress(ip, prefix) } catch (e: Throwable) {
                Log.e(TAG, "addAddress $addr failed: ${e.message}")
            }
        }
        for (route in routes) {
            val (ip, prefix) = splitCidr(route) ?: continue
            try { builder.addRoute(ip, prefix) } catch (e: Throwable) {
                Log.e(TAG, "addRoute $route failed: ${e.message}")
            }
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

    private fun showDisconnecting() {
        disconnecting = true
        phase = Phase.DISCONNECTING
        stopKeepAliveUpdates()
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIF_ID, buildNotification())
    }

    // Dart's own disconnect: the engine stop is already under way there.
    private fun handleActionDisconnecting(): Int {
        if (finalized) return Service.START_NOT_STICKY
        showDisconnecting()
        finalizeIfStuck("ACTION_DISCONNECTING", 15_000)
        return Service.START_STICKY
    }

    // Safety net: if ACTION_FINALIZE never arrives (race/crash), self-finalize.
    private fun finalizeIfStuck(source: String, delayMs: Long) {
        Handler(Looper.getMainLooper()).postDelayed({
            if (disconnecting && !finalized) {
                Log.w(TAG, "Safety timeout: forcing finalize after $source")
                handleActionFinalize()
            }
        }, delayMs)
    }

    // "ip/prefix", or a bare ip read as a single host.
    private fun splitCidr(cidr: String): Pair<String, Int>? {
        val parts = cidr.trim().split("/")
        val ip = parts[0].ifBlank { return null }
        val prefix = parts.getOrNull(1)?.toIntOrNull() ?: if (ip.contains(':')) 128 else 32
        return ip to prefix
    }

    private fun requestCoreDisconnect(source: String, safetyDelayMs: Long): Int {
        Log.i(TAG, "$source received")
        showDisconnecting()
        // Signal Dart/UI only - do not close the PFD here.
        GlitchVpnCorePlugin.notifyDisconnectPressed()

        // If the UI is attached (Dart is running), the notifyDisconnectPressed
        // channel above already drove the disconnect. Do NOT start the headless
        // engine then - it's heavy, blocks the main thread, and causes an ANR.
        val sessionEngine = systemStartEngine
        if (GlitchVpnCorePlugin.isUiAttached()) {
            Log.i(TAG, "UI attached -> skipping headless disconnect to avoid ANR")
        } else if (sessionEngine != null) {
            // The isolate that connected is still listening: it disconnects.
            Log.i(TAG, "UI detached -> system-start engine disconnects")
            channelOf(sessionEngine).invokeMethod("onDisconnectPressed", null)
        } else {
            Log.i(TAG, "UI detached -> starting headless disconnect")
            startHeadlessDisconnect()
        }

        finalizeIfStuck(source, safetyDelayMs)

        return Service.START_STICKY
    }

    private fun handleActionDisconnect(): Int {
        return requestCoreDisconnect("ACTION_DISCONNECT", 15_000)
    }

    override fun onRevoke() {
        Log.w(TAG, "VPN revoked by Android; requesting core disconnect")
        Handler(Looper.getMainLooper()).post {
            requestCoreDisconnect("onRevoke", 5_000)
        }
    }

    private fun startHeadlessDisconnect() {
        if (headlessEngine != null) {
            Log.i(TAG, "Headless engine already running")
            return
        }
        headlessEngine = startHeadlessEngine("glitchVpnCoreBackgroundDisconnect") ?: return

        // Auto-clean the engine after a timeout so it doesn't linger in memory.
        Handler(Looper.getMainLooper()).postDelayed({
            try {
                headlessEngine?.destroy()
            } catch (_: Throwable) {}
            headlessEngine = null
        }, 15000)
    }

    private fun handleActionUpdate(intent: Intent?): Int {
        // Ignore updates after disconnect - prevents race where a buffered stats update
        // re-creates the notification after ACTION_FINALIZE already cancelled it.
        if (disconnecting || finalized) {
            Log.i(TAG, "Ignoring ACTION_UPDATE: disconnecting=$disconnecting finalized=$finalized")
            return Service.START_NOT_STICKY
        }

        val newTexts = NotificationTexts.fromBundle(intent?.getBundleExtra(EXTRA_NOTIFICATION_TEXTS))
        if (newTexts != null) {
            texts = newTexts
            PluginPrefs.setNotificationTexts(this, newTexts)
            createNotificationChannel()
        }
        intent?.getStringExtra(EXTRA_COUNTRY_LINE)?.let { countryLine = it }
        if (intent?.getBooleanExtra(EXTRA_CONNECTED, false) == true) markConnected()

        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIF_ID, buildNotification())
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
        leaveForeground()
        destroySystemStartEngine()
        stopSelf()
        return Service.START_NOT_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        if (instance == this) instance = null
        inForeground = false
        destroySystemStartEngine()
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
