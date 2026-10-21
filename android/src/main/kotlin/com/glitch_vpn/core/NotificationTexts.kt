package com.glitch_vpn.core

import android.os.Bundle

/** The notification's words, in the app's language; see VpnNotificationTexts in Dart. */
internal data class NotificationTexts(
    val title: String,
    val channel: String,
    val connecting: String,
    val connected: String,
    val disconnecting: String,
    val disconnectAction: String,
    /** The traffic line's units, from bytes up to terabytes. */
    val byteUnits: List<String>,
) {
    fun toBundle(): Bundle = Bundle().apply {
        putString(KEY_TITLE, title)
        putString(KEY_CHANNEL, channel)
        putString(KEY_CONNECTING, connecting)
        putString(KEY_CONNECTED, connected)
        putString(KEY_DISCONNECTING, disconnecting)
        putString(KEY_DISCONNECT_ACTION, disconnectAction)
        KEYS_BYTE_UNITS.zip(byteUnits).forEach { (key, unit) -> putString(key, unit) }
    }

    companion object {
        private const val KEY_TITLE = "title"
        private const val KEY_CHANNEL = "channel"
        private const val KEY_CONNECTING = "connecting"
        private const val KEY_CONNECTED = "connected"
        private const val KEY_DISCONNECTING = "disconnecting"
        private const val KEY_DISCONNECT_ACTION = "disconnectAction"
        private val KEYS_BYTE_UNITS = listOf("bytes", "kilobytes", "megabytes", "gigabytes", "terabytes")

        /** Null unless every text is present: a partial set is not shown. */
        fun fromMap(map: Map<*, *>?): NotificationTexts? {
            if (map == null) return null
            fun text(key: String) = map[key] as? String
            return NotificationTexts(
                title = text(KEY_TITLE) ?: return null,
                channel = text(KEY_CHANNEL) ?: return null,
                connecting = text(KEY_CONNECTING) ?: return null,
                connected = text(KEY_CONNECTED) ?: return null,
                disconnecting = text(KEY_DISCONNECTING) ?: return null,
                disconnectAction = text(KEY_DISCONNECT_ACTION) ?: return null,
                byteUnits = KEYS_BYTE_UNITS.map { text(it) ?: return null },
            )
        }

        fun fromBundle(bundle: Bundle?): NotificationTexts? {
            if (bundle == null) return null
            return fromMap(bundle.keySet().associateWith { bundle.getString(it) })
        }
    }
}
