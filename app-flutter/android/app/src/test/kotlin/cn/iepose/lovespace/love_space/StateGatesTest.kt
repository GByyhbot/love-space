package cn.iepose.lovespace.love_space

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 2.8.7 自动报备：状态事件判定口径（与 Dart 侧 state_aggregator.dart 一一对应）。
 *
 * 钉住：电量阈值与**已报值**比、充电翻转即报、60s 防抖不丢变化、
 * 网络类型变化即报、SSID 抖动 5min 冷却、解锁 10min 窗口、亮屏会话时长。
 */
class StateGatesTest {

    // ── 电量 ────────────────────────────────────────────────

    @Test
    fun battery_firstReading_alwaysEmits() {
        assertTrue(
            StateGates.battery(
                level = 80, chargingFlag = 0, emittedLevel = -1,
                seenCharging = -1, lastEmitMs = 0L, nowMs = 0L
            )
        )
    }

    @Test
    fun battery_accumulatesAgainstEmittedValue_notLastReading() {
        // 已报 80，逐 1% 走到 82：与已报值差 2 → 必须报（跟读数比会永远攒不到）
        assertTrue(
            StateGates.battery(
                level = 82, chargingFlag = 0, emittedLevel = 80,
                seenCharging = 0, lastEmitMs = 0L, nowMs = 300_000L
            )
        )
        // 只差 1 → 不报
        assertFalse(
            StateGates.battery(
                level = 81, chargingFlag = 0, emittedLevel = 80,
                seenCharging = 0, lastEmitMs = 0L, nowMs = 300_000L
            )
        )
    }

    @Test
    fun battery_chargingFlip_emitsEvenWithoutLevelChange() {
        assertTrue(
            StateGates.battery(
                level = 50, chargingFlag = 1, emittedLevel = 50,
                seenCharging = 0, lastEmitMs = 0L, nowMs = 300_000L
            )
        )
    }

    @Test
    fun battery_debounce_blocksWithin60s() {
        assertFalse(
            StateGates.battery(
                level = 90, chargingFlag = 0, emittedLevel = 80,
                seenCharging = 0, lastEmitMs = 100_000L, nowMs = 130_000L
            )
        )
        assertTrue(
            StateGates.battery(
                level = 90, chargingFlag = 0, emittedLevel = 80,
                seenCharging = 0, lastEmitMs = 100_000L, nowMs = 161_000L
            )
        )
    }

    @Test
    fun battery_outOfRange_isIgnored() {
        assertFalse(
            StateGates.battery(
                level = -1, chargingFlag = 0, emittedLevel = -1,
                seenCharging = -1, lastEmitMs = 0L, nowMs = 0L
            )
        )
        assertFalse(
            StateGates.battery(
                level = 101, chargingFlag = 0, emittedLevel = 80,
                seenCharging = 0, lastEmitMs = 0L, nowMs = 0L
            )
        )
    }

    // ── 网络 ────────────────────────────────────────────────

    @Test
    fun net_firstAndTypeChange_emit() {
        assertTrue(
            StateGates.net(
                type = "wifi", ssid = "home", lastType = "", lastSsid = "",
                lastEmitMs = 0L, ssidLastEmitMs = 0L, nowMs = 0L
            )
        )
        assertTrue(
            StateGates.net(
                type = "none", ssid = "", lastType = "wifi", lastSsid = "home",
                lastEmitMs = 0L, ssidLastEmitMs = 0L, nowMs = 60_000L
            )
        )
    }

    @Test
    fun net_sameTypeAndSsid_isSilent() {
        assertFalse(
            StateGates.net(
                type = "wifi", ssid = "home", lastType = "wifi", lastSsid = "home",
                lastEmitMs = 0L, ssidLastEmitMs = 0L, nowMs = 60_000L
            )
        )
    }

    @Test
    fun net_ssidFlap_isCooldownFor5min() {
        assertFalse(
            StateGates.net(
                type = "wifi", ssid = "", lastType = "wifi", lastSsid = "home",
                lastEmitMs = 0L, ssidLastEmitMs = 1_000L, nowMs = 60_000L
            )
        )
        assertTrue(
            StateGates.net(
                type = "wifi", ssid = "home2", lastType = "wifi", lastSsid = "home",
                lastEmitMs = 0L, ssidLastEmitMs = 1_000L, nowMs = 301_000L
            )
        )
    }

    @Test
    fun net_unknownType_isIgnored() {
        assertFalse(
            StateGates.net(
                type = "4g", ssid = "", lastType = "wifi", lastSsid = "home",
                lastEmitMs = 0L, ssidLastEmitMs = 0L, nowMs = 60_000L
            )
        )
    }

    // ── 解锁窗口 / 亮屏会话 ─────────────────────────────────

    @Test
    fun unlock_dueOnlyAfterTenMinutes() {
        assertFalse(StateGates.unlockDue(3, 0L, 600_000L))
        assertFalse(StateGates.unlockDue(3, 1_000L, 600_999L))
        assertTrue(StateGates.unlockDue(3, 1_000L, 601_000L))
        assertFalse(StateGates.unlockDue(0, 1_000L, 700_000L))
    }

    @Test
    fun screenSession_secondsAndGuard() {
        assertEquals(120, StateGates.screenSessionSec(0L, 120_000L))
        assertEquals(0, StateGates.screenSessionSec(0L, 0L))
        assertEquals(0, StateGates.screenSessionSec(-5L, 100_000L))
    }
}
