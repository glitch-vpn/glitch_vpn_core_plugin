package com.glitch_vpn.core

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

class GlitchVpnCorePlugin : FlutterPlugin, MethodCallHandler, ActivityAware {

    companion object {
        private const val CHANNEL_NAME = "glitch_vpn_core"
        private const val NOTIF_PERMISSION = "android.permission.POST_NOTIFICATIONS"
        private const val NOTIF_REQ_CODE = 8123
        private const val NOTIF_ONLY_REQ_CODE = 8124
        private const val PERM_ONLY_VPN_REQ_CODE = 40020
        private const val TAG = "GlitchVpnCorePlugin"

        @Volatile private var primaryChannel: MethodChannel? = null
        @Volatile private var appContext: Context? = null
        @Volatile private var activity: Activity? = null

        private val reqCode = AtomicInteger(40010)

        @Volatile private var pendingTunnel: TunnelRequest? = null
        @Volatile private var pendingResult: Result? = null
        @Volatile private var pendingPermissionOnlyResult: Result? = null

        /** Called from the service - forward to Dart on the UI thread. */
        fun notifyDisconnectPressed() {
            val ch = primaryChannel ?: return
            Handler(Looper.getMainLooper()).post {
                Log.i(TAG, "notifyDisconnectPressed -> invokeMethod(onDisconnectPressed)")
                ch.invokeMethod("onDisconnectPressed", null)
            }
        }

        fun isUiAttached(): Boolean {
            return (primaryChannel != null && attachedCount > 0)
        }

        @Volatile private var attachedCount: Int = 0
    }

    private val bgExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private fun loadInstalledApps(offset: Int, limit: Int?, includeSystem: Boolean, query: String?): Map<String, Any> {
        val ctx = appContext ?: return emptyMap()
        val pm = ctx.packageManager
        val apps = pm.getInstalledApplications(0)
        val lowerQuery = query?.trim()?.lowercase()
        val filteredBase = if (includeSystem) apps else apps.filter { (it.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) == 0 }
        val filtered = if (lowerQuery.isNullOrEmpty()) filteredBase else filteredBase.filter { ai ->
            val pkg = ai.packageName ?: ""
            val name = pm.getApplicationLabel(ai)?.toString() ?: pkg
            pkg.lowercase().contains(lowerQuery) || name.lowercase().contains(lowerQuery)
        }
        val total = filtered.size
        val start = offset.coerceIn(0, filtered.size)
        val end = if (limit == null) filtered.size else (start + limit).coerceAtMost(filtered.size)
        val slice = if (start < end) filtered.subList(start, end) else emptyList()
        val out = ArrayList<Map<String, String>>(slice.size)
        for (ai in slice) {
            val pkg = ai.packageName ?: continue
            val name = pm.getApplicationLabel(ai)?.toString() ?: pkg
            out.add(mapOf("package" to pkg, "name" to name))
        }
        return hashMapOf("items" to out, "total" to total)
    }

    private fun loadAppIcons(packages: List<String>): Map<String, ByteArray> {
        val ctx = appContext ?: return emptyMap()
        val pm = ctx.packageManager
        val out = HashMap<String, ByteArray>(packages.size)
        for (pkg in packages) {
            try {
                val d = pm.getApplicationIcon(pkg)
                val bmp = when (d) {
                    is android.graphics.drawable.BitmapDrawable -> d.bitmap
                    else -> {
                        val size = (48 * ctx.resources.displayMetrics.density).toInt().coerceAtLeast(48)
                        val b = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
                        val c = android.graphics.Canvas(b)
                        d.setBounds(0, 0, c.width, c.height)
                        d.draw(c)
                        b
                    }
                }
                val bos = java.io.ByteArrayOutputStream()
                bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, bos)
                out[pkg] = bos.toByteArray()
            } catch (_: Throwable) {
                // ignore
            }
        }
        return out
    }
    private var instanceChannel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        if (appContext == null) {
            appContext = binding.applicationContext
        }
        instanceChannel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        instanceChannel?.setMethodCallHandler(this)
        attachedCount += 1
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attachedCount = (attachedCount - 1).coerceAtLeast(0)
        if (primaryChannel == instanceChannel) {
            primaryChannel = null
        }
        instanceChannel?.setMethodCallHandler(null)
        instanceChannel = null
        if (attachedCount == 0) {
            appContext = null
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        if (instanceChannel != null) {
            primaryChannel = instanceChannel
        }

        binding.addActivityResultListener { requestCode, resultCode, _ ->
            if (requestCode == PERM_ONLY_VPN_REQ_CODE) {
                pendingPermissionOnlyResult?.success(resultCode == Activity.RESULT_OK)
                pendingPermissionOnlyResult = null
                true
            } else if (requestCode == reqCode.get()) {
                val tunnel = pendingTunnel
                if (resultCode == Activity.RESULT_OK && tunnel != null) {
                    launchService(tunnel, pendingResult)
                } else {
                    pendingResult?.error("DENIED", "User denied VPN permission", null)
                }
                pendingTunnel = null
                pendingResult = null
                true
            } else false
        }

        binding.addRequestPermissionsResultListener { code, _, grantResults ->
            if (code == NOTIF_REQ_CODE) {
                val tunnel = pendingTunnel
                if (grantResults.isNotEmpty() &&
                    grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED &&
                    tunnel != null
                ) {
                    startVpnService(tunnel, pendingResult)
                } else {
                    pendingResult?.error("NOTIFICATIONS_DENIED", "User denied notifications permission", null)
                    pendingTunnel = null
                    pendingResult = null
                }
                true
            } else if (code == NOTIF_ONLY_REQ_CODE) {
                true
            } else false
        }
    }

    override fun onDetachedFromActivity() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { onAttachedToActivity(binding) }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getPlatformVersion" -> result.success("Android ${Build.VERSION.RELEASE}")

            "prepareTunnel" -> {
                val texts = NotificationTexts.fromMap(call.argument<Map<String, Any?>>("notification"))
                if (texts == null) {
                    result.error("NO_NOTIFICATION_TEXTS", "prepareTunnel needs the notification texts", null)
                    return
                }
                val tunnel = TunnelRequest(
                    addresses = call.argument<List<String>>("addresses")?.toTypedArray(),
                    dns = call.argument<String>("dns"),
                    mtu = call.argument<Int>("mtu"),
                    splitType = call.argument<String>("splitType"),
                    splitApps = call.argument<List<String>>("splitApps")?.toTypedArray(),
                    texts = texts,
                )
                startVpnService(tunnel, result)
            }

            "stopTunnel" -> {
                requestFinalizeFromService()
                result.success(true)
            }

            "updateNotification" -> {
                pushNotificationUpdate(
                    texts = NotificationTexts.fromMap(call.argument<Map<String, Any?>>("notification")),
                    countryLine = call.argument<String>("countryLine"),
                    connected = false,
                )
                result.success(true)
            }

            "showNotificationPhase" -> {
                when (call.argument<String>("phase")) {
                    "connected" -> pushNotificationUpdate(texts = null, countryLine = null, connected = true)
                    "disconnecting" -> if (tunnelUp()) sendServiceAction(GlitchVpnService.ACTION_DISCONNECTING)
                }
                result.success(true)
            }

            "requestNotificationPermission" -> {
                // true = granted/not needed; false = prompt shown (VPN still connects)
                val act = activity
                when {
                    Build.VERSION.SDK_INT < 33 || act == null -> result.success(true)
                    ContextCompat.checkSelfPermission(act, NOTIF_PERMISSION) ==
                        android.content.pm.PackageManager.PERMISSION_GRANTED -> result.success(true)
                    else -> {
                        ActivityCompat.requestPermissions(
                            act, arrayOf(NOTIF_PERMISSION), NOTIF_ONLY_REQ_CODE
                        )
                        result.success(false)
                    }
                }
            }

            "appsListing" -> {
                val offset = call.argument<Int>("offset") ?: 0
                val limit = call.argument<Int>("limit")
                val includeSystem = call.argument<Boolean>("includeSystem") ?: false
                val query = call.argument<String>("query")
                bgExecutor.execute {
                    val list = loadInstalledApps(offset, limit, includeSystem, query)
                    mainHandler.post { result.success(list) }
                }
            }

            "isAnyVpnActive" -> {
                val ctx = appContext
                if (ctx == null) {
                    result.success(false)
                    return
                }
                val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                if (cm == null) {
                    result.success(false)
                    return
                }
                val activeNetwork = cm.activeNetwork
                if (activeNetwork == null) {
                    result.success(false)
                    return
                }
                val caps = cm.getNetworkCapabilities(activeNetwork)
                val hasVpn = caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
                result.success(hasVpn)
            }

            "appsIcon" -> {
                val packages = call.argument<List<String>>("packages") ?: emptyList()
                bgExecutor.execute {
                    val icons = loadAppIcons(packages)
                    mainHandler.post { result.success(icons) }
                }
            }

            "isBatteryOptimized" -> {
                val ctx = appContext
                if (ctx == null) {
                    result.success(true) // assume optimized if no context
                    return
                }
                val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager
                val ignoring = pm?.isIgnoringBatteryOptimizations(ctx.packageName) ?: false
                result.success(!ignoring) // true = still optimized (bad), false = exempted (good)
            }

            "requestVpnPermission" -> {
                val ctx = appContext ?: run { result.success(false); return }
                val prepare = VpnService.prepare(ctx)
                if (prepare != null) {
                    val act = activity ?: run { result.success(false); return }
                    pendingPermissionOnlyResult = result
                    act.startActivityForResult(prepare, PERM_ONLY_VPN_REQ_CODE)
                    return
                }
                result.success(true)
            }

            "requestIgnoreBatteryOptimization" -> {
                val ctx = appContext
                val act = activity
                if (ctx == null || act == null) {
                    result.success(false)
                    return
                }
                val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager
                if (pm?.isIgnoringBatteryOptimizations(ctx.packageName) == true) {
                    result.success(true) // already exempted
                    return
                }
                try {
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                        data = Uri.parse("package:${ctx.packageName}")
                    }
                    act.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to request battery optimization exemption: ${e.message}")
                    result.success(false)
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun ensureNotificationPermission(result: Result?): Boolean {
        if (Build.VERSION.SDK_INT < 33) return true
        val ctx = appContext ?: return true

        val granted = (ContextCompat.checkSelfPermission(
            ctx, NOTIF_PERMISSION
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED)

        if (!granted) {
            // Notification permission is requested separately by the Dart layer
            // before connecting. Don't block VPN connection if not granted.
            Log.w(TAG, "Notification permission not granted; VPN will work without notifications")
        }
        return true
    }

    private fun startVpnService(tunnel: TunnelRequest, result: Result?) {
        val ctx = appContext ?: run {
            result?.error("NO_CONTEXT", "Application context missing", null); return
        }

        if (!ensureNotificationPermission(result)) {
            pendingTunnel = tunnel
            pendingResult = result
            return
        }

        val prepare = VpnService.prepare(ctx)
        if (prepare != null) {
            val act = activity ?: run {
                result?.error("NO_ACTIVITY", "Activity not attached", null); return
            }
            pendingTunnel = tunnel
            pendingResult = result
            act.startActivityForResult(prepare, reqCode.get())
            return
        }

        launchService(tunnel, result)
    }

    private fun launchService(tunnel: TunnelRequest, result: Result?) {
        val ctx = appContext ?: run {
            result?.error("NO_CONTEXT", "Application context missing", null); return
        }

        val svc = Intent(ctx, GlitchVpnService::class.java).apply {
            if (tunnel.addresses != null) putExtra(GlitchVpnService.EXTRA_ADDRESSES, tunnel.addresses)
            if (!tunnel.dns.isNullOrBlank()) putExtra(GlitchVpnService.EXTRA_DNS, tunnel.dns)
            if (tunnel.mtu != null) putExtra(GlitchVpnService.EXTRA_MTU, tunnel.mtu)
            if (!tunnel.splitType.isNullOrBlank()) putExtra(GlitchVpnService.EXTRA_SPLIT_TYPE, tunnel.splitType)
            if (tunnel.splitApps != null) putExtra(GlitchVpnService.EXTRA_SPLIT_APPS, tunnel.splitApps)
            putExtra(GlitchVpnService.EXTRA_NOTIFICATION_TEXTS, tunnel.texts.toBundle())
        }

        val receiver = object : android.os.ResultReceiver(Handler(Looper.getMainLooper())) {
            override fun onReceiveResult(resultCode: Int, resultData: Bundle?) {
                when (resultCode) {
                    GlitchVpnService.RESULT_TUN_READY -> {
                        val fd = resultData?.getInt(GlitchVpnService.EXTRA_FD, -1) ?: -1
                        if (fd <= 0) result?.error("NO_FD", "Service returned invalid FD", null)
                        else result?.success(fd)
                    }
                    GlitchVpnService.RESULT_TUN_ERROR -> {
                        val msg = resultData?.getString(GlitchVpnService.EXTRA_ERROR) ?: "Unknown error"
                        result?.error("TUN_ERROR", msg, null)
                    }
                }
            }
        }
        svc.putExtra(GlitchVpnService.EXTRA_RESULT_RECEIVER, receiver)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ContextCompat.startForegroundService(ctx, svc)
        } else {
            ctx.startService(svc)
        }
    }

    private fun sendServiceAction(action: String) {
        val ctx = appContext ?: return
        ctx.startService(Intent(ctx, GlitchVpnService::class.java).apply { this.action = action })
    }

    private fun requestFinalizeFromService() = sendServiceAction(GlitchVpnService.ACTION_FINALIZE)

    // Without a tunnel there is no notification, and an intent would only
    // start a service that has nothing to show (or throw from the background).
    private fun tunnelUp() = GlitchVpnService.tunFd >= 0

    private fun pushNotificationUpdate(
        texts: NotificationTexts?,
        countryLine: String?,
        connected: Boolean,
    ) {
        val ctx = appContext ?: return
        if (!tunnelUp()) return
        val i = Intent(ctx, GlitchVpnService::class.java).apply {
            action = GlitchVpnService.ACTION_UPDATE
            if (texts != null) putExtra(GlitchVpnService.EXTRA_NOTIFICATION_TEXTS, texts.toBundle())
            if (countryLine != null) putExtra(GlitchVpnService.EXTRA_COUNTRY_LINE, countryLine)
            if (connected) putExtra(GlitchVpnService.EXTRA_CONNECTED, true)
        }
        ctx.startService(i)
    }
}

private class TunnelRequest(
    val addresses: Array<String>?,
    val dns: String?,
    val mtu: Int?,
    val splitType: String?,
    val splitApps: Array<String>?,
    val texts: NotificationTexts,
)
