package com.glitch_vpn.core

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager

/**
 * One page of installed apps: `items` of `package` and `name`, and `total`. A [query] matches any
 * package or label containing the text, so every listed app is labelled to answer it.
 */
internal fun installedAppsPage(
    apps: InstalledAppIndex,
    ownPackage: String,
    offset: Int,
    limit: Int?,
    launchableOnly: Boolean,
    query: String?,
): Map<String, Any> {
    val launchable = if (launchableOnly) apps.launchablePackages() else emptySet()
    val listed = apps.installedApplications().filter { app ->
        isListed(app.packageName, app.system, app.enabled, launchable, launchableOnly, ownPackage)
    }
    val lowerQuery = query?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
    val filtered = if (lowerQuery == null) {
        listed
    } else {
        listed.filter { app ->
            app.packageName.lowercase().contains(lowerQuery) ||
                app.label().lowercase().contains(lowerQuery)
        }
    }
    val start = offset.coerceIn(0, filtered.size)
    val end = if (limit == null) filtered.size else (start + limit).coerceAtMost(filtered.size)
    val slice = if (start < end) filtered.subList(start, end) else emptyList()
    val items = ArrayList<Map<String, String>>(slice.size)
    for (app in slice) {
        items.add(mapOf("package" to app.packageName, "name" to app.label()))
    }
    return hashMapOf("items" to items, "total" to filtered.size)
}

/**
 * The well-formed package names among [packages] that are installed, system apps included, in the
 * order given and without repeats. No label is read.
 */
internal fun installedPackagesAmong(apps: InstalledAppIndex, packages: List<Any?>): List<String> =
    packages.filterIsInstance<String>().distinct().filter { name ->
        isPackageName(name) && apps.application(name) != null
    }

/**
 * The labels of the [packages] asked for, as `package` to label: only the well-formed names that are
 * installed and that [isListed] lists with every package in scope. No other app is labelled.
 */
internal fun installedAppLabels(
    apps: InstalledAppIndex,
    ownPackage: String,
    packages: List<Any?>,
): Map<String, String> {
    val labels = LinkedHashMap<String, String>()
    for (name in packages.filterIsInstance<String>().distinct()) {
        if (!isPackageName(name)) continue
        val app = apps.application(name) ?: continue
        if (!isListed(app.packageName, app.system, app.enabled, emptySet(), false, ownPackage)) continue
        labels[name] = app.label()
    }
    return labels
}

internal interface InstalledAppIndex {
    fun launchablePackages(): Set<String>
    fun installedApplications(): List<InstalledApp>

    /** The one package, or null when it is not installed. */
    fun application(packageName: String): InstalledApp?
}

internal class InstalledApp(
    val packageName: String,
    val system: Boolean,
    val enabled: Boolean,
    private val readLabel: () -> String,
) {
    fun label(): String = readLabel()
}

internal class PackageManagerIndex(
    private val packageManager: PackageManager,
) : InstalledAppIndex {
    override fun launchablePackages(): Set<String> {
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        return packageManager.queryIntentActivities(intent, 0)
            .map { it.activityInfo.packageName }
            .toSet()
    }

    @Suppress("DEPRECATION")
    override fun installedApplications(): List<InstalledApp> =
        packageManager.getInstalledApplications(0).mapNotNull { it.asInstalledApp(packageManager) }

    override fun application(packageName: String): InstalledApp? = try {
        packageManager.getApplicationInfo(packageName, 0).asInstalledApp(packageManager)
    } catch (_: Throwable) {
        null
    }
}

private fun ApplicationInfo.asInstalledApp(packageManager: PackageManager): InstalledApp? {
    val pkg = packageName?.takeIf { it.isNotEmpty() } ?: return null
    val info = this
    return InstalledApp(
        packageName = pkg,
        system = (info.flags and ApplicationInfo.FLAG_SYSTEM) != 0,
        enabled = info.enabled,
    ) { packageManager.getApplicationLabel(info)?.toString() ?: pkg }
}
