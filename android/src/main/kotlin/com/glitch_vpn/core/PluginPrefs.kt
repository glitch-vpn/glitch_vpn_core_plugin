package com.glitch_vpn.core

import android.content.Context
import android.content.SharedPreferences

/**
 * What the service needs when the system starts it with no app running: the
 * app's system-start handler and the notification's last words.
 */
internal object PluginPrefs {
    private const val FILE = "glitch_vpn_core"
    private const val KEY_SYSTEM_START_HANDLE = "systemStartHandle"
    private const val KEY_TEXTS_PREFIX = "notification."

    private fun prefs(ctx: Context): SharedPreferences =
        ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    /** The Dart callback handle of the app's system-start handler, or null. */
    fun systemStartHandle(ctx: Context): Long? {
        val p = prefs(ctx)
        return if (p.contains(KEY_SYSTEM_START_HANDLE)) p.getLong(KEY_SYSTEM_START_HANDLE, 0L) else null
    }

    fun setSystemStartHandle(ctx: Context, handle: Long?) {
        prefs(ctx).edit().apply {
            if (handle == null) remove(KEY_SYSTEM_START_HANDLE) else putLong(KEY_SYSTEM_START_HANDLE, handle)
        }.apply()
    }

    fun notificationTexts(ctx: Context): NotificationTexts? {
        val p = prefs(ctx)
        return NotificationTexts.fromMap(
            p.all.filterKeys { it.startsWith(KEY_TEXTS_PREFIX) }
                .mapKeys { it.key.removePrefix(KEY_TEXTS_PREFIX) }
        )
    }

    fun setNotificationTexts(ctx: Context, texts: NotificationTexts) {
        val bundle = texts.toBundle()
        prefs(ctx).edit().apply {
            for (key in bundle.keySet()) putString(KEY_TEXTS_PREFIX + key, bundle.getString(key))
        }.apply()
    }
}
