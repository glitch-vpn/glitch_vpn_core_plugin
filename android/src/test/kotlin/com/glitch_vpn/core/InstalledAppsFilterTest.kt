package com.glitch_vpn.core

import kotlin.test.Test
import kotlin.test.assertEquals

internal class InstalledAppsFilterTest {
    private val own = "app.example.own"
    private val launchable = setOf("com.android.chrome", "com.user.app", own)

    private fun listed(launchableOnly: Boolean, vararg packages: Pair<String, Boolean>) =
        packages.filter { (name, system) ->
            isListed(name, system, true, launchable, launchableOnly, own)
        }.map { it.first }

    @Test
    fun aDisabledPackageIsListedOnlyWhenEveryPackageIs() {
        assertEquals(false, isListed("com.disabled", false, false, launchable, true, own))
        assertEquals(true, isListed("com.disabled", false, false, launchable, false, own))
    }

    @Test
    fun launchableOnlyKeepsUserAppsAndSystemAppsWithALauncherEntry() {
        val result = listed(
            true,
            "com.user.app" to false,
            "com.user.service" to false,
            "com.android.chrome" to true,
            "com.android.providers.media" to true,
        )
        assertEquals(listOf("com.user.app", "com.user.service", "com.android.chrome"), result)
    }

    @Test
    fun allPackagesKeepsSystemPackagesWithoutALauncherEntry() {
        val result = listed(false, "com.android.providers.media" to true, "com.user.app" to false)
        assertEquals(listOf("com.android.providers.media", "com.user.app"), result)
    }

    @Test
    fun theOwnPackageIsNeverListed() {
        assertEquals(emptyList(), listed(true, own to false))
        assertEquals(emptyList(), listed(false, own to false))
    }
}
