package com.glitch_vpn.core

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

internal class SessionGenerationTest {
    @Test
    fun callbackPostedInASessionIsCurrentUntilItEnds() {
        val sessions = SessionGeneration()
        sessions.begin()
        val posted = sessions.current
        assertTrue(sessions.isCurrent(posted))
        sessions.end()
        assertFalse(sessions.isCurrent(posted))
    }

    @Test
    fun callbackOfAnEarlierSessionIsStaleInTheNextOne() {
        val sessions = SessionGeneration()
        val first = sessions.begin()
        sessions.end()
        val second = sessions.begin()
        assertNotEquals(first, second)
        assertFalse(sessions.isCurrent(first))
        assertTrue(sessions.isCurrent(second))
    }

    @Test
    fun startingOverALiveSessionStalesItsCallbacks() {
        val sessions = SessionGeneration()
        val first = sessions.begin()
        sessions.begin()
        assertFalse(sessions.isCurrent(first))
    }
}
