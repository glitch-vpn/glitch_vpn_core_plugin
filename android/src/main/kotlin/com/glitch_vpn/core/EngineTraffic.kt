package com.glitch_vpn.core

/**
 * The core's traffic answer, "rx,tx" in bytes, as (rx, tx); null for the empty
 * answer while no engine runs, and for anything malformed.
 */
internal fun parseEngineTraffic(raw: String): Pair<Long, Long>? {
    val parts = raw.split(",")
    if (parts.size != 2) return null
    val rx = parts[0].trim().toLongOrNull() ?: return null
    val tx = parts[1].trim().toLongOrNull() ?: return null
    return rx to tx
}
