package cn.iepose.lovespace.love_space

import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.amap.api.location.AMapLocation
import com.amap.api.location.AMapLocationClient
import com.amap.api.location.AMapLocationClientOption
import com.amap.api.location.AMapLocationListener
import java.io.File
import java.util.Locale
import java.util.concurrent.Executors
import kotlin.math.roundToInt

/**
 * Pure-Kotlin gate & NDJSON formatter for the AMap shadow evaluation chain.
 * Zero android.* dependencies so JVM unit tests verify alignment, throttling,
 * coordinate-system tagging (GCJ-02), and distance calculation deterministically.
 */
internal object AmapShadowGate {
    const val MIN_SAMPLE_GAP_MS = 25_000L
    const val CACHE_REUSE_WINDOW_MS = 10_000L
    const val REQUEST_TIMEOUT_MS = 8_500L
    const val MAX_LOG_BYTES = 4L * 1024 * 1024
    const val COORD_SYS_GCJ02 = "GCJ-02"

    fun locationTypeName(code: Int): String = when (code) {
        0 -> "unknown"
        1 -> "gps"
        2 -> "same_req"
        4 -> "fix_cache"
        5 -> "wifi"
        6 -> "cell"
        8 -> "offline"
        9 -> "last_cache"
        11 -> "coarse"
        else -> "type_$code"
    }

    fun shouldTriggerNewRequest(
        nowElapsedMs: Long,
        lastAttemptElapsedMs: Long,
        inFlight: Boolean,
        minGapMs: Long = MIN_SAMPLE_GAP_MS,
    ): Boolean {
        if (inFlight) return false
        if (lastAttemptElapsedMs <= 0L) return true
        return (nowElapsedMs - lastAttemptElapsedMs) >= minGapMs
    }

    fun isReusableCache(
        nowElapsedMs: Long,
        lastSuccessElapsedMs: Long,
        cacheWindowMs: Long = CACHE_REUSE_WINDOW_MS,
    ): Boolean = lastSuccessElapsedMs > 0L && (nowElapsedMs - lastSuccessElapsedMs) <= cacheWindowMs

    fun pairDistanceMeters(
        ok: Boolean,
        nativeLatGcj: Double,
        nativeLngGcj: Double,
        amapLatGcj: Double?,
        amapLngGcj: Double?,
    ): Double? {
        if (!ok || amapLatGcj == null || amapLngGcj == null) return null
        if (!nativeLatGcj.isFinite() || !nativeLngGcj.isFinite() ||
            !amapLatGcj.isFinite() || !amapLngGcj.isFinite()
        ) {
            return null
        }
        return LocationDebouncer.haversineMeters(nativeLatGcj, nativeLngGcj, amapLatGcj, amapLngGcj)
    }

    fun jsonEscape(raw: String?): String {
        if (raw.isNullOrEmpty()) return "\"\""
        val sb = StringBuilder(raw.length + 8)
        sb.append('"')
        for (ch in raw) {
            when (ch) {
                '\\' -> sb.append("\\\\")
                '"' -> sb.append("\\\"")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> if (ch < ' ') {
                    sb.append(String.format(Locale.US, "\\u%04x", ch.code))
                } else {
                    sb.append(ch)
                }
            }
        }
        sb.append('"')
        return sb.toString()
    }

    private fun fmtDouble(v: Double?, digits: Int = 7): String {
        if (v == null || !v.isFinite()) return "null"
        return String.format(Locale.US, "%.${digits}f", v)
    }

    fun formatPairedJsonLine(
        trigger: String,
        nativeTsMs: Long,
        nativeLatGcj: Double,
        nativeLngGcj: Double,
        nativeAcc: Double,
        nativeProvider: String,
        nativeSpeed: Double?,
        nativeDebounce: String,
        nativeState: String,
        amapOk: Boolean,
        amapTsMs: Long?,
        amapLatGcj: Double?,
        amapLngGcj: Double?,
        amapAcc: Double?,
        amapLocType: Int?,
        amapCoordType: String,
        amapErrCode: Int,
        amapErrInfo: String,
    ): String {
        val dtMs = if (amapTsMs != null) amapTsMs - nativeTsMs else null
        val distM = pairDistanceMeters(amapOk, nativeLatGcj, nativeLngGcj, amapLatGcj, amapLngGcj)
        val locTypeName = amapLocType?.let { locationTypeName(it) } ?: ""
        return buildString {
            append('{')
            append("\"coord_sys\":").append(jsonEscape(COORD_SYS_GCJ02))
            append(",\"trigger\":").append(jsonEscape(trigger))
            append(",\"native_ts_ms\":").append(nativeTsMs)
            append(",\"native_lat\":").append(fmtDouble(nativeLatGcj, 7))
            append(",\"native_lng\":").append(fmtDouble(nativeLngGcj, 7))
            append(",\"native_acc\":").append(fmtDouble(nativeAcc, 2))
            append(",\"native_provider\":").append(jsonEscape(nativeProvider))
            append(",\"native_speed\":").append(fmtDouble(nativeSpeed, 2))
            append(",\"native_debounce\":").append(jsonEscape(nativeDebounce))
            append(",\"native_state\":").append(jsonEscape(nativeState))
            append(",\"amap_ok\":").append(amapOk)
            append(",\"amap_ts_ms\":").append(amapTsMs?.toString() ?: "null")
            append(",\"amap_dt_ms\":").append(dtMs?.toString() ?: "null")
            append(",\"amap_lat\":").append(fmtDouble(amapLatGcj, 7))
            append(",\"amap_lng\":").append(fmtDouble(amapLngGcj, 7))
            append(",\"amap_acc\":").append(fmtDouble(amapAcc, 2))
            append(",\"amap_loc_type\":").append(amapLocType?.toString() ?: "null")
            append(",\"amap_loc_type_name\":").append(jsonEscape(locTypeName))
            append(",\"amap_coord_type\":").append(jsonEscape(amapCoordType))
            append(",\"amap_err_code\":").append(amapErrCode)
            append(",\"amap_err_info\":").append(jsonEscape(amapErrInfo))
            append(",\"pair_dist_m\":").append(fmtDouble(distM, 2))
            append('}')
        }
    }
}

/**
 * 高德定位影子评估链（只记不用，与原生主链完全隔离）：
 * - 隐私合规沿用地图 SDK 的 updatePrivacyShow/Agree 链路；
 * - 采样时刻严格对齐原生回调/心跳，绝不自设高频定时器；
 * - 高德返回 GCJ-02 坐标，与原生端上转换后的 GCJ-02 同口径落盘对比；
 * - 仅写本机诊断文件 `peer-loc/amap-shadow-eval.jsonl`，不上传、不进报备、不改变采集状态。
 */
object AmapShadowEvaluator {
    private const val TAG = "amap-shadow"
    private const val LOG_REL_DIR = "peer-loc"
    private const val LOG_FILE_NAME = "amap-shadow-eval.jsonl"

    private data class NativeSample(
        val trigger: String,
        val tsMs: Long,
        val latGcj: Double,
        val lngGcj: Double,
        val acc: Double,
        val provider: String,
        val speed: Double?,
        val debounce: String,
        val state: String,
    )

    private data class CachedAmapFix(
        val elapsedMs: Long,
        val wallTsMs: Long,
        val latGcj: Double,
        val lngGcj: Double,
        val acc: Double,
        val locType: Int,
        val coordType: String,
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newSingleThreadExecutor()

    private var appCtx: Context? = null
    private var client: AMapLocationClient? = null
    private var enabled = false
    private var disabledReason = ""
    private var sdkVersion = ""

    private var inFlight = false
    private var lastAttemptElapsedMs = 0L
    private var lastSuccessElapsedMs = 0L
    private var lastCachedFix: CachedAmapFix? = null
    private var pendingSample: NativeSample? = null

    @Volatile private var attempts = 0
    @Volatile private var succeeded = 0
    @Volatile private var failed = 0
    @Volatile private var lastLocType = ""
    @Volatile private var lastAcc: Double? = null
    @Volatile private var lastErrCode = 0
    @Volatile private var lastPairDistM: Double? = null

    private val timeoutRunnable = Runnable {
        if (!inFlight) return@Runnable
        val sample = pendingSample
        pendingSample = null
        inFlight = false
        runCatching { client?.stopLocation() }
        if (sample != null) {
            recordResult(
                sample = sample,
                ok = false,
                amapTsMs = System.currentTimeMillis(),
                latGcj = null,
                lngGcj = null,
                acc = null,
                locType = null,
                coordType = "",
                errCode = -1,
                errInfo = "shadow_timeout",
            )
        }
    }

    private val listener = AMapLocationListener { loc ->
        mainHandler.removeCallbacks(timeoutRunnable)
        val sample = pendingSample
        pendingSample = null
        inFlight = false
        if (sample == null) return@AMapLocationListener
        handleAmapLocation(sample, loc)
    }

    fun ensurePrivacy(context: Context) {
        val ctx = context.applicationContext ?: context
        try {
            AMapLocationClient.updatePrivacyShow(ctx, true, true)
            AMapLocationClient.updatePrivacyAgree(ctx, true)
        } catch (t: Throwable) {
            android.util.Log.w(TAG, "updatePrivacy failed: ${t.message}")
        }
    }

    private fun readApiKey(context: Context): String? {
        return try {
            @Suppress("DEPRECATION")
            val info = context.packageManager.getApplicationInfo(
                context.packageName,
                PackageManager.GET_META_DATA,
            )
            info.metaData?.getString("com.amap.api.v2.apikey")?.trim()
        } catch (_: Throwable) {
            null
        }
    }

    @Synchronized
    fun start(context: Context) {
        val ctx = context.applicationContext ?: context
        appCtx = ctx
        if (client != null && enabled) return
        val key = readApiKey(ctx)
        if (key.isNullOrBlank()) {
            enabled = false
            disabledReason = "no_api_key"
            return
        }
        try {
            ensurePrivacy(ctx)
            val c = AMapLocationClient(ctx)
            val opt = AMapLocationClientOption().apply {
                setLocationMode(AMapLocationClientOption.AMapLocationMode.Hight_Accuracy)
                setOnceLocation(true)
                setOnceLocationLatest(false)
                setNeedAddress(false)
                setWifiScan(true)
                setWifiActiveScan(false)
                setLocationCacheEnable(false)
                setHttpTimeOut(8_000L)
                setMockEnable(false)
            }
            c.setLocationOption(opt)
            c.setLocationListener(listener)
            client = c
            enabled = true
            disabledReason = ""
            sdkVersion = runCatching { c.version }.getOrDefault("")
            android.util.Log.i(TAG, "shadow locator started (sdk=$sdkVersion)")
        } catch (t: Throwable) {
            enabled = false
            disabledReason = t.message ?: "init_failed"
            android.util.Log.w(TAG, "shadow locator start failed: $disabledReason")
        }
    }

    @Synchronized
    fun stop() {
        mainHandler.removeCallbacks(timeoutRunnable)
        inFlight = false
        pendingSample = null
        lastCachedFix = null
        lastAttemptElapsedMs = 0L
        lastSuccessElapsedMs = 0L
        enabled = false
        val c = client
        client = null
        if (c != null) {
            runCatching { c.stopLocation() }
            runCatching { c.unRegisterLocationListener(listener) }
            runCatching { c.onDestroy() }
        }
        android.util.Log.i(TAG, "shadow locator stopped")
    }

    fun sampleAligned(
        context: Context?,
        trigger: String,
        nativeTsMs: Long,
        nativeLatGcj: Double,
        nativeLngGcj: Double,
        nativeAcc: Double,
        nativeProvider: String,
        nativeSpeed: Double?,
        nativeDebounce: String,
        nativeState: String,
    ) {
        val ctx = context?.applicationContext ?: appCtx
        if (ctx != null) appCtx = ctx
        if (!enabled || client == null) return
        val sample = NativeSample(
            trigger = trigger,
            tsMs = nativeTsMs,
            latGcj = nativeLatGcj,
            lngGcj = nativeLngGcj,
            acc = nativeAcc,
            provider = nativeProvider,
            speed = nativeSpeed,
            debounce = nativeDebounce,
            state = nativeState,
        )
        val nowElapsed = SystemClock.elapsedRealtime()
        val cached = lastCachedFix
        if (cached != null && AmapShadowGate.isReusableCache(nowElapsed, cached.elapsedMs)) {
            attempts++
            recordResult(
                sample = sample,
                ok = true,
                amapTsMs = cached.wallTsMs,
                latGcj = cached.latGcj,
                lngGcj = cached.lngGcj,
                acc = cached.acc,
                locType = cached.locType,
                coordType = cached.coordType,
                errCode = 0,
                errInfo = "reused_recent",
            )
            return
        }
        if (!AmapShadowGate.shouldTriggerNewRequest(nowElapsed, lastAttemptElapsedMs, inFlight)) {
            return
        }
        val c = client ?: return
        inFlight = true
        lastAttemptElapsedMs = nowElapsed
        pendingSample = sample
        attempts++
        mainHandler.removeCallbacks(timeoutRunnable)
        mainHandler.postDelayed(timeoutRunnable, AmapShadowGate.REQUEST_TIMEOUT_MS)
        try {
            c.startLocation()
        } catch (t: Throwable) {
            mainHandler.removeCallbacks(timeoutRunnable)
            inFlight = false
            pendingSample = null
            recordResult(
                sample = sample,
                ok = false,
                amapTsMs = System.currentTimeMillis(),
                latGcj = null,
                lngGcj = null,
                acc = null,
                locType = null,
                coordType = "",
                errCode = -2,
                errInfo = t.message ?: "start_failed",
            )
        }
    }

    private fun handleAmapLocation(sample: NativeSample, loc: AMapLocation?) {
        if (loc == null) {
            recordResult(
                sample = sample,
                ok = false,
                amapTsMs = System.currentTimeMillis(),
                latGcj = null,
                lngGcj = null,
                acc = null,
                locType = null,
                coordType = "",
                errCode = -3,
                errInfo = "null_location",
            )
            return
        }
        if (loc.errorCode == 0) {
            val coordType = (loc.coordType ?: AmapShadowGate.COORD_SYS_GCJ02).uppercase(Locale.ROOT)
            val gcjLatLng = if (coordType == AMapLocation.COORD_TYPE_WGS84) {
                PeerLocNative.wgs84ToGcj02(loc.latitude, loc.longitude)
            } else {
                Pair(loc.latitude, loc.longitude)
            }
            val nowElapsed = SystemClock.elapsedRealtime()
            val wallTs = if (loc.time > 0L) loc.time else System.currentTimeMillis()
            val accVal = loc.accuracy.toDouble()
            lastSuccessElapsedMs = nowElapsed
            lastCachedFix = CachedAmapFix(
                elapsedMs = nowElapsed,
                wallTsMs = wallTs,
                latGcj = gcjLatLng.first,
                lngGcj = gcjLatLng.second,
                acc = accVal,
                locType = loc.locationType,
                coordType = coordType,
            )
            recordResult(
                sample = sample,
                ok = true,
                amapTsMs = wallTs,
                latGcj = gcjLatLng.first,
                lngGcj = gcjLatLng.second,
                acc = accVal,
                locType = loc.locationType,
                coordType = coordType,
                errCode = 0,
                errInfo = "",
            )
        } else {
            recordResult(
                sample = sample,
                ok = false,
                amapTsMs = System.currentTimeMillis(),
                latGcj = null,
                lngGcj = null,
                acc = null,
                locType = loc.locationType,
                coordType = loc.coordType ?: "",
                errCode = loc.errorCode,
                errInfo = loc.errorInfo ?: "",
            )
        }
    }

    private fun recordResult(
        sample: NativeSample,
        ok: Boolean,
        amapTsMs: Long?,
        latGcj: Double?,
        lngGcj: Double?,
        acc: Double?,
        locType: Int?,
        coordType: String,
        errCode: Int,
        errInfo: String,
    ) {
        if (ok) {
            succeeded++
            lastLocType = locType?.let { AmapShadowGate.locationTypeName(it) } ?: ""
            lastAcc = acc
            lastErrCode = 0
            lastPairDistM = AmapShadowGate.pairDistanceMeters(
                ok = true,
                nativeLatGcj = sample.latGcj,
                nativeLngGcj = sample.lngGcj,
                amapLatGcj = latGcj,
                amapLngGcj = lngGcj,
            )
        } else {
            failed++
            lastErrCode = errCode
        }
        val line = AmapShadowGate.formatPairedJsonLine(
            trigger = sample.trigger,
            nativeTsMs = sample.tsMs,
            nativeLatGcj = sample.latGcj,
            nativeLngGcj = sample.lngGcj,
            nativeAcc = sample.acc,
            nativeProvider = sample.provider,
            nativeSpeed = sample.speed,
            nativeDebounce = sample.debounce,
            nativeState = sample.state,
            amapOk = ok,
            amapTsMs = amapTsMs,
            amapLatGcj = latGcj,
            amapLngGcj = lngGcj,
            amapAcc = acc,
            amapLocType = locType,
            amapCoordType = coordType,
            amapErrCode = errCode,
            amapErrInfo = errInfo,
        )
        val ctx = appCtx ?: return
        ioExecutor.execute { appendLine(ctx, line) }
    }

    private fun logFile(context: Context): File {
        val base = context.getExternalFilesDir(null) ?: context.filesDir
        val dir = File(base, LOG_REL_DIR)
        if (!dir.exists()) dir.mkdirs()
        return File(dir, LOG_FILE_NAME)
    }

    private fun appendLine(context: Context, line: String) {
        try {
            val f = logFile(context)
            f.appendText("$line\n", Charsets.UTF_8)
            if (f.length() > AmapShadowGate.MAX_LOG_BYTES) {
                val bytes = f.readBytes()
                val half = bytes.size / 2
                var cut = half
                while (cut < bytes.size && bytes[cut] != '\n'.code.toByte()) {
                    cut++
                }
                val start = if (cut + 1 < bytes.size) cut + 1 else half
                f.writeBytes(bytes.copyOfRange(start, bytes.size))
            }
        } catch (t: Throwable) {
            android.util.Log.w(TAG, "appendLine failed: ${t.message}")
        }
    }

    fun diagnostics(context: Context?): Map<String, Any?> {
        val ctx = context?.applicationContext ?: appCtx
        val f = ctx?.let { logFile(it) }
        val exists = f != null && f.exists()
        return mapOf(
            "enabled" to enabled,
            "disabledReason" to disabledReason,
            "sdkVersion" to sdkVersion,
            "attempts" to attempts,
            "succeeded" to succeeded,
            "failed" to failed,
            "lastLocType" to lastLocType,
            "lastAcc" to lastAcc,
            "lastErrCode" to lastErrCode,
            "lastPairDistM" to lastPairDistM?.let { (it * 10.0).roundToInt() / 10.0 },
            "logPath" to (if (exists) f.absolutePath else ""),
            "logBytes" to (if (exists) f.length() else 0L),
        )
    }

    fun summaryLine(context: Context?): String {
        val ctx = context?.applicationContext ?: appCtx ?: return ""
        val f = logFile(ctx)
        if (!f.exists() && attempts == 0) return ""
        return "amapShadow enabled=$enabled sdk=$sdkVersion attempts=$attempts ok=$succeeded " +
            "fail=$failed lastType=$lastLocType lastAcc=$lastAcc log=${f.absolutePath} (${f.length()} B)"
    }

    fun exportLog(context: Context?): Map<String, Any?> {
        val ctx = context?.applicationContext ?: appCtx
        if (ctx == null) {
            return mapOf("path" to "", "bytes" to 0L, "lines" to 0, "content" to "")
        }
        val f = logFile(ctx)
        if (!f.exists()) {
            return mapOf("path" to f.absolutePath, "bytes" to 0L, "lines" to 0, "content" to "")
        }
        val text = runCatching { f.readText(Charsets.UTF_8) }.getOrDefault("")
        val lineCount = if (text.isEmpty()) 0 else text.count { it == '\n' }
        return mapOf(
            "path" to f.absolutePath,
            "bytes" to f.length(),
            "lines" to lineCount,
            "content" to text,
        )
    }
}
