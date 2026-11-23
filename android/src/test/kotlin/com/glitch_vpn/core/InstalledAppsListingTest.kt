package com.glitch_vpn.core

import kotlin.test.Test
import kotlin.test.assertEquals

internal class InstalledAppsListingTest {
    private val own = "app.example.own"

    @Test
    fun aPackageNameQueryWithoutALimitMatchesEveryPackageContainingIt() {
        val labeled = mutableListOf<String>()
        val index = FakeIndex(
            listOf(
                app("com.android.chrome", "Chrome", labeled),
                app("com.android.chrome.beta", "Chrome Beta", labeled),
                app("com.google.android.apps.maps", "Maps", labeled),
            ),
        )

        val page = installedAppsPage(index, own, 0, null, false, "  com.android.chrome  ")

        assertEquals(
            listOf(
                mapOf("package" to "com.android.chrome", "name" to "Chrome"),
                mapOf("package" to "com.android.chrome.beta", "name" to "Chrome Beta"),
            ),
            page["items"],
        )
        assertEquals(2, page["total"])
        assertEquals(emptyList(), index.lookups)
    }

    @Test
    fun aNameQueryMatchesTheLabelCaselessly() {
        val labeled = mutableListOf<String>()
        val maps = app("com.google.android.apps.nav", "Maps", labeled)
        val index = FakeIndex(listOf(app("com.android.chrome", "Chrome", labeled), maps))

        val page = installedAppsPage(index, own, 0, null, false, "MAPS")

        assertEquals(
            mapOf(
                "items" to listOf(mapOf("package" to maps.packageName, "name" to "Maps")),
                "total" to 1,
            ),
            page,
        )
    }

    @Test
    fun aListingWithoutAQueryLabelsOnlyThePage() {
        val labeled = mutableListOf<String>()
        val index = FakeIndex(
            listOf(
                app("com.android.chrome", "Chrome", labeled),
                app("com.android.chrome.beta", "Chrome Beta", labeled),
                app("com.google.android.apps.maps", "Maps", labeled),
            ),
        )

        val page = installedAppsPage(index, own, 0, 1, false, null)

        assertEquals(
            listOf(mapOf("package" to "com.android.chrome", "name" to "Chrome")),
            page["items"],
        )
        assertEquals(3, page["total"])
        assertEquals(listOf("com.android.chrome"), labeled)
    }

    @Test
    fun theInstalledPackagesAreFoundWithoutLabelsOrTheListing() {
        val labeled = mutableListOf<String>()
        val index = FakeIndex(
            listOf(
                app("com.android.chrome", "Chrome", labeled, system = true),
                app("com.google.android.apps.maps", "Maps", labeled),
            ),
        )

        val installed = installedPackagesAmong(
            index,
            listOf(
                "com.google.android.apps.maps",
                "com.missing.app",
                "chrome",
                7,
                null,
                "com.android.chrome",
                "com.android.chrome",
            ),
        )

        assertEquals(listOf("com.google.android.apps.maps", "com.android.chrome"), installed)
        assertEquals(emptyList(), labeled)
        assertEquals(
            listOf("com.google.android.apps.maps", "com.missing.app", "com.android.chrome"),
            index.lookups,
        )
    }
}

internal class FakeIndex(
    private val apps: List<InstalledApp>,
    private val launchers: Set<String> = emptySet(),
) : InstalledAppIndex {
    val lookups = mutableListOf<String>()

    override fun launchablePackages(): Set<String> = launchers

    override fun installedApplications(): List<InstalledApp> = apps

    override fun application(packageName: String): InstalledApp? {
        lookups += packageName
        return apps.firstOrNull { it.packageName == packageName }
    }
}

internal fun app(
    packageName: String,
    label: String,
    labeled: MutableList<String>,
    system: Boolean = false,
    enabled: Boolean = true,
) = InstalledApp(packageName, system, enabled) {
    labeled.add(packageName)
    label
}
