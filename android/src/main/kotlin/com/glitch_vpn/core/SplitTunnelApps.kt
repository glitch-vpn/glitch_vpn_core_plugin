package com.glitch_vpn.core

/**
 * The per-app calls of VpnService.Builder. Android accepts a package that is not installed
 * without adding any rule for it, so installation is asked separately.
 */
internal interface AppRoutingTarget {
    fun isInstalled(packageName: String): Boolean
    fun allow(packageName: String)
    fun disallow(packageName: String)
}

internal enum class AppRoutingOutcome {
    /** Only the listed apps that are installed go through the tunnel. */
    Whitelist,

    /** Every app but the excluded ones goes through the tunnel. */
    Blacklist,

    /** A whitelist named no installed app; every app but this one goes through the tunnel. */
    WhitelistFellBack,
}

/**
 * Applies the split-tunnel choice so that this process never enters its own tun, where the
 * engine's connection to its server would loop. A whitelist that adds no app leaves the tun
 * with no app rule, so it falls back to excluding this package. A builder takes either
 * allowed or disallowed apps, never both.
 */
internal fun applyAppRouting(
    target: AppRoutingTarget,
    splitType: String?,
    apps: List<String>,
    ownPackage: String,
): AppRoutingOutcome {
    if (splitType?.lowercase() == "whitelist") {
        val installed = apps.filter { it != ownPackage && target.isInstalled(it) }
        if (installed.isNotEmpty()) {
            installed.forEach { target.allow(it) }
            return AppRoutingOutcome.Whitelist
        }
        target.disallow(ownPackage)
        return AppRoutingOutcome.WhitelistFellBack
    }
    target.disallow(ownPackage)
    if (splitType?.lowercase() == "blacklist") {
        apps.filter { it != ownPackage }.forEach { target.disallow(it) }
    }
    return AppRoutingOutcome.Blacklist
}
