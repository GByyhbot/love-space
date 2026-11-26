package cn.iepose.lovespace.love_space

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 2.8.7 全量施工令 · 应用使用采集纯逻辑（JVM 单测）。
 *
 * 钉住令文 §六 原生三条：
 * 7. 会话配对（RESUMED/PAUSED 交错、多应用切换、跨调用游标续拉不重不漏）；
 * 8. <10 秒折叠两态；脱敏命中后不出现真实包名；
 * 9. street 网格化圆整；进行中会话跨进程恢复的超时丢弃。
 */
class UsageGatesTest {

    private fun ev(pkg: String, ts: Long, resumed: Boolean) =
        UsageGates.Raw(pkg, ts, resumed)

    @Test
    fun `resumed paused pairs into one session`() {
        val r = UsageGates.pairIncremental(
            null,
            listOf(ev("com.a", 1000, true), ev("com.a", 61000, false)),
        )
        assertEquals(1, r.sessions.size)
        assertEquals("com.a", r.sessions[0].pkg)
        assertEquals(1000, r.sessions[0].start)
        assertEquals(61000, r.sessions[0].end)
        assertEquals(60, r.sessions[0].durSec)
        assertNull(r.open)
    }

    @Test
    fun `switch app closes previous at switch time`() {
        val r = UsageGates.pairIncremental(
            null,
            listOf(
                ev("com.a", 1000, true),
                ev("com.b", 5000, true),   // 换包：A 到此结束
                ev("com.b", 9000, false),
            ),
        )
        assertEquals(2, r.sessions.size)
        assertEquals("com.a", r.sessions[0].pkg)
        assertEquals(5000, r.sessions[0].end)
        assertEquals("com.b", r.sessions[1].pkg)
        assertEquals(4000, r.sessions[1].durSec)
    }

    @Test
    fun `same pkg resumed twice does not open twice`() {
        val r = UsageGates.pairIncremental(
            null,
            listOf(
                ev("com.a", 1000, true),
                ev("com.a", 3000, true),
                ev("com.a", 5000, false),
            ),
        )
        assertEquals(1, r.sessions.size)
        assertEquals(1000, r.sessions[0].start)
    }

    @Test
    fun `paused for another pkg is ignored`() {
        val r = UsageGates.pairIncremental(
            null,
            listOf(
                ev("com.a", 1000, true),
                ev("com.b", 2000, false),  // 乱序/别包 PAUSED：不许关 A
                ev("com.a", 3000, false),
            ),
        )
        assertEquals(1, r.sessions.size)
        assertEquals(3000, r.sessions[0].end)
    }

    @Test
    fun `cross call resume continues open session (no duplicate no gap)`() {
        // 第一次拉取只看到 RESUMED
        val first = UsageGates.pairIncremental(
            null, listOf(ev("com.a", 1000, true)))
        assertEquals(0, first.sessions.size)
        assertEquals("com.a", first.open?.pkg)
        // 第二次拉取只看到 PAUSED（游标已过 RESUMED）
        val second = UsageGates.pairIncremental(
            first.open, listOf(ev("com.a", 61000, false)))
        assertEquals(1, second.sessions.size)
        assertEquals(1000, second.sessions[0].start)
        assertEquals(60000, second.sessions[0].durSec)
        assertNull(second.open)
    }

    @Test
    fun `cross call switch across batch keeps continuity`() {
        val first = UsageGates.pairIncremental(
            null, listOf(ev("com.a", 1000, true), ev("com.a", 2000, true)))
        val second = UsageGates.pairIncremental(
            first.open,
            listOf(ev("com.b", 3000, true), ev("com.b", 9000, false)))
        assertEquals(2, second.sessions.size)
        assertEquals("com.a", second.sessions[0].pkg)
        assertEquals(3000, second.sessions[0].end)
        assertEquals("com.b", second.sessions[1].pkg)
    }

    @Test
    fun `fold short drops under ten seconds only when enabled`() {
        assertTrue(UsageGates.shouldDrop(9, true))
        assertFalse(UsageGates.shouldDrop(10, true))
        assertFalse(UsageGates.shouldDrop(9, false))
    }

    @Test
    fun `mask hit replaces pkg with sentinel`() {
        val (pkg, masked) = UsageGates.mask("com.secret", setOf("com.secret"))
        assertEquals(UsageGates.MASK_PKG, pkg)
        assertTrue(masked)
        // 未命中：原样
        val (p2, m2) = UsageGates.mask("com.wechat", setOf("com.secret"))
        assertEquals("com.wechat", p2)
        assertFalse(m2)
    }

    @Test
    fun `masked payload contains no real package string`() {
        val (pkg, masked) = UsageGates.mask("com.secret.app", setOf("com.secret.app"))
        val label = if (masked) UsageGates.MASK_APP else "com.secret.app"
        val payload = "pkg=$pkg;app=$label"
        assertFalse(payload.contains("com.secret.app"))
        assertTrue(payload.contains("masked.other"))
    }

    @Test
    fun `grid round to 500m step`() {
        assertEquals(39.905, UsageGates.gridRound(39.9031), 1e-9)
        assertEquals(116.400, UsageGates.gridRound(116.3987), 1e-9)
        // 已在网格上的值不动
        assertEquals(39.900, UsageGates.gridRound(39.900), 1e-9)
    }

    @Test
    fun `now emit throttles per app but fires on change`() {
        assertTrue(UsageGates.shouldEmitNow("", 0, "com.a", 1000))
        // 同应用未到 30 秒：不发
        assertFalse(UsageGates.shouldEmitNow("com.a", 1000, "com.a", 2000))
        // 同应用满 30 秒：发
        assertTrue(UsageGates.shouldEmitNow("com.a", 1000, "com.a", 31000))
        // 换应用：立刻发
        assertTrue(UsageGates.shouldEmitNow("com.a", 31000, "com.b", 31001))
    }

    @Test
    fun `cursor never runs into future and stays when batch empty`() {
        assertEquals(5000, UsageGates.advanceCursor(0, 5000, 9000))
        assertEquals(5000, UsageGates.advanceCursor(5000, 0, 9000))
        assertEquals(9000, UsageGates.advanceCursor(0, 12000, 9000))
    }

    @Test
    fun `stale open session dropped after six hours`() {
        val now = 10 * 3600_000L
        assertNull(UsageGates.sanitizeOpen(UsageGates.Open("com.a", 0), now))
        assertNull(UsageGates.sanitizeOpen(UsageGates.Open("com.a", 1000), now))
        // 3 小时前开的：保留
        assertEquals("com.a", UsageGates.sanitizeOpen(UsageGates.Open("com.a", now - 3 * 3600_000L), now)?.pkg)
    }
}
