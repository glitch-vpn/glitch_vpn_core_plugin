package com.glitch_vpn.core

import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The one thread the service calls into the core on, never the main thread:
 * an engine start or stop holds the core for as long as it runs. A call asked
 * for while the previous one is still running is skipped, not queued.
 */
internal class CoreCallThread {
    private val executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "GlitchVpnCoreCall").apply { isDaemon = true }
    }
    private val busy = AtomicBoolean(false)

    /**
     * Runs [call] on the thread and hands its result, or null when it threw,
     * to [onResult] there. False when a call was still running; [onResult]
     * is not called then.
     */
    fun <T : Any> callIfIdle(call: () -> T, onResult: (T?) -> Unit): Boolean {
        if (!busy.compareAndSet(false, true)) return false
        executor.execute {
            val result = try { call() } catch (_: Throwable) { null }
            busy.set(false)
            onResult(result)
        }
        return true
    }
}
