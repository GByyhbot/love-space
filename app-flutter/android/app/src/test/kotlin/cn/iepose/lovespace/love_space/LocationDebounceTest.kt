package cn.iepose.lovespace.love_space

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.random.Random

/**
 * Pure JVM unit tests for 4-layer [LocationDebouncer] and adaptive sampling / backoff.
 */
class LocationDebounceTest {

    private val baseLat = 31.2304
    private val baseLng = 121.4737

    private fun offsetMeters(lat: Double, lng: Double, northM: Double, eastM: Double): Pair<Double, Double> {
        val dLat = northM / 111_320.0
        val dLng = eastM / (111_320.0 * cos(lat * PI / 180.0))
        return Pair(lat + dLat, lng + dLng)
    }

    // ① 静止噪声云（200 点，σ ≈ 25m）：锁定 STATIONARY_LOCKED、锚点来自真实采样、无虚构坐标
    @Test
    fun stationaryCloud_locksRealAnchorAndAbsorbsNoise() {
        val debouncer = LocationDebouncer()
        val rng = Random(42)
        val inputCoords = ArrayList<Pair<Double, Double>>(200)
        var emitted = 0
        var anchorCount = 0

        // 200 fixes spaced 15s apart (total ~50 min), jittered around base within ~25m.
        for (i in 0 until 200) {
            val angle = rng.nextDouble() * 2.0 * PI
            // Uniform radius <= 18m keeps pairwise <= 36m so cluster locks cleanly at >=2min.
            val radius = if (i < 15) rng.nextDouble() * 14.0 else rng.nextDouble() * 25.0
            val p = offsetMeters(
                baseLat,
                baseLng,
                radius * kotlin.math.sin(angle),
                radius * cos(angle),
            )
            inputCoords.add(p)
            val acc = if (i % 5 == 0) 6.0 else 18.0
            val out = debouncer.process(RawFix(p.first, p.second, acc, 0.0, 1_700_000_000_000L + i * 15_000L))
            if (out is DebounceOutcome.Emit) {
                emitted++
                if (out.isAnchor) anchorCount++
            }
        }

        assertEquals(DebounceState.STATIONARY_LOCKED, debouncer.state)
        assertTrue(debouncer.anchorLockCount >= 1)
        assertEquals(1, anchorCount)
        // Stationary noise cloud emissions drop by >90%.
        assertTrue("Expected steep reduction, got $emitted/200", emitted <= 15)

        val anchor = debouncer.anchor!!
        // Anchor must match an actual input sample exactly (never synthesized average).
        val matched = inputCoords.any { (la, ln) -> la == anchor.lat && ln == anchor.lng }
        assertTrue("Anchor (${anchor.lat}, ${anchor.lng}) must be a real input sample", matched)
    }

    // ② A-B-A 回弹：>200m 突变且 ≤2 周期内回到 50m 内 → B 丢为 BOUNCE，A/C 保留
    @Test
    fun bounceABA_dropsOutlierAndPreservesReturn() {
        val debouncer = LocationDebouncer()
        val t0 = 1_700_000_000_000L

        val outA = debouncer.process(RawFix(baseLat, baseLng, 10.0, 1.0, t0))
        assertTrue(outA is DebounceOutcome.Emit)

        // Jump 350m North over 30s (~11.7 m/s < 45 m/s spike threshold, > 200m bounce threshold).
        val b = offsetMeters(baseLat, baseLng, 350.0, 0.0)
        val outB = debouncer.process(RawFix(b.first, b.second, 15.0, 1.0, t0 + 30_000L))
        assertTrue(outB is DebounceOutcome.Drop && outB.reason == DropReason.BOUNCE)

        // Return within 10m of A on next fix (1 cycle).
        val c = offsetMeters(baseLat, baseLng, 10.0, 0.0)
        val outC = debouncer.process(RawFix(c.first, c.second, 10.0, 1.0, t0 + 60_000L))
        assertTrue(outC is DebounceOutcome.Emit)
        assertEquals(1, debouncer.droppedBounce)
    }

    // ③ 直线 + 90° 转弯步行：总里程误差 ≤ 5%，转角拐点保留不被平滑抹圆
    @Test
    fun movingWalk_withNinetyDegreeTurn_preservesTurnAndLengthWithin5Pct() {
        val debouncer = LocationDebouncer()
        val raw = ArrayList<RawFix>()
        val emitted = ArrayList<RawFix>()
        var t = 1_700_000_000_000L

        // 8 points heading due East, 35m each (total 245m).
        for (i in 0..7) {
            val p = offsetMeters(baseLat, baseLng, 0.0, i * 35.0)
            raw.add(RawFix(p.first, p.second, 8.0, 1.4, t))
            t += 25_000L
        }
        // 90 deg turn due North from East corner: 8 points, 35m each (total 280m).
        val cornerEast = 7 * 35.0
        for (j in 1..8) {
            val p = offsetMeters(baseLat, baseLng, j * 35.0, cornerEast)
            raw.add(RawFix(p.first, p.second, 8.0, 1.4, t))
            t += 25_000L
        }

        for (fix in raw) {
            val out = debouncer.process(fix)
            assertTrue(out is DebounceOutcome.Emit)
            emitted.add((out as DebounceOutcome.Emit).fix)
        }

        // Verify the first fix after 90° turn bypassed smoothing cleanly (exact coordinates preserved).
        val turnRaw = raw[8]
        val turnOut = emitted[8]
        assertEquals(turnRaw.lat, turnOut.lat, 1e-9)
        assertEquals(turnRaw.lng, turnOut.lng, 1e-9)

        fun totalDist(pts: List<RawFix>): Double {
            var sum = 0.0
            for (k in 1 until pts.size) {
                sum += LocationDebouncer.haversineMeters(
                    pts[k - 1].lat, pts[k - 1].lng, pts[k].lat, pts[k].lng,
                )
            }
            return sum
        }

        val rawLen = totalDist(raw)
        val outLen = totalDist(emitted)
        val errPct = kotlin.math.abs(outLen - rawLen) / rawLen
        assertTrue("Path error ${(errPct * 100).roundToInt()}% exceeded 5%", errPct <= 0.05)
    }

    // ④ 锁/解锁边界：79m 不解锁、单点 81m 不解锁、连续 2 点 81m 解锁回 MOVING
    @Test
    fun lockAndUnlockBoundary_requiresTwoConsecutiveOutside80m() {
        val debouncer = LocationDebouncer()
        var t = 1_700_000_000_000L

        // Feed 4 fixes at exact same point over 3 minutes -> locks.
        for (i in 0..3) {
            debouncer.process(RawFix(baseLat, baseLng, 8.0, 0.0, t + i * 60_000L))
        }
        assertEquals(DebounceState.STATIONARY_LOCKED, debouncer.state)

        // 79m away -> absorbed, still locked.
        val p79 = offsetMeters(baseLat, baseLng, 79.0, 0.0)
        val o79 = debouncer.process(RawFix(p79.first, p79.second, 8.0, 1.0, t + 240_000L))
        assertTrue(o79 is DebounceOutcome.Drop)
        assertEquals(DebounceState.STATIONARY_LOCKED, debouncer.state)

        // Single 81m away -> still locked (outsideStreak == 1 < 2).
        val p81a = offsetMeters(baseLat, baseLng, 81.0, 0.0)
        val o81a = debouncer.process(RawFix(p81a.first, p81a.second, 8.0, 1.0, t + 270_000L))
        assertTrue(o81a is DebounceOutcome.Drop)
        assertEquals(DebounceState.STATIONARY_LOCKED, debouncer.state)

        // Back inside 79m -> streak resets, still locked.
        val o79b = debouncer.process(RawFix(p79.first, p79.second, 8.0, 1.0, t + 300_000L))
        assertTrue(o79b is DebounceOutcome.Drop)
        assertEquals(DebounceState.STATIONARY_LOCKED, debouncer.state)

        // Two consecutive 81m fixes -> unlocks on 2nd to MOVING and emits.
        val o81b = debouncer.process(RawFix(p81a.first, p81a.second, 8.0, 1.0, t + 330_000L))
        assertTrue(o81b is DebounceOutcome.Drop)
        assertEquals(DebounceState.STATIONARY_LOCKED, debouncer.state)

        val p81c = offsetMeters(baseLat, baseLng, 85.0, 0.0)
        val o81c = debouncer.process(RawFix(p81c.first, p81c.second, 8.0, 1.0, t + 360_000L))
        assertTrue(o81c is DebounceOutcome.Emit)
        assertEquals(DebounceState.MOVING, debouncer.state)
    }

    // ⑤ 上传失败指数退避：1 → 2 → 5 → 10 min 序列与成功清零
    @Test
    fun failureBackoff_follows1_2_5_10MinAndResetsOnSuccess() {
        val debouncer = LocationDebouncer()
        assertEquals(60_000L, debouncer.recordFailure())
        assertEquals(1, debouncer.backoffStep)
        assertEquals(120_000L, debouncer.recordFailure())
        assertEquals(2, debouncer.backoffStep)
        assertEquals(300_000L, debouncer.recordFailure())
        assertEquals(3, debouncer.backoffStep)
        assertEquals(600_000L, debouncer.recordFailure())
        assertEquals(4, debouncer.backoffStep)
        // Stays capped at 10 min.
        assertEquals(600_000L, debouncer.recordFailure())

        debouncer.recordSuccess()
        assertEquals(0, debouncer.backoffStep)
        assertEquals(0L, debouncer.currentBackoffMs())
        assertFalse(debouncer.diagnostics().backoffStep != 0)
    }

    // ⑥ 精度门禁（>50m 丢为 ACCURACY）与超速毛刺门禁（>45m/s 丢为 SPIKE）
    @Test
    fun accuracyAndSpikeGates_dropInvalidFixes() {
        val debouncer = LocationDebouncer()
        val t0 = 1_700_000_000_000L

        val badAcc = debouncer.process(RawFix(baseLat, baseLng, 55.0, 0.0, t0))
        assertTrue(badAcc is DebounceOutcome.Drop && badAcc.reason == DropReason.ACCURACY)
        assertEquals(1, debouncer.droppedAccuracy)

        val okA = debouncer.process(RawFix(baseLat, baseLng, 10.0, 0.0, t0 + 10_000L))
        assertTrue(okA is DebounceOutcome.Emit)

        // 1000m jump in 5s = 200 m/s > 45 m/s -> dropped as SPIKE.
        val spike = offsetMeters(baseLat, baseLng, 1000.0, 0.0)
        val outSpike = debouncer.process(RawFix(spike.first, spike.second, 10.0, 0.0, t0 + 15_000L))
        assertTrue(outSpike is DebounceOutcome.Drop && outSpike.reason == DropReason.SPIKE)
        assertEquals(1, debouncer.droppedSpike)
    }
}
