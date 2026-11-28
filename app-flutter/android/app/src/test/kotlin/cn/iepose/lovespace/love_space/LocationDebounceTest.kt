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

    // ⑦ 自适应半径公式与等比例解锁边界（min 40m / median*1.5 / max 150m）
    @Test
    fun adaptiveRadius_scalesWithMedianAccuracyAndCapsAt150m() {
        val f10 = RawFix(baseLat, baseLng, 10.0, 0.0, 0L)
        val f40 = RawFix(baseLat, baseLng, 40.0, 0.0, 0L)
        val f80 = RawFix(baseLat, baseLng, 80.0, 0.0, 0L)
        val f120 = RawFix(baseLat, baseLng, 120.0, 0.0, 0L)

        assertEquals(40.0, LocationDebouncer.adaptiveLockRadiusMeters(listOf(f10)), 1e-6)
        assertEquals(80.0, LocationDebouncer.adaptiveUnlockRadiusMeters(40.0), 1e-6)

        assertEquals(60.0, LocationDebouncer.adaptiveLockRadiusMeters(listOf(f40)), 1e-6)
        assertEquals(120.0, LocationDebouncer.adaptiveUnlockRadiusMeters(60.0), 1e-6)

        assertEquals(120.0, LocationDebouncer.adaptiveLockRadiusMeters(listOf(f10, f80, f120)), 1e-6)
        assertEquals(150.0, LocationDebouncer.adaptiveLockRadiusMeters(listOf(f120, f120, f120)), 1e-6)
        assertEquals(300.0, LocationDebouncer.adaptiveUnlockRadiusMeters(150.0), 1e-6)

        // End-to-end: 3 fixes spaced ~55m apart with acc=45m (radius=67.5m, unlock=135m).
        val debouncer = LocationDebouncer()
        val t0 = 1_700_000_000_000L
        val p1 = offsetMeters(baseLat, baseLng, 0.0, 0.0)
        val p2 = offsetMeters(baseLat, baseLng, 55.0, 0.0)
        val p3 = offsetMeters(baseLat, baseLng, 25.0, 25.0)
        debouncer.process(RawFix(p1.first, p1.second, 45.0, 0.0, t0))
        debouncer.process(RawFix(p2.first, p2.second, 45.0, 0.0, t0 + 90_000L))
        val out3 = debouncer.process(RawFix(p3.first, p3.second, 45.0, 0.0, t0 + 180_000L))
        assertTrue(out3 is DebounceOutcome.Emit && out3.isAnchor)
        assertEquals(DebounceState.STATIONARY_LOCKED, debouncer.state)
        assertEquals(67.5, debouncer.activeLockRadiusM, 1e-6)
        assertEquals(135.0, debouncer.activeUnlockRadiusM, 1e-6)

        // 120m away (>80m baseline, <=135m adaptive unlock) must remain locked.
        val anchor = debouncer.anchor!!
        val p120 = offsetMeters(anchor.lat, anchor.lng, 120.0, 0.0)
        val o120 = debouncer.process(RawFix(p120.first, p120.second, 45.0, 0.0, t0 + 240_000L))
        assertTrue(o120 is DebounceOutcome.Drop && o120.reason == DropReason.STATIONARY_ABSORBED)
        assertEquals(DebounceState.STATIONARY_LOCKED, debouncer.state)

        // Two consecutive 140m fixes (>135m) unlock back to MOVING.
        val p140a = offsetMeters(anchor.lat, anchor.lng, 140.0, 0.0)
        val p140b = offsetMeters(anchor.lat, anchor.lng, 142.0, 0.0)
        val o140a = debouncer.process(RawFix(p140a.first, p140a.second, 45.0, 1.0, t0 + 270_000L))
        assertTrue(o140a is DebounceOutcome.Drop)
        val o140b = debouncer.process(RawFix(p140b.first, p140b.second, 45.0, 1.0, t0 + 300_000L))
        assertTrue(o140b is DebounceOutcome.Emit)
        assertEquals(DebounceState.MOVING, debouncer.state)
    }

    // ⑧ 必测合成轨迹 ①：静止散布（σ≈80m、30 分钟）须锁定且上报收敛到锚点 + 心跳
    @Test
    fun stationaryScatter_sigma80m_30min_locksAndConvergesToAnchorAndHeartbeat() {
        val debouncer = LocationDebouncer()
        val rng = Random(20261128)
        val sigmaXY = 80.0 / kotlin.math.sqrt(2.0) // 2D radial RMS ≈ 80m
        val inputs = ArrayList<RawFix>(60)
        val emitted = ArrayList<DebounceOutcome.Emit>()
        val t0 = 1_700_000_000_000L

        fun nextGaussian(): Double {
            val u1 = rng.nextDouble().coerceAtLeast(1e-12)
            val u2 = rng.nextDouble()
            return kotlin.math.sqrt(-2.0 * kotlin.math.ln(u1)) * cos(2.0 * PI * u2)
        }

        for (i in 0 until 60) {
            val northM = nextGaussian() * sigmaXY
            val eastM = nextGaussian() * sigmaXY
            val pos = offsetMeters(baseLat, baseLng, northM, eastM)
            val acc = 45.0 + (i % 6) // 45..50m weak-signal optimistic accuracy
            val fix = RawFix(pos.first, pos.second, acc, 0.0, t0 + i * 30_000L)
            inputs.add(fix)
            val out = debouncer.process(fix)
            if (out is DebounceOutcome.Emit) {
                emitted.add(out)
            }
        }

        assertEquals(DebounceState.STATIONARY_LOCKED, debouncer.state)
        assertTrue("Expected at least 1 anchor lock, got ${debouncer.anchorLockCount}", debouncer.anchorLockCount >= 1)
        assertTrue("Expected sharp emission reduction, got ${emitted.size}/60", emitted.size <= 20)

        val anchor = debouncer.anchor!!
        assertTrue(
            "Anchor must come from actual sampled fixes",
            inputs.any { it.lat == anchor.lat && it.lng == anchor.lng },
        )

        // Heartbeat fixes after lock stay pinned exactly to the locked anchor with speed=0.0.
        val hb1 = debouncer.heartbeatFix(t0 + 15 * 60_000L)!!
        val hb2 = debouncer.heartbeatFix(t0 + 30 * 60_000L)!!
        assertEquals(anchor.lat, hb1.lat, 0.0)
        assertEquals(anchor.lng, hb1.lng, 0.0)
        assertEquals(0.0, hb1.speed!!, 0.0)
        assertEquals(anchor.lat, hb2.lat, 0.0)
        assertEquals(anchor.lng, hb2.lng, 0.0)
    }

    // ⑨ 必测合成轨迹 ②：慢速步行（1 m/s、σ≈30m 噪声）不许被永久锁住，全程位置误差有界、里程误差 ≤5%
    @Test
    fun slowWalk_1mps_sigma30m_neverPermanentlyLocked_boundedErrorAndLengthWithin5Pct() {
        val debouncer = LocationDebouncer()
        val rng = Random(20261127)
        val t0 = 1_700_000_000_000L
        val stepSec = 30
        val count = 61 // 30 minutes = 1800m true distance
        val sigmaXY = 30.0 / kotlin.math.sqrt(2.0)
        val rho = 0.92
        val innovScale = kotlin.math.sqrt(1.0 - rho * rho)

        fun nextGaussian(): Double {
            val u1 = rng.nextDouble().coerceAtLeast(1e-12)
            val u2 = rng.nextDouble()
            return kotlin.math.sqrt(-2.0 * kotlin.math.ln(u1)) * cos(2.0 * PI * u2)
        }

        var errN = 0.0
        var errE = 0.0
        val emitted = ArrayList<RawFix>()
        val trueCoords = ArrayList<Pair<Double, Double>>(count)

        for (i in 0 until count) {
            errN = rho * errN + innovScale * nextGaussian() * sigmaXY
            errE = rho * errE + innovScale * nextGaussian() * sigmaXY
            val trueEastM = i * stepSec * 1.0
            val truePos = offsetMeters(baseLat, baseLng, 0.0, trueEastM)
            trueCoords.add(truePos)
            val noisyPos = offsetMeters(baseLat, baseLng, errN, trueEastM + errE)
            val acc = 28.0 + (i % 5) * 1.5 // 28..34m
            val fix = RawFix(noisyPos.first, noisyPos.second, acc, 1.0, t0 + i * stepSec * 1000L)
            val out = debouncer.process(fix)
            if (out is DebounceOutcome.Emit) {
                emitted.add(out.fix)
            }
        }

        // Must NOT be permanently locked at the end of a 1 m/s walk.
        assertEquals(DebounceState.MOVING, debouncer.state)
        assertTrue("Expected majority of walk fixes emitted, got ${emitted.size}/$count", emitted.size >= 50)

        // Position error vs ground truth at every emitted timestamp must stay bounded.
        var maxPosErrM = 0.0
        for (p in emitted) {
            val idx = ((p.timeMs - t0) / (stepSec * 1000L)).toInt().coerceIn(0, count - 1)
            val truth = trueCoords[idx]
            val errM = LocationDebouncer.haversineMeters(p.lat, p.lng, truth.first, truth.second)
            if (errM > maxPosErrM) maxPosErrM = errM
        }
        assertTrue("Max position error ${maxPosErrM}m exceeded 120m bound", maxPosErrM <= 120.0)

        // Emitted distance error vs true 1800m walk must be <= 5%.
        var outDistM = 0.0
        for (k in 1 until emitted.size) {
            outDistM += LocationDebouncer.haversineMeters(
                emitted[k - 1].lat,
                emitted[k - 1].lng,
                emitted[k].lat,
                emitted[k].lng,
            )
        }
        val trueDistM = (count - 1) * stepSec * 1.0
        val errPct = kotlin.math.abs(outDistM - trueDistM) / trueDistM
        assertTrue(
            "Slow-walk mileage error ${(errPct * 1000).roundToInt() / 10.0}% (out=$outDistM vs true=$trueDistM) exceeded 5%",
            errPct <= 0.05,
        )
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
