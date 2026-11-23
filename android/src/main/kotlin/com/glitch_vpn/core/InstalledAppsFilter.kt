package com.glitch_vpn.core

/**
 * Whether the app listing includes a package. The app itself never appears. With [launchableOnly]
 * a package is listed when it is enabled and is either not a system package or has a launcher
 * entry; without it, every other package is listed.
 */
internal fun isListed(
    packageName: String,
    isSystem: Boolean,
    isEnabled: Boolean,
    launchablePackages: Set<String>,
    launchableOnly: Boolean,
    ownPackage: String,
): Boolean {
    if (packageName == ownPackage) return false
    if (!launchableOnly) return true
    return isEnabled && (!isSystem || packageName in launchablePackages)
}

private val packageNameGrammar = Regex("""[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+""")

/** A well-formed Android package name, at most 255 characters. */
internal fun isPackageName(name: String): Boolean =
    name.length <= 255 && packageNameGrammar.matches(name)
