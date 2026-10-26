package com.glitch_vpn.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

internal class EngineTrafficTest {
    @Test
    fun readsRxThenTx() {
        assertEquals(1024L to 512L, parseEngineTraffic("1024,512"))
    }

    @Test
    fun noEngineRunningIsNull() {
        assertNull(parseEngineTraffic(""))
    }

    @Test
    fun garbageIsNull() {
        assertNull(parseEngineTraffic("1024"))
        assertNull(parseEngineTraffic("a,b"))
        assertNull(parseEngineTraffic("1,2,3"))
    }
}
