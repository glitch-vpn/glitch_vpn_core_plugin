package com.glitch_vpn.core

import kotlin.test.Test
import kotlin.test.assertEquals

internal class SplitTunnelAppsTest {
    private val own = "app.example.own"

    /** Android takes an absent package without adding a rule, and refuses to mix the two lists. */
    private class FakeTarget(private val installed: Set<String>) : AppRoutingTarget {
        val allowed = mutableListOf<String>()
        val disallowed = mutableListOf<String>()
        private var allowCalled = false
        private var disallowCalled = false

        override fun isInstalled(packageName: String) = packageName in installed

        override fun allow(packageName: String) {
            if (disallowCalled) throw UnsupportedOperationException()
            allowCalled = true
            if (packageName in installed) allowed += packageName
        }

        override fun disallow(packageName: String) {
            if (allowCalled) throw UnsupportedOperationException()
            disallowCalled = true
            if (packageName in installed) disallowed += packageName
        }
    }

    @Test
    fun whitelistNeverAddsTheOwnPackage() {
        val target = FakeTarget(setOf(own, "a"))
        val outcome = applyAppRouting(target, "whitelist", listOf(own, "a"), own)
        assertEquals(AppRoutingOutcome.Whitelist, outcome)
        assertEquals(listOf("a"), target.allowed)
        assertEquals(emptyList(), target.disallowed)
    }

    @Test
    fun whitelistOfOnlyTheOwnPackageFallsBack() {
        val target = FakeTarget(setOf(own))
        val outcome = applyAppRouting(target, "whitelist", listOf(own), own)
        assertEquals(AppRoutingOutcome.WhitelistFellBack, outcome)
        assertEquals(emptyList(), target.allowed)
        assertEquals(listOf(own), target.disallowed)
    }

    @Test
    fun whitelistWithNoInstalledAppFallsBackToExcludingTheOwnPackage() {
        val target = FakeTarget(setOf(own))
        val outcome = applyAppRouting(target, "whitelist", listOf("gone", "absent"), own)
        assertEquals(AppRoutingOutcome.WhitelistFellBack, outcome)
        assertEquals(emptyList(), target.allowed)
        assertEquals(listOf(own), target.disallowed)
    }

    @Test
    fun emptyWhitelistFallsBack() {
        val target = FakeTarget(setOf(own))
        val outcome = applyAppRouting(target, "whitelist", emptyList(), own)
        assertEquals(AppRoutingOutcome.WhitelistFellBack, outcome)
        assertEquals(listOf(own), target.disallowed)
    }

    @Test
    fun whitelistWithSomeInstalledAppsKeepsThemAndSkipsTheAbsent() {
        val target = FakeTarget(setOf(own, "a", "b"))
        val outcome = applyAppRouting(target, "WhiteList", listOf("a", "gone", "b"), own)
        assertEquals(AppRoutingOutcome.Whitelist, outcome)
        assertEquals(listOf("a", "b"), target.allowed)
        assertEquals(emptyList(), target.disallowed)
    }

    @Test
    fun blacklistExcludesTheOwnPackageAndTheListed() {
        val target = FakeTarget(setOf(own, "a", "b"))
        val outcome = applyAppRouting(target, "blacklist", listOf("a", own, "b"), own)
        assertEquals(AppRoutingOutcome.Blacklist, outcome)
        assertEquals(emptyList(), target.allowed)
        assertEquals(listOf(own, "a", "b"), target.disallowed)
    }

    @Test
    fun noSplitTunnelExcludesTheOwnPackage() {
        val target = FakeTarget(setOf(own))
        val outcome = applyAppRouting(target, null, emptyList(), own)
        assertEquals(AppRoutingOutcome.Blacklist, outcome)
        assertEquals(listOf(own), target.disallowed)
    }

    @Test
    fun whitelistOfAbsentAppsNeverPassesThemToTheBuilder() {
        val target = FakeTarget(setOf(own))
        applyAppRouting(target, "whitelist", listOf("gone"), own)
        assertEquals(emptyList(), target.allowed)
        assertEquals(listOf(own), target.disallowed)
    }
}
