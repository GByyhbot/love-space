package cn.iepose.lovespace.love_space

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Pure-Kotlin 4-layer location debouncer & adaptive sampling configuration.
 * Zero android.* dependencies for deterministic JVM unit testing.
 */
object LocationDebounceConfig {
    // ── Layer 1: Accuracy gate ──
    const val MAX_ACCURACY_M = 50.0

    // ── Layer 2: Spike & A-B-A bounce rejection ──
    const val MAX_IMPLIED_SPEED_MPS = 45.0
    const val BOUNCE_DEVIATION_M = 200.0
    const val BOUNCE_RETURN_M = 50.0
    const val BOUNCE_MAX_CYCLES = 2

    // ── Layer 3: Stationary anchor lock ──
    const val LOCK_MIN_POINTS = 3
    const val LOCK_MAX_PAIRWISE_M = 40.0
    const val LOCK_MIN_SPAN_MS = 2 * 60_000L
    const val UNLOCK_RADIUS_M = 80.0
    const val UNLOCK_CONSECUTIVE_POINTS = 2

    // ── Layer 4: Moving lightweight smoother ──
    const val SMOOTH_WINDOW_SIZE = 3
    val SMOOTH_WEIGHTS = doubleArrayOf(0.05, 0.15, 0.80)
    const val TURN_BYPASS_DEG = 60.0

    // ── Adaptive sampling & failure backoff ──
    const val MOVING_MIN_TIME_MS = 30_000L
    const val MOVING_MIN_DISTANCE_M = 30f
    const val STATIONARY_HEARTBEAT_MS = 15 * 60_000L
    val BACKOFF_STEPS_MS = longArrayOf(60_000L, 120_000L, 300_000L, 600_000L)
}

enum class DebounceState {
    MOVING,
    STATIONARY_LOCKED,
}

enum class DropReason {
    ACCURACY,
    SPIKE,
    BOUNCE,
    STATIONARY_ABSORBED,
}

data class RawFix(
    val lat: Double,
    val lng: Double,
    val acc: Double,
    val speed: Double?,
    val timeMs: Long,
)

data class DebounceDiagnostics(
    val state: DebounceState,
    val anchorLockCount: Int,
    val droppedAccuracy: Int,
    val droppedSpike: Int,
    val droppedBounce: Int,
    val droppedStationary: Int,
    val backoffStep: Int,
    val backoffDelayMs: Long,
)

sealed class DebounceOutcome {
    data class Emit(
        val fix: RawFix,
        val state: DebounceState,
        val isAnchor: Boolean = false,
    ) : DebounceOutcome()

    data class Drop(
        val reason: DropReason,
        val state: DebounceState,
    ) : DebounceOutcome()
}

/**
 * Four-layer location debouncer:
 * 1) Accuracy gate (drop acc > 50m)
 * 2) Spike (> 45 m/s) & A-B-A bounce (> 200m returning <= 50m within <= 2 cycles)
 * 3) Stationary anchor lock (>= 3 pairwise <= 40m over >= 2min; real-sample anchor
 *    closest to 1/acc^2 centroid; immutable until 2 consecutive fixes > 80m)
 * 4) Moving 3-point weighted smoother with > 60deg turn bypass
 */
class LocationDebouncer {
    var state: DebounceState = DebounceState.MOVING
        private set

    var anchor: RawFix? = null
        private set

    var anchorLockCount: Int = 0
        private set

    var droppedAccuracy: Int = 0
        private set

    var droppedSpike: Int = 0
        private set

    var droppedBounce: Int = 0
        private set

    var droppedStationary: Int = 0
        private set

    var backoffStep: Int = 0
        private set

    private var lastReliable: RawFix? = null
    private var outsideStreak: Int = 0
    private var pendingAnchor: RawFix? = null
    private var postTurnBypassRemaining: Int = 0
    private val pendingBounce = ArrayList<RawFix>(LocationDebounceConfig.BOUNCE_MAX_CYCLES)
    private val clusterWindow = ArrayList<RawFix>()
    private val smoothWindow = ArrayList<RawFix>(LocationDebounceConfig.SMOOTH_WINDOW_SIZE)

    fun reset() {
        state = DebounceState.MOVING
        anchor = null
        anchorLockCount = 0
        droppedAccuracy = 0
        droppedSpike = 0
        droppedBounce = 0
        droppedStationary = 0
        backoffStep = 0
        lastReliable = null
        outsideStreak = 0
        pendingAnchor = null
        postTurnBypassRemaining = 0
        pendingBounce.clear()
        clusterWindow.clear()
        smoothWindow.clear()
    }

    fun diagnostics(): DebounceDiagnostics = DebounceDiagnostics(
        state = state,
        anchorLockCount = anchorLockCount,
        droppedAccuracy = droppedAccuracy,
        droppedSpike = droppedSpike,
        droppedBounce = droppedBounce,
        droppedStationary = droppedStationary,
        backoffStep = backoffStep,
        backoffDelayMs = currentBackoffMs(),
    )

    fun recordFailure(): Long {
        val steps = LocationDebounceConfig.BACKOFF_STEPS_MS
        val idx = backoffStep.coerceIn(0, steps.lastIndex)
        val delay = steps[idx]
        if (backoffStep < steps.size) {
            backoffStep++
        }
        return delay
    }

    fun recordSuccess() {
        backoffStep = 0
    }

    fun currentBackoffMs(): Long {
        if (backoffStep <= 0) return 0L
        val steps = LocationDebounceConfig.BACKOFF_STEPS_MS
        return steps[(backoffStep - 1).coerceIn(0, steps.lastIndex)]
    }

    fun heartbeatFix(nowMs: Long): RawFix? {
        val lockedAnchor = anchor ?: return null
        if (state != DebounceState.STATIONARY_LOCKED) return null
        return lockedAnchor.copy(speed = 0.0, timeMs = nowMs)
    }

    fun process(fix: RawFix): DebounceOutcome {
        // Layer 1: accuracy & coordinate validity gate.
        if (!fix.lat.isFinite() ||
            !fix.lng.isFinite() ||
            !fix.acc.isFinite() ||
            fix.acc <= 0.0 ||
            fix.acc > LocationDebounceConfig.MAX_ACCURACY_M
        ) {
            droppedAccuracy++
            return DebounceOutcome.Drop(DropReason.ACCURACY, state)
        }

        // Layer 2a: spike gate against last reliable fix (also shields stationary lock).
        val ref = lastReliable
        if (ref != null) {
            val dtSec = (fix.timeMs - ref.timeMs) / 1000.0
            val dist = haversineMeters(ref.lat, ref.lng, fix.lat, fix.lng)
            if (dtSec > 0.0 && (dist / dtSec) > LocationDebounceConfig.MAX_IMPLIED_SPEED_MPS) {
                droppedSpike++
                return DebounceOutcome.Drop(DropReason.SPIKE, state)
            }
        }

        // Layer 3 (when locked): immutable anchor until 2 consecutive fixes > 80m.
        if (state == DebounceState.STATIONARY_LOCKED) {
            val lockedAnchor = anchor
            if (lockedAnchor != null) {
                val distFromAnchor = haversineMeters(
                    lockedAnchor.lat,
                    lockedAnchor.lng,
                    fix.lat,
                    fix.lng,
                )
                if (distFromAnchor <= LocationDebounceConfig.UNLOCK_RADIUS_M) {
                    outsideStreak = 0
                    lastReliable = fix
                    droppedStationary++
                    return DebounceOutcome.Drop(DropReason.STATIONARY_ABSORBED, state)
                }
                outsideStreak++
                if (outsideStreak < LocationDebounceConfig.UNLOCK_CONSECUTIVE_POINTS) {
                    droppedStationary++
                    return DebounceOutcome.Drop(DropReason.STATIONARY_ABSORBED, state)
                }
                // Unlocked by >= 2 consecutive fixes outside 80m.
                state = DebounceState.MOVING
                anchor = null
                outsideStreak = 0
                pendingAnchor = null
                postTurnBypassRemaining = 0
                pendingBounce.clear()
                clusterWindow.clear()
                smoothWindow.clear()
                return emitMoving(fix)
            }
            state = DebounceState.MOVING
        }

        // Layer 2b: A-B-A bounce filter while moving.
        if (pendingBounce.isNotEmpty()) {
            val a = pendingAnchor
            if (a != null &&
                haversineMeters(a.lat, a.lng, fix.lat, fix.lng) <=
                LocationDebounceConfig.BOUNCE_RETURN_M
            ) {
                // Returned near A within allowed cycles: drop suspect B(s) cleanly and accept C.
                pendingAnchor = null
                pendingBounce.clear()
                lastReliable = a
            } else if (pendingBounce.size < LocationDebounceConfig.BOUNCE_MAX_CYCLES) {
                pendingBounce.add(fix)
                droppedBounce++
                return DebounceOutcome.Drop(DropReason.BOUNCE, state)
            } else {
                // Sustained move away from A: accept new baseline cleanly.
                pendingAnchor = null
                postTurnBypassRemaining = 0
                pendingBounce.clear()
                clusterWindow.clear()
                smoothWindow.clear()
            }
        } else if (ref != null &&
            haversineMeters(ref.lat, ref.lng, fix.lat, fix.lng) >
            LocationDebounceConfig.BOUNCE_DEVIATION_M
        ) {
            pendingAnchor = ref
            pendingBounce.add(fix)
            droppedBounce++
            return DebounceOutcome.Drop(DropReason.BOUNCE, state)
        }

        return emitMoving(fix)
    }

    private fun emitMoving(fix: RawFix): DebounceOutcome {
        // Layer 3 lock check: prune front if incoming point exceeds pairwise radius.
        while (clusterWindow.isNotEmpty() &&
            clusterWindow.any {
                haversineMeters(it.lat, it.lng, fix.lat, fix.lng) >
                    LocationDebounceConfig.LOCK_MAX_PAIRWISE_M
            }
        ) {
            clusterWindow.removeAt(0)
        }
        clusterWindow.add(fix)

        if (clusterWindow.size >= LocationDebounceConfig.LOCK_MIN_POINTS) {
            val spanMs = clusterWindow.last().timeMs - clusterWindow.first().timeMs
            if (spanMs >= LocationDebounceConfig.LOCK_MIN_SPAN_MS &&
                allPairwiseWithin(clusterWindow, LocationDebounceConfig.LOCK_MAX_PAIRWISE_M)
            ) {
                val realAnchor = selectRealAnchor(clusterWindow)
                state = DebounceState.STATIONARY_LOCKED
                anchor = realAnchor
                anchorLockCount++
                outsideStreak = 0
                lastReliable = realAnchor
                smoothWindow.clear()
                return DebounceOutcome.Emit(realAnchor, state, isAnchor = true)
            }
        }

        // Layer 4: 3-point weighted moving smoother (bypassed on sharp turns > 60 deg).
        lastReliable = fix
        if (smoothWindow.size >= LocationDebounceConfig.SMOOTH_WINDOW_SIZE) {
            smoothWindow.removeAt(0)
        }
        smoothWindow.add(fix)

        // Point right after a detected corner is also emitted raw (no smoothing pull-in).
        if (postTurnBypassRemaining > 0) {
            postTurnBypassRemaining--
            return DebounceOutcome.Emit(fix, state, isAnchor = false)
        }

        if (smoothWindow.size < LocationDebounceConfig.SMOOTH_WINDOW_SIZE) {
            return DebounceOutcome.Emit(fix, state, isAnchor = false)
        }

        val p0 = smoothWindow[0]
        val p1 = smoothWindow[1]
        val p2 = smoothWindow[2]
        if (haversineMeters(p0.lat, p0.lng, p1.lat, p1.lng) >= 0.5 &&
            haversineMeters(p1.lat, p1.lng, p2.lat, p2.lng) >= 0.5
        ) {
            val b1 = initialBearingDeg(p0.lat, p0.lng, p1.lat, p1.lng)
            val b2 = initialBearingDeg(p1.lat, p1.lng, p2.lat, p2.lng)
            val delta = abs(((b2 - b1 + 540.0) % 360.0) - 180.0)
            if (delta > LocationDebounceConfig.TURN_BYPASS_DEG) {
                // Keep turn corner unsmoothed & reset tail so previous branch does not pull next segment.
                smoothWindow.clear()
                smoothWindow.add(p2)
                postTurnBypassRemaining = 1
                return DebounceOutcome.Emit(p2, state, isAnchor = false)
            }
        }

        val w = LocationDebounceConfig.SMOOTH_WEIGHTS
        val sLat = w[0] * p0.lat + w[1] * p1.lat + w[2] * p2.lat
        val sLng = w[0] * p0.lng + w[1] * p1.lng + w[2] * p2.lng
        return DebounceOutcome.Emit(
            p2.copy(lat = sLat, lng = sLng),
            state,
            isAnchor = false,
        )
    }

    private fun allPairwiseWithin(points: List<RawFix>, maxDistM: Double): Boolean {
        for (i in points.indices) {
            for (j in i + 1 until points.size) {
                if (haversineMeters(
                        points[i].lat,
                        points[i].lng,
                        points[j].lat,
                        points[j].lng,
                    ) > maxDistM
                ) {
                    return false
                }
            }
        }
        return true
    }

    /**
     * Selects an actual sampled fix from [cluster] closest to the 1/acc^2 centroid
     * (never synthesizing averaged coordinates for locked anchors).
     */
    private fun selectRealAnchor(cluster: List<RawFix>): RawFix {
        var sumW = 0.0
        var sumLat = 0.0
        var sumLng = 0.0
        for (p in cluster) {
            val accSafe = p.acc.coerceAtLeast(1.0)
            val weight = 1.0 / (accSafe * accSafe)
            sumW += weight
            sumLat += weight * p.lat
            sumLng += weight * p.lng
        }
        val cLat = sumLat / sumW
        val cLng = sumLng / sumW

        var best = cluster.first()
        var bestDist = haversineMeters(best.lat, best.lng, cLat, cLng)
        for (i in 1 until cluster.size) {
            val candidate = cluster[i]
            val d = haversineMeters(candidate.lat, candidate.lng, cLat, cLng)
            if (d < bestDist - 1e-6 || (abs(d - bestDist) <= 1e-6 && candidate.acc < best.acc)) {
                best = candidate
                bestDist = d
            }
        }
        return best
    }

    companion object {
        fun haversineMeters(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double {
            val r = 6371000.0
            val dLat = (lat2 - lat1) * PI / 180.0
            val dLng = (lng2 - lng1) * PI / 180.0
            val phi1 = lat1 * PI / 180.0
            val phi2 = lat2 * PI / 180.0
            val s = sin(dLat / 2.0) * sin(dLat / 2.0) +
                cos(phi1) * cos(phi2) * sin(dLng / 2.0) * sin(dLng / 2.0)
            return r * 2.0 * atan2(sqrt(s), sqrt((1.0 - s).coerceAtLeast(0.0)))
        }

        fun initialBearingDeg(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double {
            val phi1 = lat1 * PI / 180.0
            val phi2 = lat2 * PI / 180.0
            val dLambda = (lng2 - lng1) * PI / 180.0
            val y = sin(dLambda) * cos(phi2)
            val x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(dLambda)
            return ((atan2(y, x) * 180.0 / PI) + 360.0) % 360.0
        }
    }
}
