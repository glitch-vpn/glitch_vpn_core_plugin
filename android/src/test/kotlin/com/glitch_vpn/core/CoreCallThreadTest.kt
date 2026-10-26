package com.glitch_vpn.core

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class CoreCallThreadTest {
    @Test
    fun callAskedForWhileOneIsBlockedIsSkippedNotQueued() {
        val coreCalls = CoreCallThread()
        val release = CountDownLatch(1)
        val firstDone = CountDownLatch(1)
        var calls = 0
        assertTrue(coreCalls.callIfIdle({ calls++; release.await(); "first" }) { firstDone.countDown() })

        assertFalse(coreCalls.callIfIdle({ calls++; "second" }) { })

        release.countDown()
        assertTrue(firstDone.await(5, TimeUnit.SECONDS))
        assertEquals(1, calls)
    }

    @Test
    fun nextCallRunsOnceThePreviousOneReturned() {
        val coreCalls = CoreCallThread()
        repeat(3) { round ->
            val done = CountDownLatch(1)
            var result: String? = null
            assertTrue(coreCalls.callIfIdle({ "round $round" }) { result = it; done.countDown() })
            assertTrue(done.await(5, TimeUnit.SECONDS))
            assertEquals("round $round", result)
        }
    }

    @Test
    fun callThatThrowsHandsOverNullAndFreesTheThread() {
        val coreCalls = CoreCallThread()
        val failed = CountDownLatch(1)
        var result: String? = "unset"
        coreCalls.callIfIdle<String>({ throw UnsatisfiedLinkError("no core") }) { result = it; failed.countDown() }
        assertTrue(failed.await(5, TimeUnit.SECONDS))
        assertNull(result)

        val next = CountDownLatch(1)
        assertTrue(coreCalls.callIfIdle({ "ok" }) { next.countDown() })
        assertTrue(next.await(5, TimeUnit.SECONDS))
    }
}
