package cn.iepose.lovespace.love_space

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 2.8.0 fix7/fix8 · 静止心跳纯决策单测（施工令四·1 的可测部分）。
 *
 * 只测 [HeartbeatGate]（不碰 Android API）。AlarmManager 在真机 Doze 下
 * 是否准时、动态接收器是否收到广播，JVM 单测无法证明——那两条由真机
 * `dumpsys deviceidle force-idle` + logcat 实测，回执已注明。
 */
class HeartbeatGateTest {

    private val win = HeartbeatGate.HEARTBEAT_MS // 300_000

    // ① 同一 5 min 窗口只许一点（防双发）：差 1 ms 都不放行
    @Test
    fun due_onlyAfterFullWindow() {
        assertFalse(HeartbeatGate.due(1_000L, 1_000L))
        assertFalse(HeartbeatGate.due(1_000L + win - 1, 1_000L))
        assertTrue(HeartbeatGate.due(1_000L + win, 1_000L))
        assertTrue(HeartbeatGate.due(1_000L + win * 3, 1_000L))
    }

    // ② 首次上报（lastSentAt=0）立即视为到期
    @Test
    fun due_whenNeverSentBefore() {
        assertTrue(HeartbeatGate.due(win, 0L))
        assertFalse(HeartbeatGate.due(win - 1, 0L))
    }

    // ③ 进入静止：连续满 3 次才置位，且已静止不重复触发（防重复挂表）
    @Test
    fun enterStill_requiresConfirmTimesAndNotAlreadyStill() {
        assertFalse(HeartbeatGate.shouldEnterStill(0, false))
        assertFalse(HeartbeatGate.shouldEnterStill(2, false))
        assertTrue(HeartbeatGate.shouldEnterStill(3, false))
        assertTrue(HeartbeatGate.shouldEnterStill(4, false))
        assertFalse(HeartbeatGate.shouldEnterStill(3, true))
    }

    // ④ fix8 持续兜底：采集中且有历史定位就挂表；只有停采才收摊
    @Test
    fun arm_requiresRunningAndHistory_onlyStopEndsIt() {
        assertTrue(HeartbeatGate.shouldArm(true, true))
        assertFalse(HeartbeatGate.shouldArm(false, true))
        assertFalse(HeartbeatGate.shouldArm(true, false))
        assertTrue(HeartbeatGate.shouldEndArm(false))
        assertFalse(HeartbeatGate.shouldEndArm(true))
        assertTrue(HeartbeatGate.hasHistory(true, false))
        assertTrue(HeartbeatGate.hasHistory(false, true))
        assertFalse(HeartbeatGate.hasHistory(false, false))
    }

    // ⑤ tick 出点必须三条全真（运行中 + 有历史 + 满窗口）；
    //    关键：stillMode 不再参与——「刚移动完就息屏」也要能产点
    @Test
    fun emitOnTick_needsRunningHistoryAndDue() {
        assertTrue(HeartbeatGate.shouldEmitOnTick(true, true, true))
        assertFalse(HeartbeatGate.shouldEmitOnTick(false, true, true))
        assertFalse(HeartbeatGate.shouldEmitOnTick(true, false, true))
        assertFalse(HeartbeatGate.shouldEmitOnTick(true, true, false))
    }

    // ⑥ 续挂锚点 = lastSentAt + 窗口；锚点已过则 earliest = now + 1s（不漂移累加）
    @Test
    fun nextArmAt_anchorsOnLastSentAt_notOnNow() {
        val last = 10_000L
        assertEquals(last + win, HeartbeatGate.nextArmAt(last + 1_000L, last))
        // tick 早到（被系统提前唤醒）：仍按锚点，不把下一次推后
        assertEquals(last + win, HeartbeatGate.nextArmAt(last - 1_000L, last))
        // 锚点已过：立刻补一跳，且不早于 now + minDelay
        assertEquals(50_000L + HeartbeatGate.MIN_ARM_DELAY_MS,
            HeartbeatGate.nextArmAt(50_000L, last))
    }

    // ⑦ acc 口径：只有 ≤50 的来源定位能造心跳轨迹点，50–100 只许保鲜 latest
    @Test
    fun heartbeatSource_onlyAcceptsPointTierAccuracy() {
        assertTrue(HeartbeatGate.heartbeatSourceAllowed(5.0))
        assertTrue(HeartbeatGate.heartbeatSourceAllowed(50.0)) // 边界含等号
        assertFalse(HeartbeatGate.heartbeatSourceAllowed(50.1))
        assertFalse(HeartbeatGate.heartbeatSourceAllowed(80.0))
    }
}
