package cn.iepose.lovespace.love_space

/**
 * Pure place-formatting and re-geocode throttling rules for Android Geocoder results.
 * Separated from Android framework types so it runs directly on JVM unit tests.
 */
internal object PlaceFormatter {
    private val genericNames = setOf("", "中国", "中华人民共和国")

    fun formatAddress(
        adminArea: String?,
        locality: String?,
        subLocality: String?,
        thoroughfare: String?,
        featureName: String?,
        addressLine: String?,
    ): String {
        val parts = ArrayList<String>(3)
        fun addUnique(raw: String?) {
            val s = raw?.trim() ?: return
            if (s.isEmpty() || s in genericNames) return
            if (s.all { it.isDigit() || it == '.' || it == '-' || it == ',' || it == ' ' }) return
            if (parts.any { it == s || it.contains(s) || s.contains(it) }) return
            parts.add(s)
        }
        val loc = locality?.trim()?.takeIf { it.isNotEmpty() && it !in genericNames }
        val adm = adminArea?.trim()?.takeIf { it.isNotEmpty() && it !in genericNames }
        addUnique(loc ?: adm)
        addUnique(subLocality)
        addUnique(thoroughfare)
        if (parts.size < 3) {
            val feat = featureName?.trim()
            if (!feat.isNullOrEmpty() && !feat.all { it.isDigit() }) {
                addUnique(feat)
            }
        }
        var joined = parts.joinToString("")
        if (joined.isEmpty()) {
            val line = addressLine?.trim()?.removePrefix("中国")?.trim().orEmpty()
            if (line.isNotEmpty() && line !in genericNames) {
                joined = line
            }
        }
        joined = joined.trim()
        return if (joined.length > 24) joined.substring(0, 24) else joined
    }

    fun shouldRegeocode(
        lastLat: Double?,
        lastLng: Double?,
        lastAtMs: Long,
        lat: Double,
        lng: Double,
        nowMs: Long,
    ): Boolean {
        if (lastLat == null || lastLng == null || lastAtMs <= 0L) return true
        if (nowMs - lastAtMs >= 10 * 60_000L) return true
        val dLat = (lat - lastLat) * 111_320.0
        val avgLatRad = Math.toRadians((lat + lastLat) * 0.5)
        val dLng = (lng - lastLng) * 111_320.0 * kotlin.math.cos(avgLatRad)
        return kotlin.math.hypot(dLat, dLng) >= 150.0
    }
}

/**
 * 2.8.7 全量施工令 · 应用使用采集的**纯逻辑**（不碰 Android API，JVM 单测直测）。
 *
 * 原生侧只做「取事件 → 配对 → 折叠 → 脱敏 → 投递」，不做任何网络与存储
 * （上行仍在 Dart 的文件队列，红线 2/3 不变）。
 *
 * 🔴 会话配对必须**增量**：`UsageStatsManager.queryEvents` 是按游标拉的，
 * 一次拉取可能只有 PAUSED 没有 RESUMED（跨了上一次拉取）。所以「进行中的
 * 会话」要作为状态跨调用保存（进程内字段 + SharedPreferences），否则每次
 * 拉取都会丢一段会话。
 */
internal object UsageGates {

    /** 一条原始使用事件（RESUMED / PAUSED）。 */
    data class Raw(val pkg: String, val ts: Long, val resumed: Boolean)

    /** 一个已闭合的会话（end 必非空）。 */
    data class Session(val pkg: String, val start: Long, val end: Long) {
        val durSec: Long get() = (end - start) / 1000
    }

    /** 跨调用保留的「进行中会话」。 */
    data class Open(val pkg: String, val start: Long)

    data class PairResult(
        val sessions: List<Session>,
        val open: Open?,
        val maxTs: Long,
    )

    /** 事件值常量：RESUMED=1 / PAUSED=2（ACTIVITY_RESUMED 与旧 MOVE_TO_FOREGROUND 同值）。 */
    const val EVENT_RESUMED = 1
    const val EVENT_PAUSED = 2

    /**
     * 增量配对：接着 [open] 继续把 [events] 折成会话。
     *
     * 规矩：同包 RESUMED 不新开；换包 RESUMED 视为上一个会话在此时结束；
     * PAUSED 只关同包会话（别包 PAUSED 忽略，防系统乱序时误关）。
     */
    fun pairIncremental(open: Open?, events: List<Raw>): PairResult {
        var cur = open
        val out = mutableListOf<Session>()
        var maxTs = 0L
        for (e in events) {
            if (e.ts > maxTs) maxTs = e.ts
            if (e.resumed) {
                if (cur != null && cur.pkg == e.pkg) continue
                if (cur != null && e.ts > cur.start) {
                    out += Session(cur.pkg, cur.start, e.ts)
                }
                cur = Open(e.pkg, e.ts)
            } else {
                if (cur != null && cur.pkg == e.pkg) {
                    if (e.ts > cur.start) out += Session(cur.pkg, cur.start, e.ts)
                    cur = null
                }
            }
        }
        return PairResult(out, cur, maxTs)
    }

    /** 折叠口径：<10 秒的切换在 fold_short 开时端侧直接丢（不入队）。 */
    fun shouldDrop(sec: Long, foldShort: Boolean): Boolean = foldShort && sec < 10

    /** 脱敏：命中敏感清单 → 哨兵包名 + masked 标记（真实包名不出设备）。 */
    fun mask(pkg: String, sensitive: Set<String>): Pair<String, Boolean> =
        if (sensitive.contains(pkg)) MASK_PKG to true else pkg to false

    const val MASK_PKG = "masked.other"
    const val MASK_APP = "其他应用"

    /** 「正在使用」节流：换应用立刻发，同应用 ≥30 秒才再发。 */
    fun shouldEmitNow(
        lastPkg: String,
        lastMs: Long,
        pkg: String,
        now: Long,
        throttleMs: Long = 30_000L,
    ): Boolean = pkg != lastPkg || now - lastMs >= throttleMs

    /** 坐标网格化（street 档端侧先圆整，服务端再兜一次）。 */
    fun gridRound(v: Double, step: Double = 0.005): Double {
        if (v.isNaN() || v.isInfinite()) return v
        return Math.round(v / step) * step
    }

    /**
     * 游标推进：取「本批最大事件时刻」，但不越过 now；没有事件时保持不动
     * （避免空拉把游标推到未来导致漏事件）。
     */
    fun advanceCursor(prev: Long, maxTs: Long, now: Long): Long {
        val cap = now
        val next = if (maxTs > 0) maxTs else prev
        return if (next > cap) cap else next
    }

    /** 进程死亡后恢复的进行中会话：超过 [maxAgeMs] 直接丢弃（不许凭空造 6 小时会话）。 */
    fun sanitizeOpen(open: Open?, now: Long, maxAgeMs: Long = 6 * 3600_000L): Open? {
        if (open == null) return null
        if (open.start <= 0 || now - open.start > maxAgeMs) return null
        return open
    }
}
