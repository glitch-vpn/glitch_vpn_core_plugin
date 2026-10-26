package com.glitch_vpn.core

/**
 * Tells which tunnel session a delayed callback was posted for. A callback
 * captures [current] when it is posted and acts only while [isCurrent] holds,
 * so a session's timers die with it.
 */
internal class SessionGeneration {
    @Volatile
    var current: Long = 0L
        private set

    /** A new session starts: every earlier callback is now stale. */
    fun begin(): Long {
        current += 1
        return current
    }

    /** The session ended: every callback posted for it is stale. */
    fun end() {
        current += 1
    }

    fun isCurrent(generation: Long): Boolean = generation == current
}
