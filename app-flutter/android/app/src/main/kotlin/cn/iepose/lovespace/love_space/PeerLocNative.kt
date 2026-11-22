package cn.iepose.lovespace.love_space

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.atan2
import kotlin.math.PI

/**
 * 2.8.0 定位守护第 0 步 · 路线 B：原生 LocationManager 三 provider 采集 +
 * 端上 GCJ-02 转换 + 原生自足批量上报（全链路在 FGS 进程内，不依赖任何
 * Flutter isolate——flutter_foreground_task 的服务 isolate 是独立 engine，
 * 主 engine 的 channel 服务侧收不到，故采集/上报全在原生层，Dart 只发
 * start(token, baseUrl) / stop 指令）。
 *
 * 🔴 红线依据：国产小米机无 GMS，FusedLocationProvider 回调永不触发
 * （开源实证）。🔴 couple-tracker 无 LICENSE：只借鉴设计与参数，本文件自研。
 *
 * 采样口径（提示词主体二，参数集中此处便于二期调参）：
 * · 位移触发 25 m（GPS/NETWORK，硬件级系统判断）；minTime 15 s；
 * · PASSIVE 零耗电补点（复用其他 App 的定位结果）；
 * · 静止判定：连续 3 次位移 <25 m → 降 5 min 心跳（附带状态字段）；
 *   恢复有效位移即回行进节奏；
 * · 精度过滤：acc>100 m 丢弃；50<acc≤100 m 只更新 latest 不入轨迹；
 * · 批量上报：攒满 5 条或距上次成功超 3 min；队列上限 50 条溢出丢最旧；
 *   失败保留队列网络恢复补传（置 backfilled 标记）；
 * · 坐标：端上 WGS-84→GCJ-02 转换后上报（后端入库统一 GCJ-02，不二次转换）。
 *
 * [peer-loc] 前缀调试日志（采样切换/上报成败/补传量），本段保留不删。
 */
object PeerLocNative {
    private const val CHANNEL = "peer_loc/native"
    const val TAG = "peer-loc"

    // ── 参数集中（二期调参）────────────────────────────────────────────
    private const val MIN_DISTANCE_M = 25f
    private const val MIN_TIME_MS = 15_000L
    private const val STILL_HEARTBEAT_MS = 5 * 60_000L
    private const val STILL_CONFIRM_TIMES = 3
    private const val ACC_DROP_M = 100.0        // >100 m 丢弃
    private const val ACC_LATEST_ONLY_M = 50.0  // >50 m 只更新 latest
    private const val BATCH_MAX = 5
    private const val BATCH_FLUSH_MS = 3 * 60_000L
    private const val QUEUE_MAX = 50
    private const val POINT_RETENTION_HINT = 15 // 仅注释口径，清理在后端

    private var lm: LocationManager? = null
    private val listeners = mutableListOf<LocationListener>()
    private val handler = Handler(Looper.getMainLooper())

    // 会话凭据（Dart 端 start 注入；进程内保存，服务被杀随进程消失）
    private var sessionCookie: String? = null
    private var baseUrl: String? = null
    private var appContext: Context? = null

    // 采集态
    private val queue = ArrayDeque<JSONObject>()
    private var lastSent: JSONObject? = null
    private var lastEnqueued: JSONObject? = null
    private var lastSentAt = 0L
    private var stillCount = 0
    private var stillMode = false
    private var lastFlushAt = 0L
    private var reportedCount = 0
    private var droppedCount = 0
    private var lastError: String? = null
    private var receivedCount = 0
    private var lastReceivedAt = 0L

    private fun log(msg: String) = android.util.Log.d(TAG, msg)

    fun register(messenger: io.flutter.plugin.common.BinaryMessenger, context: Context) {
        appContext = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                // ── 2.8.0 fix4 胶水重做：单一原生入口（一口价）──────────
                // Dart 只搬运 {enable, cookie, baseUrl}（凭据从 secure_storage
                // 正本读出后下传，Dart 只做渲染），一切权限判定/启停/状态
                // 都在本原生层收口，返回 {ok, reason, detail}。
                "toggle" -> {
                    val args = call.arguments() as? Map<*, *>
                    val enable = args?.get("enable") == true
                    sessionCookie = args?.get("cookie") as? String
                    baseUrl = args?.get("baseUrl") as? String
                    result.success(toggle(context, enable))
                }
                "status" -> result.success(status())
                "exportFatal" -> result.success(exportFatalLog())
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 2.8.0 fix4：FINE 硬门槛判定（toggle 内部分别回报 fine/background 两值，
     * 缺后台走对应引导；background 是否真生效再由回调探针实证）。
     */
    fun hasPermission(context: Context): Boolean = fineGranted(context)

    /** FINE 定位：checkSelfPermission 硬门槛（各 ROM 口径一致）。 */
    fun fineGranted(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * BACKGROUND 定位（Android 11+ / MIUI 兼容口径）：
     * 权限 API（checkSelfPermission/geolocator 枚举）在部分 ROM 上
     * 「已授仍报 denied」不可作事实源（真机实证）——background 是否真生效
     * 以**回调实证探针**为准：start 后统计真实 location 回调数（received），
     * Dart 侧轮询 stats，3 min 内 0 回调即判定后台定位未生效并给用户可见
     * 说明（权限 API 只做 FINE 硬门槛与引导）。
     */
    fun backgroundGranted(context: Context): Boolean =
        ContextCompat.checkSelfPermission(
            context, Manifest.permission.ACCESS_BACKGROUND_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /** 启用前置检查：逐项给出缺失原因（FINE 硬门槛；background 走探针实证）。 */
    fun startReason(context: Context): String? = when {
        !fineGranted(context) -> "需要定位权限（使用期间/始终允许）"
        else -> null
    }

    /** 胶水一口价：开/关。返回 {ok, reason, detail}（Dart 只渲染）。 */
    @Synchronized
    fun toggle(context: Context, enable: Boolean): Map<String, Any?> {
        if (!enable) {
            stop()
            return mapOf("ok" to true, "reason" to "", "detail" to detailMap())
        }
        // 权限系统真实状态分开回报（缺前台/缺后台两种 reason，Dart 对应引导）
        val fine = fineGranted(context)
        val bg = backgroundGranted(context)
        val detail = mapOf("fine" to (if (fine) "granted" else "denied"),
                           "background" to (if (bg) "granted" else "denied"))
        if (!fine) {
            val reason = "需要定位权限（使用期间），请在系统设置中授予"
            log("toggle-on rejected: fine=$fine bg=$bg")
            fatal(context, "toggle-on rejected fine=${fine} bg=${bg}")
            return mapOf("ok" to false, "reason" to reason, "detail" to detail)
        }
        if (!bg) {
            val reason = "定位权限已授「使用期间」，还需要「始终允许」：" +
                "系统设置 → 应用 → 恋爱空间 → 位置 → 选择「始终允许」后重试"
            log("toggle-on rejected: fine=$fine bg=$bg")
            fatal(context, "toggle-on rejected fine=${fine} bg=${bg}")
            return mapOf("ok" to false, "reason" to reason, "detail" to detail)
        }
        stillMode = false; stillCount = 0; queue.clear()
        reportedCount = 0; droppedCount = 0; lastError = null
        receivedCount = 0; lastReceivedAt = 0
        start(context)
        val running = listeners.isNotEmpty()
        val reason = if (running) "" else "采集启动失败（前台服务未运行或被系统拒绝），请重启 App 后重试"
        log("toggle-on: running=$running")
        if (!running) fatal(context, "toggle-on start failed (listeners empty)")
        return mapOf("ok" to running, "reason" to reason, "detail" to detail)
    }

    /** 开关态单一事实源查询：服务在跑 + 最近回调计数（页面进入/toggle 后回填）。 */
    fun status(): Map<String, Any?> = mapOf(
        "running" to listeners.isNotEmpty(),
        "received" to receivedCount,
        "lastReceivedAt" to lastReceivedAt,
        "queue" to queue.size,
        "reported" to reportedCount,
        "dropped" to droppedCount,
        "still" to stillMode,
        "error" to lastError)

    /** fatal 日志导出（验证卡导出/分享入口——机主拿得出来才算落盘完成）。 */
    fun exportFatalLog(): Map<String, Any?> {
        val ctx = appContext
        val f = java.io.File(
            (ctx?.getExternalFilesDir(null) ?: ctx?.filesDir), "peer-loc${java.io.File.separator}fatal-native.txt")
        val content = if (f.exists()) f.readText() else ""
        return mapOf("path" to (if (f.exists()) f.absolutePath else ""),
                     "content" to content)
    }

    /** 原生侧 fatal 落盘（注册类/采集类问题堆栈原文，logcat 截断兜底）。 */
    private fun fatal(context: Context, msg: String) {
        try {
            val dir = java.io.File(context.getExternalFilesDir(null), "peer-loc")
            if (!dir.exists()) dir.mkdirs()
            java.io.File(dir, "fatal-native.txt").appendText(
                "[${System.currentTimeMillis()}] $msg\n")
        } catch (_: Exception) {}
    }

    @Synchronized
    fun start(context: Context) {
        appContext = context.applicationContext
        if (listeners.isNotEmpty()) return
        val reason = startReason(context)
        if (reason != null) {
            log("start denied: $reason")
            return
        }
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        lm = manager
        val listener = LocationListener { onLocation(it) }
        listeners.add(listener)
        try {
            manager.requestLocationUpdates(
                LocationManager.GPS_PROVIDER, MIN_TIME_MS, MIN_DISTANCE_M, listener,
                Looper.getMainLooper())
            manager.requestLocationUpdates(
                LocationManager.NETWORK_PROVIDER, MIN_TIME_MS, MIN_DISTANCE_M, listener,
                Looper.getMainLooper())
            manager.requestLocationUpdates(
                LocationManager.PASSIVE_PROVIDER, 0L, 0f, listener, Looper.getMainLooper())
            log("started: gps+network+passive (25m/15s; passive 0/0)")
        } catch (e: Exception) {
            log("start partial-error: ${e.message}") // provider 被系统关闭不整体失败
        }
    }

    @Synchronized
    fun stop() {
        val manager = lm ?: return
        for (l in listeners) { try { manager.removeUpdates(l) } catch (_: Exception) {} }
        listeners.clear(); lm = null; queue.clear(); lastSent = null
        lastEnqueued = null; lastSentAt = 0
        stillMode = false; stillCount = 0
        log("stopped (queue cleared)")
    }

    // ── 采集与判定 ──────────────────────────────────────────────────────

    private fun onLocation(location: Location) {
        receivedCount++
        lastReceivedAt = System.currentTimeMillis()
        val acc = if (location.hasAccuracy()) location.accuracy.toDouble() else 9999.0
        // 精度过滤：acc>100 丢弃
        if (acc > ACC_DROP_M) {
            droppedCount++; log("drop: acc=${acc}m > ${ACC_DROP_M}m"); return
        }
        val gcj = wgs84ToGcj02(location.latitude, location.longitude)
        // 位移判定（与上次上报点比较，米）
        val moved = lastSent?.let {
            distanceMeters(it.getDouble("lat"), it.getDouble("lng"), gcj.first, gcj.second)
        } ?: Double.MAX_VALUE
        var heartbeat = false
        if (moved < MIN_DISTANCE_M) {
            stillCount++
            if (stillCount >= STILL_CONFIRM_TIMES && !stillMode) {
                stillMode = true
                log("still confirmed x$stillCount -> heartbeat ${STILL_HEARTBEAT_MS / 1000}s")
            }
        } else {
            if (stillMode) log("movement resumed (moved=${moved.toInt()}m) -> active pace")
            stillCount = 0; stillMode = false
        }
        // 静止心跳 5 min 时间门控：门控未到直接丢弃本次回调（PASSIVE/重复
        // provider 高频触发，不能每帧都当心跳入点）
        if (stillMode) {
            val since = System.currentTimeMillis() - lastSentAt
            if (since < STILL_HEARTBEAT_MS) {
                log("still heartbeat gated (${since / 1000}s < ${STILL_HEARTBEAT_MS / 1000}s)")
                return
            }
            heartbeat = true
        }
        // 多 provider 去重：与上一个**入队**点 <10 m 视为同位置重复回调
        lastEnqueued?.let {
            if (distanceMeters(it.getDouble("lat"), it.getDouble("lng"),
                    gcj.first, gcj.second) < 10.0) {
                log("dedup: same spot as last enqueued (${location.provider})")
                return
            }
        }
        val point = JSONObject().apply {
            put("id", "pl-${location.time}")
            put("ts", location.time.toDouble())
            put("lat", gcj.first)
            put("lng", gcj.second)
            put("acc", acc)
            put("speed", if (location.hasSpeed()) location.speed.toDouble() else 0.0)
        }
        // 精度分层：50<acc≤100 只更新 latest，不入轨迹 points
        if (acc <= ACC_LATEST_ONLY_M) {
            enqueue(point)
        }
        lastEnqueued = point
        lastSent = JSONObject().apply {
            put("lat", gcj.first); put("lng", gcj.second)
            put("battery", readBattery()); put("charging", readCharging())
            put("net", readNet()); put("wifi", readWifi())
            put("ts", System.currentTimeMillis().toDouble())
        }
        lastSentAt = System.currentTimeMillis()
        maybeFlush()
    }

    private fun enqueue(point: JSONObject) {
        while (queue.size >= QUEUE_MAX) { queue.removeFirst(); log("queue overflow -> drop oldest") }
        queue.addLast(point)
        log("enqueued (n=${queue.size})")
    }

    private fun maybeFlush() {
        val last = lastSent ?: return
        val due = queue.size >= BATCH_MAX ||
            (queue.isNotEmpty() && System.currentTimeMillis() - lastFlushAt >= BATCH_FLUSH_MS)
        if (due) flush()
    }

    // ── 原生上报（HttpURLConnection 零依赖）────────────────────────────

    private fun flush() {
        val urlBase = baseUrl ?: return
        val cookie = sessionCookie ?: return
        if (queue.isEmpty()) return
        val batch = JSONArray()
        while (batch.length() < BATCH_MAX && queue.isNotEmpty()) batch.put(queue.first())
        val latest = lastSent
        val body = JSONObject().apply {
            put("points", batch)
            if (latest != null) put("latest", latest)
        }
        Thread {
            var ok = false
            try {
                val conn = URL("$urlBase/api/peer/location").openConnection() as HttpURLConnection
                conn.requestMethod = "POST"
                conn.connectTimeout = 10_000
                conn.readTimeout = 15_000
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setRequestProperty("Cookie", cookie)
                conn.setRequestProperty("X-Love-Space", "1")
                OutputStreamWriter(conn.outputStream, Charsets.UTF_8).use { it.write(body.toString()) }
                val code = conn.responseCode
                ok = code in 200..299
                if (!ok) {
                    lastError = "HTTP $code"
                    // 上报者开关关闭 422 → 端上自愈：停报清队列（提示词对齐修订 6）
                    if (code == 422) { queue.clear(); stop(); log("422 -> self-heal: stop & clear") }
                }
                conn.disconnect()
            } catch (e: Exception) {
                lastError = e.message ?: e.toString()
            }
            handler.post {
                if (ok) {
                    repeat(batch.length()) { if (queue.isNotEmpty()) queue.removeFirst() }
                    reportedCount += batch.length()
                    lastFlushAt = System.currentTimeMillis()
                    log("flush ok n=${batch.length()} (reported=$reportedCount, queue=${queue.size})")
                } else {
                    log("flush fail (queue=${queue.size}) err=$lastError")
                }
            }
        }.start()
    }

    // ── 状态附带（读不到给空不报错）────────────────────────────────────

    // 电量/充电：sticky BATTERY_CHANGED 广播（免 receiver 生命周期）
    private fun readBattery(): Int = try {
        val ctx = appContext ?: return -1
        val intent = ctx.registerReceiver(null,
            android.content.IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED))
        intent?.getIntExtra(android.os.BatteryManager.EXTRA_LEVEL, -1) ?: -1
    } catch (_: Exception) { -1 }

    private fun readCharging(): Boolean = try {
        val ctx = appContext ?: return false
        val intent = ctx.registerReceiver(null,
            android.content.IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED))
        val status = intent?.getIntExtra(android.os.BatteryManager.EXTRA_STATUS, -1) ?: -1
        status == android.os.BatteryManager.BATTERY_STATUS_CHARGING ||
            status == android.os.BatteryManager.BATTERY_STATUS_FULL
    } catch (_: Exception) { false }

    // 网络类型：ConnectivityManager activeNetwork 能力判定（wifi/cell/none）
    private fun readNet(): String = try {
        val ctx = appContext ?: return ""
        val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
        val nw = cm.activeNetwork ?: return "none"
        val caps = cm.getNetworkCapabilities(nw)
        when {
            caps == null -> "none"
            caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) -> "cell"
            else -> "other"
        }
    } catch (_: Exception) { "" }

    // Wi-Fi SSID：定位权限已覆盖读取（读不到给空，不报错）
    private fun readWifi(): String = try {
        val ctx = appContext ?: return ""
        val wifi = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE)
            as android.net.wifi.WifiManager
        val ssid = wifi.connectionInfo?.ssid?.trim('"') ?: ""
        if (ssid.startsWith("<unknown")) "" else ssid
    } catch (_: Exception) { ""
    }

    // ── GCJ-02（端上转换，后端入库统一 GCJ-02）──────────────────────────

    private const val A = 6378245.0
    private const val EE = 0.00669342162296594323

    private fun outOfChina(lat: Double, lng: Double): Boolean =
        lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271

    private fun tLat(x: Double, y: Double): Double {
        var r = -100.0 + 2.0*x + 3.0*y + 0.2*y*y + 0.1*x*y + 0.2*sqrt(abs(x))
        r += (20.0*sin(6.0*x*PI) + 20.0*sin(2.0*x*PI)) * 2.0/3.0
        r += (20.0*sin(y*PI) + 40.0*sin(y/3.0*PI)) * 2.0/3.0
        r += (160.0*sin(y/12.0*PI) + 320.0*sin(y*PI/30.0)) * 2.0/3.0
        return r
    }
    private fun tLng(x: Double, y: Double): Double {
        var r = 300.0 + x + 2.0*y + 0.1*x*x + 0.1*x*y + 0.1*sqrt(abs(x))
        r += (20.0*sin(6.0*x*PI) + 20.0*sin(2.0*x*PI)) * 2.0/3.0
        r += (20.0*sin(x*PI) + 40.0*sin(x/3.0*PI)) * 2.0/3.0
        r += (150.0*sin(x/12.0*PI) + 300.0*sin(x/30.0*PI)) * 2.0/3.0
        return r
    }

    /** WGS-84 → GCJ-02（境外原样返回）。 */
    fun wgs84ToGcj02(lat: Double, lng: Double): Pair<Double, Double> {
        if (outOfChina(lat, lng)) return Pair(lat, lng)
        var dLat = tLat(lng - 105.0, lat - 35.0)
        var dLng = tLng(lng - 105.0, lat - 35.0)
        val radLat = lat / 180.0 * PI
        var magic = sin(radLat)
        magic = 1 - EE * magic * magic
        val sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((A * (1 - EE)) / (magic * sqrtMagic) * PI)
        dLng = (dLng * 180.0) / (A / sqrtMagic * cos(radLat) * PI)
        return Pair(lat + dLat, lng + dLng)
    }

    private fun distanceMeters(lat1: Double, lng1: Double, lat2: Double, lng2: Double): Double {
        val r = 6371000.0
        val dLat = (lat2 - lat1) * PI / 180.0
        val dLng = (lng2 - lng1) * PI / 180.0
        val s = sin(dLat/2)*sin(dLat/2) +
            cos(lat1*PI/180)*cos(lat2*PI/180)*sin(dLng/2)*sin(dLng/2)
        return r * 2 * atan2(sqrt(s), sqrt(1 - s))
    }
}
