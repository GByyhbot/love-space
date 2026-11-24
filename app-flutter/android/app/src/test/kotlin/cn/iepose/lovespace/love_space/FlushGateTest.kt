package cn.iepose.lovespace.love_space

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 2.8.0 fix8 · flush 单飞与 `accepted` 计数单测（施工令四·1）。
 *
 * 覆盖三块（全是纯逻辑，不碰 Android/网络）：
 * ① 单飞：在途时不允许再开跑，收尾后按尾随标志补发一轮；
 * ② 尾随补发只发生在「成功 + 仍在采集」，失败不重试（防无网空转）；
 * ③ `accepted` 解析：正常值照收，幂等全挡时 0，缺字段/脏体/负数一律 0。
 */
class FlushGateTest {

    // ① 单飞：flushing=true 时不许并发开第二个上报线程
    @Test
    fun canStart_onlyWhenNoInflight() {
        assertTrue(FlushGate.canStart(flushing = false))
        assertFalse(FlushGate.canStart(flushing = true))
    }

    // ② 尾随补发：待发 + 成功 + 采集态，三条全真才补
    @Test
    fun tailFlush_onlyAfterSuccessWhileRunning() {
        assertTrue(FlushGate.shouldTailFlush(pending = true, succeeded = true, running = true))
        assertFalse(FlushGate.shouldTailFlush(pending = false, succeeded = true, running = true))
        assertFalse(FlushGate.shouldTailFlush(pending = true, succeeded = false, running = true),
            "失败不补发：无网夜空转打点，交给下个 tick")
        assertFalse(FlushGate.shouldTailFlush(pending = true, succeeded = true, running = false))
    }

    // ③ accepted 正常解析（后端 app/main.py:1852 → {'ok': True, 'accepted': N}）
    @Test
    fun parseAccepted_readsInteger() {
        assertEquals(3, FlushGate.parseAccepted("""{"ok":true,"accepted":3}"""))
        assertEquals(1, FlushGate.parseAccepted("""{"accepted":1}"""))
        // 幂等全被服务端挡掉：同批重发仍 200，但 accepted=0 → 不许虚增
        assertEquals(0, FlushGate.parseAccepted("""{"ok":true,"accepted":0}"""))
        // 空 points 只保鲜 latest
        assertEquals(0, FlushGate.parseAccepted("""{"ok":true,"accepted":0}"""))
    }

    // ④ 容错：空体 / 非 JSON / 缺字段 / 负数 / 脏值一律 0，且不抛异常
    @Test
    fun parseAccepted_toleratesBadBodies() {
        assertEquals(0, FlushGate.parseAccepted(null))
        assertEquals(0, FlushGate.parseAccepted(""))
        assertEquals(0, FlushGate.parseAccepted("   "))
        assertEquals(0, FlushGate.parseAccepted("<html>502</html>"))
        assertEquals(0, FlushGate.parseAccepted("""{"ok":true}"""))
        assertEquals(0, FlushGate.parseAccepted("""{"accepted":-2}"""))
        assertEquals(0, FlushGate.parseAccepted("""{"accepted":"oops"}"""))
        assertEquals(0, FlushGate.parseAccepted("""{"accepted":null}"""))
    }

    // ⑤ 字符串数字按可解析处理（兼容把整数序列化成字符串的服务端）
    @Test
    fun parseAccepted_acceptsNumericString() {
        assertEquals(4, FlushGate.parseAccepted("""{"accepted":"4"}"""))
    }
}
